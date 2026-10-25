// Time a real editor session against a checkout: open one file, then ask for the answers an editor
// asks for while typing. Prints milliseconds per phase, best of a few rounds.
//
//   bun tools/latency.mjs <tree>            # ROUNDS=5 ASKS=40 by default
//   ROUNDS=3 ASKS=12 bun tools/latency.mjs /tmp/lye-before
//   ROUNDS=3 ASKS=12 bun tools/latency.mjs /home/once/Projects/Personal/lye
//
// Two checkouts are what this is for: `git worktree add /tmp/lye-before <ref>` and the same command
// against each answers whether a change cost anything on the path an editor takes — an open, a
// keystroke, a hover, the semantic tokens. `tools/bench.lua` answers the same question about the
// analyzer alone, which is cheap enough to measure inside one process.
//
// The file opened is the language server's own largest source file unless FILE names another, and
// the phases are:
//
//   open       didOpen, then the first token request: parse, analyse, colour
//   keystroke  an edit at the top of the file, then the tokens again
//   hover      ASKS hovers at different lines
//   tokens     ASKS/4 more token requests over the text as it now stands
//   edits      EDITS edits of each shape — a statement in a function body, a space in an
//              annotation, a statement at module level — each measured to its token answer, with
//              p50 and p95 over the samples
//
// Each round is a fresh server, so a round includes the JIT warming up; the best round is reported
// for that reason. A second line carries the server's own marks — initialize, the workspace scans,
// each analysis, the token build and the plugin walk — so a phase that is the editor waiting can be
// told from a phase that is the server working. LYE_TIMING=1 is set for the child; COLD=1 empties
// the cache before every round and FILE=path opens another document, which is the usual way to
// separate a first run from a typical one.
import { spawn } from "node:child_process";
import { rmSync } from "node:fs";

const tree = process.argv[2] ?? "/home/once/Projects/Personal/lye";
// The largest source file is the worst case; `FILE` names another one, which is what a typical
// keystroke looks like rather than the ceiling.
const file = process.env.FILE ?? `${tree}/packages/lye-lsp/src/language.lua`;
const text = await Bun.file(file).text();
const uri = `file://${file}`;
const rounds = Number(process.env.ROUNDS ?? 5);
const asks = Number(process.env.ASKS ?? 40);
const editsPerShape = Number(process.env.EDITS ?? 5);
// The server's own marks are the only place the workspace scan and the token walk are timed apart
// from the request that carried them. `COLD=1` makes every round a first run, which is what the
// scan and the cache are worth measuring on.
const cold = process.env.COLD === "1";
const cache = `/tmp/lye-latency-${tree.replace(/[^a-zA-Z0-9]/g, "_")}`;

const frame = (value) => {
	// The length is bytes, not characters: a document with an em dash in it declares four bytes for
	// three characters, and a header that says otherwise is a frame the server cannot read.
	const body = JSON.stringify(value);
	return `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`;
};

const request = (id, method, params) => ({ jsonrpc: "2.0", id, method, params });

async function once() {
	if (cold) rmSync(cache, { recursive: true, force: true });
	const child = spawn("lde", ["run", "-C", `${tree}/packages/lye-lsp`, "tests/fixtures/server.lua"], {
		cwd: tree,
		env: { ...process.env, LYE_CACHE_DIR: cache, LYE_TIMING: process.env.LYE_TIMING ?? "1" },
		stdio: ["pipe", "pipe", "pipe"],
	});

	let out = Buffer.alloc(0);
	let settled = 0;
	const phases = {};
	const waiters = [];
	const marks = {};
	let trace = "";
	child.stderr.on("data", (chunk) => {
		trace += chunk.toString();
		while (true) {
			const newline = trace.indexOf("\n");
			if (newline < 0) break;
			const line = trace.slice(0, newline);
			trace = trace.slice(newline + 1);
			const found = line.match(/^lye timing: ([a-z-]+)=([\d.]+)ms(?: (.*))?$/);
			if (found) {
				const note = found[3] ?? "";
				// A cached token answer is a different measurement from building one, and keeping
				// only the last of them would report the cheap one.
				const label = found[1] + (note.includes("cached=0") ? ":build" : note.includes("cached=1") ? ":cached" : "");
				marks[label] = { ms: Number(found[2]), note };
			}
		}
	});
	const startedAt = performance.now();
	child.stdout.on("data", (chunk) => {
		out = Buffer.concat([out, chunk]);
		while (true) {
			const at = out.indexOf("\r\n\r\n");
			if (at < 0) break;
			const head = out.subarray(0, at).toString();
			const length = Number(head.match(/content-length:\s*(\d+)/i)?.[1]);
			if (!Number.isFinite(length) || out.length < at + 4 + length) break;
			const message = JSON.parse(out.subarray(at + 4, at + 4 + length).toString());
			out = out.subarray(at + 4 + length);
			if (message.id !== undefined) {
				settled = Math.max(settled, message.id);
			}
		}
		const done = waiters.filter((w) => settled >= w.id);
		for (const waiter of done) {
			waiters.splice(waiters.indexOf(waiter), 1);
			waiter.resolve();
		}
	});

	const settle = (id) => new Promise((resolve) => {
		if (settled >= id) return resolve();
		waiters.push({ id, resolve });
	});

	const send = (value) => new Promise((resolve) => {
		child.stdin.write(frame(value), resolve);
	});

	let id = 1;
	await send(request(id, "initialize", {
		capabilities: {}, rootUri: `file://${tree}`,
	}));
	await settle(id++);
	phases.init = performance.now() - startedAt;

	// The open: nothing is known yet, so this is a parse, an analysis and the first diagnostics.
	let at = performance.now();
	await send({ jsonrpc: "2.0", method: "textDocument/didOpen", params: {
		textDocument: { uri, languageId: "lua", version: 1, text },
	} });
	const openId = id++;
	await send(request(openId, "textDocument/semanticTokens/full", { textDocument: { uri } }));
	await settle(openId);
	phases.open = performance.now() - at;

	// A keystroke: a newline inserted at the top, which is the edit that moves every offset there
	// is — then the answers again, which is what makes it cost anything.
	at = performance.now();
	await send({ jsonrpc: "2.0", method: "textDocument/didChange", params: {
		textDocument: { uri, version: 2 },
		contentChanges: [{
			range: { start: { line: 0, character: 0 }, ["end"]: { line: 0, character: 0 } },
			text: "-- typed\n",
		}],
	} });
	const changeId = id++;
	await send(request(changeId, "textDocument/semanticTokens/full", { textDocument: { uri } }));
	await settle(changeId);
	phases.keystroke = performance.now() - at;

	// The text the server now holds, kept in step with the edits below so a position is a position.
	let live = `-- typed\n${text}`;
	let version = 2;

	// What an editor asks while the cursor moves: hover, then the tokens again, `asks` times.
	at = performance.now();
	for (let i = 0; i < asks; i += 1) {
		const hover = id++;
		await send(request(hover, "textDocument/hover", {
			textDocument: { uri }, position: { line: 100 + (i % 40), character: 12 },
		}));
		await settle(hover);
	}
	phases.hover = performance.now() - at;

	at = performance.now();
	for (let i = 0; i < Math.ceil(asks / 4); i += 1) {
		const tokens = id++;
		await send(request(tokens, "textDocument/semanticTokens/full", { textDocument: { uri } }));
		await settle(tokens);
	}
	phases.tokens = performance.now() - at;

	// The edit script: three shapes of edit an editor sends all day. Each is measured from the
	// didChange to the token answer for the text it produced, so it carries the analysis a
	// keystroke carries and nothing an idle cursor does not.
	const edits = { body: [], annotation: [], module: [] };

	const lineStarts = (source) => {
		const starts = [0];
		for (let index = 0; index < source.length; index += 1) {
			if (source[index] === "\n") starts.push(index + 1);
		}
		return starts;
	};
	const offsetOf = (source, position) => lineStarts(source)[position.line] + position.character;

	// The places each shape can be applied, found on the text as it stands: a function line with a
	// statement after it, an annotation line, and the module's own `return`.
	const bodyPlaces = (source) => {
		const lines = source.split("\n");
		const found = [];
		for (let index = 0; index + 1 < lines.length; index += 1) {
			if (!/^\s*(local\s+)?function\b/.test(lines[index])) continue;
			const next = lines[index + 1];
			if (next.trim() === "" || next.trim() === "end" || next.trim() === "end)") continue;
			const indent = next.match(/^\s*/)[0];
			found.push({ line: index + 1, character: 0, text: `${indent}-- edit\n` });
		}
		return found;
	};
	const annotationPlaces = (source) => {
		const found = [];
		for (const [index, line] of source.split("\n").entries()) {
			const foundTag = line.match(/^(\s*)(---@[A-Za-z]+)/);
			if (foundTag) found.push({ line: index, character: foundTag[1].length + foundTag[2].length, text: " " });
		}
		return found;
	};
	const modulePlaces = (source) => {
		const lines = source.split("\n");
		for (let index = lines.length - 1; index >= 0; index -= 1) {
			if (/^return\b/.test(lines[index])) return [{ line: index, character: 0, text: "local __edit = 1\n" }];
		}
		return lines.length > 0 ? [{ line: 0, character: 0, text: "local __edit = 1\n" }] : [];
	};
	const shapes = { body: bodyPlaces, annotation: annotationPlaces, module: modulePlaces };

	for (const [shape, places] of Object.entries(shapes)) {
		for (let sample = 0; sample < editsPerShape; sample += 1) {
			const candidates = places(live);
			if (candidates.length === 0) break;
			// Spread over the candidates, and recomputed per edit because an insertion moved them.
			const edit = candidates[Math.min(candidates.length - 1,
				Math.floor(sample * candidates.length / editsPerShape))];
			const started = performance.now();
			version += 1;
			await send({ jsonrpc: "2.0", method: "textDocument/didChange", params: {
				textDocument: { uri, version },
				contentChanges: [{
					range: { start: { line: edit.line, character: edit.character },
						["end"]: { line: edit.line, character: edit.character } },
					text: edit.text,
				}],
			} });
			const answer = id++;
			await send(request(answer, "textDocument/semanticTokens/full", { textDocument: { uri } }));
			await settle(answer);
			edits[shape].push(performance.now() - started);
			const at = offsetOf(live, edit);
			live = live.slice(0, at) + edit.text + live.slice(at);
		}
	}

	at = performance.now();
	await send(request(id++, "shutdown"));
	await settle(id - 1);
	child.kill();
	phases.shutdown = performance.now() - at;
	return { phases, marks, edits };
}

const results = [];
for (let round = 0; round < rounds; round += 1) results.push(await once());
const best = {};
for (const phase of Object.keys(results[0].phases)) {
	best[phase] = Math.min(...results.map((r) => r.phases[phase]));
}
const marks = {};
for (const result of results) {
	for (const [label, mark] of Object.entries(result.marks)) {
		if (!marks[label] || mark.ms < marks[label].ms) marks[label] = mark;
	}
}
console.log(
	Object.entries(best)
		.map(([phase, ms]) => `${phase}=${ms.toFixed(1)}ms`)
		.join(" ") + `  (${asks} asks, best of ${rounds}${cold ? ", cold" : ""})`,
);
console.log(
	"server " + Object.entries(marks)
		.map(([label, mark]) => `${label}=${mark.ms.toFixed(1)}ms${mark.note ? `(${mark.note})` : ""}`)
		.join(" "),
);

// The edit samples are pooled across rounds: each is an independent edit of a fresh server, and a
// percentile over five samples is a percentile of an accident.
const percentile = (values, share) => {
	const sorted = [...values].sort((left, right) => left - right);
	const rank = Math.ceil((share / 100) * sorted.length) - 1;
	return sorted[Math.max(0, Math.min(sorted.length - 1, rank))];
};
const pooled = { body: [], annotation: [], module: [] };
for (const result of results) {
	for (const [shape, values] of Object.entries(result.edits)) pooled[shape].push(...values);
}
console.log(
	"edits " + Object.entries(pooled)
		.map(([shape, values]) => values.length === 0
			? `${shape}=none`
			: `${shape} p50=${percentile(values, 50).toFixed(1)}ms p95=${percentile(values, 95).toFixed(1)}ms n=${values.length}`)
		.join("  "),
);

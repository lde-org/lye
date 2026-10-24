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
// The file opened is the language server's own largest source file, and the phases are:
//
//   open       didOpen, then the first token request: parse, analyse, colour
//   keystroke  an edit at the top of the file, then the tokens again
//   hover      ASKS hovers at different lines
//   tokens     ASKS/4 more token requests over the text as it now stands
//
// Each round is a fresh server, so a round includes the JIT warming up; the best round is reported
// for that reason.
import { spawn } from "node:child_process";

const tree = process.argv[2] ?? "/home/once/Projects/Personal/lye";
const file = `${tree}/packages/lye-lsp/src/language.lua`;
const text = await Bun.file(file).text();
const uri = `file://${file}`;
const rounds = Number(process.env.ROUNDS ?? 5);
const asks = Number(process.env.ASKS ?? 40);

const frame = (value) => {
	// The length is bytes, not characters: a document with an em dash in it declares four bytes for
	// three characters, and a header that says otherwise is a frame the server cannot read.
	const body = JSON.stringify(value);
	return `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`;
};

const request = (id, method, params) => ({ jsonrpc: "2.0", id, method, params });

async function once() {
	const child = spawn("lde", ["run", "-C", `${tree}/packages/lye-lsp`, "tests/fixtures/server.lua"], {
		cwd: tree,
		env: { ...process.env, LYE_CACHE_DIR: `/tmp/lye-latency-${tree.replace(/[^a-zA-Z0-9]/g, "_")}` },
		stdio: ["pipe", "pipe", "ignore"],
	});

	let out = "";
	let settled = 0;
	const phases = {};
	const waiters = [];
	child.stdout.on("data", (chunk) => {
		out += chunk.toString();
		while (true) {
			const at = out.indexOf("\r\n\r\n");
			if (at < 0) break;
			const length = Number(out.slice(0, at).match(/content-length:\s*(\d+)/i)?.[1]);
			if (!Number.isFinite(length) || out.length < at + 4 + length) break;
			const message = JSON.parse(out.slice(at + 4, at + 4 + length));
			out = out.slice(at + 4 + length);
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

	at = performance.now();
	await send(request(id++, "shutdown"));
	await settle(id - 1);
	child.kill();
	phases.shutdown = performance.now() - at;
	return phases;
}

const results = [];
for (let round = 0; round < rounds; round += 1) results.push(await once());
const best = {};
for (const phase of Object.keys(results[0])) {
	best[phase] = Math.min(...results.map((r) => r[phase]));
}
console.log(
	Object.entries(best)
		.map(([phase, ms]) => `${phase}=${ms.toFixed(1)}ms`)
		.join(" ") + `  (${asks} asks, best of ${rounds})`,
);

/**
 * A responsiveness benchmark that speaks the protocol the way `vscode-languageclient` does.
 *
 * It spawns the real executable with the arguments the client appends, opens a file that uses
 * the standard library, and times each request an editor makes while someone types: hover over a
 * call, completion after a dot, completion of a name, go-to-definition, document symbols,
 * semantic tokens, and the round trip from a keystroke to the diagnostics the editor draws.
 *
 *     LYE_BINARY=../lye-lsp/lye-lsp node tests/benchmark.mjs [--iterations 50] [--json out.json]
 */

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const BINARY = process.env.LYE_BINARY ?? "lye";
const URI = "file:///benchmark.lua";

const args = process.argv.slice(2);
/**
 * @param {string} name
 * @param {string} fallback
 */
function option(name, fallback) {
	const at = args.indexOf(`--${name}`);
	return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
}
const ITERATIONS = Number(option("iterations", "50"));
const SOURCE = readFileSync(option("source", new URL("./fixtures/benchmark.lua", import.meta.url)), "utf8");

/** @param {object} value */
function frame(value) {
	const body = Buffer.from(JSON.stringify(value), "utf8");
	return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
}

class Client {
	constructor(binary) {
		this.child = spawn(binary, ["--stdio", `--clientProcessId=${process.pid}`], {
			stdio: ["pipe", "pipe", "pipe"],
		});
		this.pending = new Map();
		this.diagnostics = [];
		this.buffer = Buffer.alloc(0);
		this.nextId = 1;
		this.child.stdout.on("data", (chunk) => {
			this.buffer = Buffer.concat([this.buffer, chunk]);
			this.read();
		});
		this.child.stderr.on("data", () => {});
	}

	read() {
		while (true) {
			const headerEnd = this.buffer.indexOf("\r\n\r\n");
			if (headerEnd < 0) return;
			const header = this.buffer.subarray(0, headerEnd).toString("ascii");
			const length = Number(/Content-Length:\s*(\d+)/i.exec(header)?.[1]);
			if (!Number.isFinite(length)) return;
			const start = headerEnd + 4;
			if (this.buffer.length < start + length) return;
			const body = this.buffer.subarray(start, start + length).toString("utf8");
			this.buffer = this.buffer.subarray(start + length);
			this.dispatch(JSON.parse(body));
		}
	}

	/** @param {any} message */
	dispatch(message) {
		if (message.id !== undefined && this.pending.has(message.id)) {
			const settle = this.pending.get(message.id);
			this.pending.delete(message.id);
			settle(message);
			return;
		}
		if (message.method === "textDocument/publishDiagnostics") {
			for (const listener of this.diagnostics.splice(0)) listener(message.params);
		}
	}

	/**
	 * @param {string} method
	 * @param {object} params
	 * @returns {Promise<any>}
	 */
	request(method, params) {
		const id = this.nextId++;
		const answer = new Promise((resolve, reject) => {
			const deadline = setTimeout(
				() => reject(new Error(`timed out waiting for ${method}`)),
				30000,
			);
			this.pending.set(id, (message) => {
				clearTimeout(deadline);
				if (message.error) reject(new Error(`${method}: ${JSON.stringify(message.error)}`));
				else resolve(message.result);
			});
		});
		this.child.stdin.write(frame({ jsonrpc: "2.0", id, method, params }));
		return answer;
	}

	/**
	 * @param {string} method
	 * @param {object} params
	 */
	notify(method, params) {
		this.child.stdin.write(frame({ jsonrpc: "2.0", method, params }));
	}

	/** Resolves when the next diagnostics arrive. */
	nextDiagnostics() {
		return new Promise((resolve) => this.diagnostics.push(resolve));
	}
}

const client = new Client(BINARY);
const { capabilities } = await client.request("initialize", {
	processId: process.pid,
	clientInfo: { name: "lye-benchmark" },
	capabilities: {
		general: { positionEncodings: ["utf-16"] },
		textDocument: { hover: {}, synchronization: { dynamicRegistration: false } },
	},
});
client.notify("initialized", {});
client.notify("textDocument/didOpen", {
	textDocument: { uri: URI, languageId: "lua", version: 1, text: SOURCE },
});
await new Promise((resolve) => setTimeout(resolve, 250));

/**
 * Where a needle is in the fixture, as a line and character.
 * @param {string} needle
 * @param {number} occurrence
 */
function positionOf(needle, occurrence = 1) {
	let at = -1;
	for (let index = 0; index < occurrence; index++) at = SOURCE.indexOf(needle, at + 1);
	if (at < 0) throw new Error(`the fixture has no ${JSON.stringify(needle)}`);
	const before = SOURCE.slice(0, at);
	return {
		line: before.split("\n").length - 1,
		character: at - (before.lastIndexOf("\n") + 1),
	};
}

/** @param {number[]} samples */
function summarize(samples) {
	const sorted = [...samples].sort((a, b) => a - b);
	const at = (fraction) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
	const mean = sorted.reduce((sum, value) => sum + value, 0) / (sorted.length || 1);
	return { runs: sorted.length, min: sorted[0] ?? 0, p50: at(0.5) ?? 0, p95: at(0.95) ?? 0, max: sorted.at(-1) ?? 0, mean };
}

const checks = {};

/**
 * Times a request, and records what it answered so the numbers are known to be about real work.
 * @param {string} name
 * @param {() => Promise<any>} run
 * @param {(value: any) => any} check
 * @param {number} iterations
 * @returns {Promise<[string, ReturnType<typeof summarize>]>}
 */
async function bench(name, run, check, iterations = ITERATIONS) {
	checks[name] = check(await run());
	const samples = [];
	for (let index = 0; index < iterations; index++) {
		const started = process.hrtime.bigint();
		await run();
		samples.push(Number(process.hrtime.bigint() - started) / 1e6);
	}
	return [name, summarize(samples)];
}

/** @param {any} hover */
function hoverText(hover) {
	if (!hover?.contents) return "nothing";
	const parts = Array.isArray(hover.contents) ? hover.contents : [hover.contents];
	return parts.map((part) => part.value ?? String(part)).join(" ").replace(/\s+/g, " ").trim();
}

async function benchKeystroke() {
	const typed = "local extra = numbers[1]\n";
	const samples = [];
	const runs = Math.min(ITERATIONS, 20);
	for (let index = 0; index < runs; index++) {
		const line = 45;
		const started = process.hrtime.bigint();
		const seen = client.nextDiagnostics();
		client.notify("textDocument/didChange", {
			textDocument: { uri: URI, version: 2 + index },
			contentChanges: [{
				range: { start: { line, character: 0 }, end: { line, character: 0 } },
				text: typed,
			}],
		});
		await seen;
		samples.push(Number(process.hrtime.bigint() - started) / 1e6);
		// Put the file back and wait for that round trip too, outside the measurement: the server
		// answers requests in order, so an unawaited change would be timed with the next one.
		const undone = client.nextDiagnostics();
		client.notify("textDocument/didChange", {
			textDocument: { uri: URI, version: 100 + index },
			contentChanges: [{
				range: { start: { line, character: 0 }, end: { line, character: typed.length - 1 } },
				text: "",
			}],
		});
		await undone;
	}
	return ["keystroke to diagnostics", summarize(samples)];
}

/** The first of several needles the fixture actually contains, so one benchmark runs on any file. */
function firstOf(candidates) {
	for (const candidate of candidates) if (SOURCE.includes(candidate)) return candidate;
	throw new Error(`the fixture has none of ${candidates.join(", ")}`);
}

/** A position a few characters into one of several needles, which is where a cursor would be. */
function insideOf(candidates, ahead) {
	const position = positionOf(firstOf(candidates));
	return { line: position.line, character: position.character + ahead };
}

const results = [];
/** @param {any} list */
function labelsOf(list) {
	return (list?.items ?? []).map((item) => item.label);
}

results.push(await bench("hover over a stdlib call", () => client.request("textDocument/hover", {
	textDocument: { uri: URI }, position: insideOf(["math.floor"], 6),
}), hoverText));
results.push(await bench("hover over a local", () => client.request("textDocument/hover", {
	textDocument: { uri: URI }, position: insideOf(["sum = sum", "scaled = value"], 2),
}), hoverText));
results.push(await bench("completion after math.", () => client.request("textDocument/completion", {
	textDocument: { uri: URI }, position: insideOf(["math.floor"], 5),
}), (list) => ({ count: labelsOf(list).length, has: ["floor", "abs", "pi"].filter((name) => labelsOf(list).includes(name)) })));
results.push(await bench("completion after a local dot", () => client.request("textDocument/completion", {
	textDocument: { uri: URI }, position: insideOf(["second.y", "widget.id"], 7),
}), (list) => ({ count: labelsOf(list).length, has: ["add", "x", "y"].filter((name) => labelsOf(list).includes(name)) })));
results.push(await bench("completion of a name", () => client.request("textDocument/completion", {
	textDocument: { uri: URI }, position: insideOf(["return sum", "return tonumber"], 9),
}), (list) => ({
	count: labelsOf(list).length,
	has: ["math", "string", "table", "print", "sum", "values"].filter((name) => labelsOf(list).includes(name)),
})));
results.push(await bench("go to definition", () => client.request("textDocument/definition", {
	textDocument: { uri: URI }, position: insideOf(["total(numbers)", "step1(1)"], 3),
}), (found) => (Array.isArray(found) ? found.length : found ? 1 : 0)));
results.push(await bench("document symbols", () => client.request("textDocument/documentSymbol", {
	textDocument: { uri: URI },
}), (symbols) => (symbols ?? []).length));
results.push(await bench("semantic tokens", () => client.request("textDocument/semanticTokens/full", {
	textDocument: { uri: URI },
}), (tokens) => (tokens?.data ?? []).length / 5));
results.push(await benchKeystroke());

const report = {
	binary: BINARY,
	lines: SOURCE.split("\n").length,
	iterations: ITERATIONS,
	results: Object.fromEntries(results),
	checks,
};
const out = option("json", "");
if (out) writeFileSync(out, `${JSON.stringify(report, null, "\t")}\n`);

console.log(`${BINARY} — ${report.lines} lines, ${ITERATIONS} iterations each`);
for (const [name, answer] of Object.entries(checks)) {
	console.log(`  ${name.padEnd(28)} -> ${JSON.stringify(answer)}`);
}
for (const [name, stats] of results) {
	console.log(
		`  ${name.padEnd(28)} p50 ${stats.p50.toFixed(2).padStart(7)}ms  ` +
		`p95 ${stats.p95.toFixed(2).padStart(7)}ms  max ${stats.max.toFixed(2).padStart(7)}ms  ` +
		`mean ${stats.mean.toFixed(2).padStart(7)}ms`,
	);
}

await client.request("shutdown", {});
client.notify("exit", {});
setTimeout(() => process.exit(0), 100);

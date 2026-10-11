/**
 * Print a file coloured the way the language server says it should be.
 *
 * The semantic tokens are what an editor paints, so reading them back in a terminal is the only
 * way to *see* whether the answer is right: a method that comes back `variable` and a pattern that
 * comes back `string` both look fine in a list of numbers and wrong on a screen.
 *
 * 	node tools/semantic-view.mjs <file> [LYE_BINARY]
 */
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const file = resolve(process.argv[2] ?? "packages/lye-lsp/src/language.lua");
const binary = process.argv[3] ?? process.env.LYE_BINARY ?? "./packages/lye-lsp/lye-lsp";
const source = readFileSync(file, "utf8");
const URI = `file://${file}`;

/** The colours a terminal can show, one per token kind the server advertises. */
const COLOURS = {
	keyword: "\u001b[38;5;176m",
	string: "\u001b[38;5;114m",
	number: "\u001b[38;5;215m",
	comment: "\u001b[38;5;244m",
	operator: "\u001b[38;5;146m",
	variable: "\u001b[38;5;252m",
	["function"]: "\u001b[38;5;81m",
	parameter: "\u001b[38;5;180m",
	type: "\u001b[38;5;222m",
	namespace: "\u001b[38;5;147m",
	class: "\u001b[38;5;222m",
	property: "\u001b[38;5;117m",
	method: "\u001b[38;5;213m",
	regexp: "\u001b[38;5;203m",
};
const RESET = "\u001b[0m";

const child = spawn(binary, ["--stdio", `--clientProcessId=${process.pid}`], { stdio: ["pipe", "pipe", "pipe"] });
let buffer = Buffer.alloc(0);
const pending = new Map();
const frame = (value) => {
	const body = Buffer.from(JSON.stringify(value), "utf8");
	return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
};
child.stdout.on("data", (chunk) => {
	buffer = Buffer.concat([buffer, chunk]);
	while (true) {
		const end = buffer.indexOf("\r\n\r\n");
		if (end < 0) return;
		const length = Number(/Content-Length:\s*(\d+)/i.exec(buffer.subarray(0, end).toString())[1]);
		const start = end + 4;
		if (buffer.length < start + length) return;
		const message = JSON.parse(buffer.subarray(start, start + length).toString("utf8"));
		buffer = buffer.subarray(start + length);
		if (message.id !== undefined && pending.has(message.id)) pending.get(message.id)(message);
		else if (message.method && message.id !== undefined) {
			child.stdin.write(frame({ jsonrpc: "2.0", id: message.id, result: null }));
		}
	}
});
child.stderr.on("data", () => {});
let id = 0;
const send = (method, params) => {
	const requestId = ++id;
	const answer = new Promise((done) => pending.set(requestId, done));
	child.stdin.write(frame({ jsonrpc: "2.0", id: requestId, method, params }));
	return answer;
};

const init = await send("initialize", { processId: process.pid, capabilities: {} });
const legend = init.result?.capabilities?.semanticTokensProvider?.legend?.tokenTypes ?? [];
child.stdin.write(frame({ jsonrpc: "2.0", method: "initialized", params: {} }));
child.stdin.write(frame({
	jsonrpc: "2.0", method: "textDocument/didOpen",
	params: { textDocument: { uri: URI, languageId: "lua", version: 1, text: source } },
}));
await new Promise((done) => setTimeout(done, 500));
const answer = await send("textDocument/semanticTokens/full", { textDocument: { uri: URI } });
const data = answer.result?.data ?? [];

// Every character carries the kind the last token to cover it had.
const painted = new Map();
let line = 0, character = 0;
for (let i = 0; i + 4 < data.length; i += 5) {
	line += data[i];
	character = data[i] === 0 ? character + data[i + 1] : data[i + 1];
	const kind = legend[data[i + 3]];
	for (let at = character; at < character + data[i + 2]; at += 1) painted.set(`${line}:${at}`, kind);
}

// `JSON=1` prints the tokens themselves, so another tool can draw them.
if (process.env.JSON === "1") {
	const out = [];
	line = 0; character = 0;
	for (let i = 0; i + 4 < data.length; i += 5) {
		line += data[i];
		character = data[i] === 0 ? character + data[i + 1] : data[i + 1];
		out.push({ line, start: character, length: data[i + 2], kind: legend[data[i + 3]] });
	}
	console.log(JSON.stringify(out));
	process.exit(0);
}

const lines = source.split("\n");
const wanted = process.env.LINES ? process.env.LINES.split(",").map(Number) : lines.map((_, index) => index);
for (const index of wanted) {
	const text = lines[index] ?? "";
	let out = "";
	for (let at = 0; at < text.length; at += 1) {
		const kind = painted.get(`${index}:${at}`);
		const colour = kind ? COLOURS[kind] : "\u001b[2m";
		const last = at > 0 ? painted.get(`${index}:${at - 1}`) : null;
		out += `${(kind ?? null) === (last ?? null) ? "" : colour}${text[at]}`;
	}
	console.log(`${out}${RESET}`);
}
process.exit(0);

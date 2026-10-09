/**
 * A client-side smoke test for the wrapper's assumptions.
 *
 * It spawns the real executable with the arguments `vscode-languageclient` appends, and speaks
 * the protocol the way that library does: `Content-Length` frames on stdio, an `initialize` with
 * UTF-16 as the offered encoding, then open, hover, shutdown and exit. Chasing the protocol
 * without the arguments is what let a server that rejected `--stdio` look healthy. Run it
 * against a built binary:
 *
 *     LYE_BINARY=../lye-lsp/lye-lsp node tests/smoke.mjs
 */

import { spawn } from "node:child_process";
import { strict as assert } from "node:assert";

const BINARY = process.env.LYE_BINARY ?? "lye";
const URI = "file:///smoke.lua";
const SOURCE = ['---@type string?', 'local x = "s"', "while x do", "\tprint(x)", "end", ""].join("\n");

/** @param {object} value */
function frame(value) {
	const body = Buffer.from(JSON.stringify(value), "utf8");
	return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
}

/** Collects framed messages from a stream, in order. */
class Frames {
	/** @param {import("node:stream").Readable} stream */
	constructor(stream) {
		this.pending = Buffer.alloc(0);
		this.messages = [];
		this.waiters = [];
		stream.on("data", (chunk) => {
			this.pending = Buffer.concat([this.pending, chunk]);
			this.drain();
		});
	}

	drain() {
		while (true) {
			const headerEnd = this.pending.indexOf("\r\n\r\n");
			if (headerEnd < 0) return;
			const header = this.pending.subarray(0, headerEnd).toString("ascii");
			const length = Number(/Content-Length:\s*(\d+)/i.exec(header)?.[1]);
			if (!Number.isFinite(length)) return;
			const start = headerEnd + 4;
			if (this.pending.length < start + length) return;
			const body = this.pending.subarray(start, start + length).toString("utf8");
			this.pending = this.pending.subarray(start + length);
			this.messages.push(JSON.parse(body));
			for (const waiter of this.waiters.splice(0)) waiter();
		}
	}

	/**
	 * @param {(message: any) => boolean} predicate
	 * @param {string} what
	 */
	async wait(predicate, what) {
		const deadline = Date.now() + 10000;
		while (Date.now() < deadline) {
			const found = this.messages.find(predicate);
			if (found) return found;
			await new Promise((resolve) => setTimeout(resolve, 20));
		}
		throw new Error(`timed out waiting for ${what}`);
	}
}

// Exactly what the client spawns: it appends the transport flag and the pid to the arguments.
const child = spawn(BINARY, ["--stdio", `--clientProcessId=${process.pid}`], {
	stdio: ["pipe", "pipe", "pipe"],
});
const frames = new Frames(child.stdout);
let stderr = "";
child.stderr.on("data", (chunk) => {
	stderr += chunk.toString();
});

function send(value) {
	child.stdin.write(frame(value));
}

send({
	jsonrpc: "2.0",
	id: 1,
	method: "initialize",
	params: {
		processId: process.pid,
		clientInfo: { name: "smoke" },
		capabilities: {
			general: { positionEncodings: ["utf-16"] },
			textDocument: { hover: {}, synchronization: { dynamicRegistration: false } },
		},
	},
});

const initialized = await frames.wait((m) => m.id === 1, "initialize");
const capabilities = initialized.result?.capabilities;
assert.ok(capabilities, "initialize must return capabilities");
assert.equal(
	capabilities.positionEncoding,
	"utf-16",
	"vscode-languageclient throws unless the server agrees on utf-16",
);
assert.equal(capabilities.textDocumentSync.change, 2, "the client sends incremental changes");
assert.equal(capabilities.textDocumentSync.openClose, true);
assert.ok(capabilities.hoverProvider, "hover must be advertised");
assert.ok(capabilities.completionProvider, "completion must be advertised");
assert.ok(capabilities.semanticTokensProvider, "semantic tokens must be advertised");

send({ jsonrpc: "2.0", method: "initialized", params: {} });
send({
	jsonrpc: "2.0",
	method: "textDocument/didOpen",
	params: {
		textDocument: { uri: URI, languageId: "lua", version: 1, text: SOURCE },
	},
});

const published = await frames.wait(
	(m) => m.method === "textDocument/publishDiagnostics",
	"diagnostics",
);
assert.equal(published.params.uri, URI);
assert.equal(published.params.diagnostics.length, 0, "the opening text is clean");

send({
	jsonrpc: "2.0",
	id: 2,
	method: "textDocument/hover",
	params: { textDocument: { uri: URI }, position: { line: 3, character: 7 } },
});
const hover = await frames.wait((m) => m.id === 2, "hover");
assert.match(
	hover.result?.contents?.value ?? "",
	/x: string/,
	"hover should report the type the loop condition narrows to",
);

// Positions in the protocol are UTF-16 code units, while the source is bytes. The rocket is one
// code point in four bytes and two code units, so a server that confuses the two answers about
// the wrong token here, and reports diagnostics on the wrong line below.
const EMOJI_LINE = 'local s = "🚀"; print(s)';
const ASTRAL_SOURCE = [
	EMOJI_LINE,
	"---@type string?",
	'local y = "v"',
	"print(y)",
	"",
].join("\n");
send({
	jsonrpc: "2.0",
	method: "textDocument/didChange",
	params: {
		textDocument: { uri: URI, version: 2 },
		contentChanges: [{ text: ASTRAL_SOURCE }],
	},
});

const changed = await frames.wait(
	(m) => m.method === "textDocument/publishDiagnostics" && m.params.version === 2,
	"diagnostics after a change",
);
assert.equal(changed.params.diagnostics.length, 0, "the replacement text is clean");

// Character 22 is the `s` inside `print(s)` when the emoji counts as two: six for `local `,
// one for `s`, three for ` = `, one quote, two for the emoji, one quote, `;`, space, `print(`.
send({
	jsonrpc: "2.0",
	id: 4,
	method: "textDocument/hover",
	params: { textDocument: { uri: URI }, position: { line: 0, character: 22 } },
});
const astral = await frames.wait((m) => m.id === 4, "hover past an astral character");
assert.match(
	astral.result?.contents?.value ?? "",
	/s: string/,
	"hover lands on the argument, which is what UTF-16 counting finds there",
);
assert.equal(astral.result.range.start.line, 0, "the declaration is on the same line");
assert.equal(astral.result.range.start.character, 6, "and after `local `, counted in UTF-16");

send({
	jsonrpc: "2.0",
	method: "textDocument/didChange",
	params: {
		textDocument: { uri: URI, version: 3 },
		contentChanges: [
			{
				// Replace `"v"` on the line below the emoji with `1`.
				range: { start: { line: 2, character: 10 }, end: { line: 2, character: 13 } },
				text: "1",
			},
		],
	},
});

const broken = await frames.wait(
	(m) => m.method === "textDocument/publishDiagnostics" && m.params.version === 3,
	"diagnostics for the type error",
);
assert.equal(broken.params.diagnostics.length, 1, "assigning a number to string? is an error");
const [diagnostic] = broken.params.diagnostics;
assert.equal(diagnostic.range.start.line, 2, "the error is on the declaration line");
assert.equal(diagnostic.range.start.character, 6, "and starts at the name");
assert.equal(diagnostic.severity, 1, "it is an error, not a warning");
assert.match(diagnostic.message, /number/, diagnostic.message);

send({ jsonrpc: "2.0", id: 3, method: "shutdown" });
const shutdown = await frames.wait((m) => m.id === 3, "shutdown");
assert.equal(shutdown.result, null, "shutdown answers with null");
send({ jsonrpc: "2.0", method: "exit" });

const code = await new Promise((resolve) => child.once("exit", resolve));
assert.equal(code, 0, `exit after shutdown is 0, got ${code}; stderr: ${stderr}`);
console.log("smoke: ok");

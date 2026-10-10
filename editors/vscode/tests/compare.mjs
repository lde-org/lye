/**
 * Compare lye with other Lua language servers, action by action.
 *
 * Spawns each server with the arguments its client uses, opens the same file in each, and runs the
 * same requests through all of them: what each one advertises, what each one answers, and how long
 * it takes. Every answer is summarised, so a row of dashes means the server did not answer rather
 * than that it answered quickly.
 *
 *     node tests/compare.mjs --lye ../lye-lsp/lye-lsp --luals ~/Tools/lua-language-server \
 *         --emmylua ~/.local/bin/emmylua_ls [--iterations 20] [--json out.json]
 *
 * The three rows are the servers; the columns are the rounds of requests. A server whose binary is
 * missing is skipped with a note, so this runs with whichever of them are installed.
 *
 * Launch lines, as their own clients use them:
 *
 *   lye      --stdio
 *   luals    (nothing)
 *   emmylua  --communication stdio
 *
 * Two things cost an afternoon to find and are worth keeping: a server's requests to the client
 * have to be answered, or it waits forever (LuaLS registers capabilities before it will analyse
 * anything), and emmylua silently skips its standard library unless `capabilities.workspace` is
 * present — even as `{}` — so an initialize that looks successful answers `any` to everything.
 */

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = join(HERE, "fixtures", "benchmark.lua");
const SOURCE = readFileSync(FIXTURE, "utf8");
const ROOT = dirname(FIXTURE);
const URI = `file://${FIXTURE}`;

const args = process.argv.slice(2);
/**
 * @param {string} name
 * @param {string} fallback
 */
function option(name, fallback) {
	const at = args.indexOf(`--${name}`);
	return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
}
const ITERATIONS = Number(option("iterations", "20"));
const OUT = option("json", "");

const SERVERS = [
	{ name: "lye", binary: option("lye", ""), argv: ["--stdio"] },
	{ name: "luals", binary: option("luals", ""), argv: [] },
	{ name: "emmylua", binary: option("emmylua", ""), argv: ["--communication", "stdio"] },
].filter((server) => server.binary !== "");

/** @param {object} value */
function frame(value) {
	const body = Buffer.from(JSON.stringify(value), "utf8");
	return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
}

class Client {
	/**
	 * @param {{name: string, binary: string, argv: string[]}} spec
	 */
	constructor(spec) {
		this.spec = spec;
		this.child = spawn(spec.binary, [...spec.argv, ...(spec.extra ?? [])], {
			stdio: ["pipe", "pipe", "pipe"],
			cwd: ROOT,
		});
		this.pending = new Map();
		this.notifications = [];
		this.requestLog = [];
		this.diagnostics = [];
		this.buffer = Buffer.alloc(0);
		this.nextId = 1;
		this.stderr = "";
		this.child.stdout.on("data", (chunk) => {
			this.buffer = Buffer.concat([this.buffer, chunk]);
			this.read();
		});
		this.child.stderr.on("data", (chunk) => {
			this.stderr += chunk.toString();
		});
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
			try {
				this.dispatch(JSON.parse(body));
			} catch {
				// A server writing something this reader cannot parse is a result of its own.
			}
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
			this.diagnostics.push(message.params);
			for (const listener of this.diagnosticsWaiters.splice(0)) listener(message.params);
			return;
		}
		if (message.method && message.id !== undefined) {
			// A request from the server. LuaLS registers capabilities and EmmyLua asks for
			// configuration; a client that stays silent makes the server wait. The answers are the
			// empty ones: no settings, nothing registered.
			this.requestLog.push(message.method);
			const result = message.method === "workspace/configuration"
				? (message.params?.items ?? []).map(() => null)
				: null;
			this.child.stdin.write(frame({ jsonrpc: "2.0", id: message.id, result }));
			return;
		}
		if (message.method) this.notifications.push(message);
	}

	/** @param {string} method @param {object} params @param {number} timeout */
	request(method, params, timeout = 15000) {
		const id = this.nextId++;
		const answer = new Promise((resolve) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				resolve({ timedOut: true });
			}, timeout);
			this.pending.set(id, (message) => {
				clearTimeout(timer);
				resolve(message);
			});
		});
		this.child.stdin.write(frame({ jsonrpc: "2.0", id, method, params }));
		return answer;
	}

	/** @param {string} method @param {object} params */
	notify(method, params) {
		this.child.stdin.write(frame({ jsonrpc: "2.0", method, params }));
	}

	get diagnosticsWaiters() {
		this.waiters ??= [];
		return this.waiters;
	}

	nextDiagnostics() {
		return new Promise((resolve) => this.diagnosticsWaiters.push(resolve));
	}

	kill() {
		try {
			this.child.kill();
		} catch {
			// Already gone.
		}
	}
}

/** Where a needle is, as an LSP position, a few characters in. */
function at(needle, ahead = 0, occurrence = 1) {
	let index = -1;
	for (let seen = 0; seen < occurrence; seen++) index = SOURCE.indexOf(needle, index + 1);
	if (index < 0) throw new Error(`the fixture has no ${needle}`);
	const offset = index + ahead;
	const before = SOURCE.slice(0, offset);
	return {
		line: before.split("\n").length - 1,
		character: offset - (before.lastIndexOf("\n") + 1),
	};
}

const position = {
	mathFloor: at("math.floor", 6),
	local: at("local sum", 6),
	userFunction: at("join(labels)", 2),
	afterMathDot: at("math.floor", 5),
	afterLocalDot: at("second.y", 7),
	nameWord: at("return sum", 9),
	callArgs: at("math.floor", 11),
	callSite: at("total(numbers)", 3),
	classValue: at("first:add", 2),
};

/** @param {any} value */
function hoverText(value) {
	const contents = value?.contents;
	if (!contents) return null;
	const parts = Array.isArray(contents) ? contents : [contents];
	return parts
		.map((part) => part.value ?? part)
		.join(" ")
		.replace(/\s+/g, " ")
		.trim()
		.slice(0, 70);
}

/** @param {any} list */
function labels(list) {
	return (list?.items ?? list ?? []).map((item) => String(item.label ?? item.name));
}

/** The requests, as the rounds of the comparison. Each one summarises its own answer. */
const ACTIONS = [
	{
		name: "hover stdlib",
		method: "textDocument/hover",
		params: { position: position.mathFloor },
		summary: hoverText,
	},
	{
		name: "hover local",
		method: "textDocument/hover",
		params: { position: position.local },
		summary: hoverText,
	},
	{
		name: "hover function",
		method: "textDocument/hover",
		params: { position: position.userFunction },
		summary: hoverText,
	},
	{
		name: "completion fields",
		method: "textDocument/completion",
		params: { position: position.afterMathDot },
		summary: (value) => `${labels(value).length} items`,
	},
	{
		name: "completion class",
		method: "textDocument/completion",
		params: { position: position.afterLocalDot },
		summary: (value) => labels(value).slice(0, 6).join(" ") || "none",
	},
	{
		name: "completion name",
		method: "textDocument/completion",
		params: { position: position.nameWord },
		summary: (value) => `${labels(value).length} items`,
	},
	{
		name: "signature help",
		method: "textDocument/signatureHelp",
		params: { position: position.callArgs },
		summary: (value) => value?.signatures?.[0]?.label ?? null,
	},
	{
		name: "definition",
		method: "textDocument/definition",
		params: { position: position.callSite },
		summary: (value) => (Array.isArray(value) ? `${value.length} places` : value ? "1 place" : null),
	},
	{
		name: "type definition",
		method: "textDocument/typeDefinition",
		params: { position: position.classValue },
		summary: (value) => (Array.isArray(value) ? `${value.length} places` : value ? "1 place" : null),
	},
	{
		name: "references",
		method: "textDocument/references",
		params: { position: position.callSite, context: { includeDeclaration: true } },
		summary: (value) => `${(value ?? []).length} places`,
	},
	{
		name: "rename",
		method: "textDocument/rename",
		params: { position: position.callSite, newName: "tally" },
		summary: (value) => {
			const edits = value?.changes?.[URI] ?? Object.values(value?.changes ?? {})[0];
			return edits ? `${edits.length} edits` : null;
		},
	},
	{
		name: "highlight",
		method: "textDocument/documentHighlight",
		params: { position: position.callSite },
		summary: (value) => `${(value ?? []).length} places`,
	},
	{
		name: "symbols",
		method: "textDocument/documentSymbol",
		params: {},
		summary: (value) => `${(value ?? []).length} symbols`,
	},
	{
		name: "folding",
		method: "textDocument/foldingRange",
		params: {},
		summary: (value) => `${(value ?? []).length} ranges`,
	},
	{
		name: "selection range",
		method: "textDocument/selectionRange",
		params: { positions: [position.callSite] },
		summary: (value) => {
			let depth = 0;
			for (let node = value?.[0]; node; node = node.parent) depth++;
			return `${depth} deep`;
		},
	},
	{
		name: "inlay hints",
		method: "textDocument/inlayHint",
		params: { range: { start: { line: 0, character: 0 }, end: { line: 200, character: 0 } } },
		summary: (value) => `${(value ?? []).length} hints`,
	},
	{
		name: "semantic tokens",
		method: "textDocument/semanticTokens/full",
		params: {},
		summary: (value) => `${(value?.data ?? []).length / 5} tokens`,
	},
	{
		name: "call hierarchy",
		method: "textDocument/prepareCallHierarchy",
		params: { position: position.callSite },
		summary: (value) => `${(value ?? []).length} items`,
	},
	{
		name: "workspace symbols",
		method: "workspace/symbol",
		params: { query: "" },
		summary: (value) => `${(value ?? []).length} symbols`,
	},
	{
		name: "implementation",
		method: "textDocument/implementation",
		params: { position: position.classValue },
		summary: (value) => `${(value ?? []).length} places`,
	},
	{
		name: "code lens",
		method: "textDocument/codeLens",
		params: {},
		summary: (value) => `${(value ?? []).length} lenses`,
	},
	{
		// What an editor sends: the diagnostics it is showing for the range, which is what a quickfix
		// is a fix *for*. A server that offered actions without them would be guessing.
		name: "code actions",
		method: "textDocument/codeAction",
		build: (client) => ({
			range: { start: position.callSite, end: position.callSite },
			context: {
				diagnostics: (client.diagnostics.at(-1)?.diagnostics ?? []).slice(0, 5),
			},
		}),
		summary: (value) => `${(value ?? []).length} actions`,
	},
	{
		name: "document colors",
		method: "textDocument/documentColor",
		params: {},
		summary: (value) => `${(value ?? []).length} colors`,
	},
	{
		name: "formatting",
		method: "textDocument/formatting",
		params: { options: { tabSize: 4, insertSpaces: false } },
		summary: (value) => (value == null ? null : `${value.length} edits`),
	},
];

/** Rounds a request through `withUri`. */
function withDocument(action) {
	const params = { textDocument: { uri: URI }, ...action.params };
	return params;
}

/**
 * @param {{name: string, binary: string, argv: string[]}} spec
 * @returns {Promise<any>}
 */
async function measure(spec) {
	const client = new Client(spec);
	const report = { name: spec.name, binary: spec.binary, actions: {}, capabilities: null, skipped: [] };

	const initialized = await client.request("initialize", {
		processId: process.pid,
		clientInfo: { name: "lye-compare" },
		rootUri: `file://${ROOT}`,
		workspaceFolders: [{ uri: `file://${ROOT}`, name: "fixture" }],
		capabilities: {
			general: { positionEncodings: ["utf-16"] },
			textDocument: {
				hover: { contentFormat: ["markdown", "plaintext"] },
				completion: { completionItem: { documentationFormat: ["markdown", "plaintext"] } },
				signatureHelp: { signatureInformation: { documentationFormat: ["markdown"] } },
				semanticTokens: { requests: { full: true, range: true }, tokenTypes: [], tokenModifiers: [], formats: ["relative"] },
				publishDiagnostics: {},
				synchronization: { dynamicRegistration: false },
			},
			workspace: { workspaceFolders: true, symbol: {}, configuration: true },
		},
		initializationOptions: {},
	}, 60000);
	if (initialized.error || !initialized.result) {
		report.skipped.push(`initialize failed: ${JSON.stringify(initialized.error ?? initialized)}`);
		client.kill();
		return report;
	}
	report.capabilities = initialized.result.capabilities ?? {};
	client.syncKind = report.capabilities.textDocumentSync?.change
		?? report.capabilities.textDocumentSync ?? 2;
	client.notify("initialized", {});
	client.notify("textDocument/didOpen", {
		textDocument: { uri: URI, languageId: "lua", version: 1, text: SOURCE },
	});

	// Give the server time to read the document and analyse it, which is what the first answer
	// waits on. LuaLS indexes on open, so this is generous rather than tight.
	await Promise.race([
		client.nextDiagnostics(),
		new Promise((resolve) => setTimeout(resolve, 20000)),
	]);

	for (const action of ACTIONS) {
		const params = withDocument(action.build ? action.build(client) : action);
		const samples = [];
		let summary = null;
		let note = "";
		try {
			const warmed = await client.request(action.method, params, 20000);
			if (warmed.timedOut) {
				note = "no answer in 20s";
			} else if (warmed.error) {
				note = `error ${warmed.error.code}`;
			} else {
				summary = action.summary(warmed.result);
				if (summary == null) note = "answered nothing";
				for (let index = 0; index < ITERATIONS; index++) {
					const started = process.hrtime.bigint();
					const answer = await client.request(action.method, params, 20000);
					if (answer.timedOut) break;
					samples.push(Number(process.hrtime.bigint() - started) / 1e6);
				}
			}
		} catch (error) {
			note = String(error.message ?? error).slice(0, 60);
		}

		samples.sort((left, right) => left - right);
		report.actions[action.name] = {
			summary,
			note,
			runs: samples.length,
			p50: samples.length ? +samples[Math.floor(samples.length / 2)].toFixed(2) : null,
			p95: samples.length ? +samples[Math.min(samples.length - 1, Math.floor(samples.length * 0.95))].toFixed(2) : null,
		};
	}

	// A keystroke: the edit, the incremental change, and the diagnostics that come back.
	const syncKind = client.syncKind;
	const typed = "local probe = 1\n";
	const samples = [];
	for (let index = 0; index < Math.min(ITERATIONS, 10); index++) {
		const started = process.hrtime.bigint();
		const drawn = client.nextDiagnostics();
		client.notify("textDocument/didChange", {
			textDocument: { uri: URI, version: 2 + index },
			contentChanges: [client.syncKind === 1
				? { text: typed + SOURCE }
				: { range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } }, text: typed }],
		});
		const settled = await Promise.race([drawn, new Promise((resolve) => setTimeout(resolve, 20000))]);
		if (!settled) break;
		samples.push(Number(process.hrtime.bigint() - started) / 1e6);
		const undone = client.nextDiagnostics();
		client.notify("textDocument/didChange", {
			textDocument: { uri: URI, version: 100 + index },
			contentChanges: [client.syncKind === 1
				? { text: SOURCE }
				: { range: { start: { line: 0, character: 0 }, end: { line: 0, character: typed.length - 1 } }, text: "" }],
		});
		await Promise.race([undone, new Promise((resolve) => setTimeout(resolve, 20000))]);
	}
	samples.sort((left, right) => left - right);
	report.actions["keystroke → diagnostics"] = {
		summary: `${client.diagnostics.length} publishes`,
		note: "",
		runs: samples.length,
		p50: samples.length ? +samples[Math.floor(samples.length / 2)].toFixed(2) : null,
		p95: samples.length ? +samples[Math.min(samples.length - 1, Math.floor(samples.length * 0.95))].toFixed(2) : null,
	};

	await client.request("shutdown", {}, 5000);
	client.notify("exit", {});
	setTimeout(() => client.kill(), 200);
	return report;
}

const reports = [];
for (const spec of SERVERS) {
	process.stdout.write(`${spec.name}: measuring… `);
	const report = await measure(spec);
	reports.push(report);
	console.log(report.skipped.length ? `skipped (${report.skipped.join("; ")})` : "done");
}

// The capabilities each server advertises, which is the feature list a client can rely on.
const CAPABILITIES = [
	"hoverProvider", "completionProvider", "signatureHelpProvider", "definitionProvider",
	"typeDefinitionProvider", "implementationProvider", "declarationProvider", "referencesProvider",
	"documentHighlightProvider", "documentSymbolProvider", "workspaceSymbolProvider",
	"renameProvider", "foldingRangeProvider", "selectionRangeProvider", "inlayHintProvider",
	"callHierarchyProvider", "codeActionProvider", "codeLensProvider", "documentLinkProvider",
	"documentFormattingProvider", "documentRangeFormattingProvider", "documentOnTypeFormattingProvider",
	"semanticTokensProvider", "colorProvider",
];
const capabilityTable = {};
for (const report of reports) {
	capabilityTable[report.name] = Object.fromEntries(CAPABILITIES.map((name) => {
		const held = report.capabilities?.[name];
		return [name, held ? (typeof held === "object" ? "yes" : "yes") : "—"];
	}));
}

console.log("");
console.log(`${"action".padEnd(24)}${reports.map((report) => report.name.padStart(28)).join("")}`);
for (const action of [...ACTIONS.map((one) => one.name), "keystroke → diagnostics"]) {
	const cells = reports.map((report) => {
		const held = report.actions[action];
		if (!held) return "—".padStart(28);
		const text = held.note ? `[${held.note}]` : (held.summary ?? "—");
		const time = held.p50 == null ? "" : ` ${held.p50}ms`;
		return `${text}${time}`.slice(0, 28).padStart(28);
	});
	console.log(`${action.padEnd(24)}${cells.join("")}`);
}

console.log("");
console.log("capability".padEnd(34) + reports.map((report) => report.name.padStart(10)).join(""));
for (const name of CAPABILITIES) {
	const cells = reports.map((report) => (capabilityTable[report.name][name] ?? "—").padStart(10));
	if (cells.some((cell) => cell.trim() !== "—")) console.log(name.padEnd(34) + cells.join(""));
}

if (OUT) writeFileSync(OUT, `${JSON.stringify({ fixture: FIXTURE, iterations: ITERATIONS, reports, capabilityTable }, null, "\t")}\n`);
process.exit(0);

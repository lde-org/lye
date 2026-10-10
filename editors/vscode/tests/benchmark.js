/**
 * Measures what an editor waits for, from inside a real VS Code instance.
 *
 * This is an extension-host test: it activates the lye extension, opens a file that uses the
 * standard library, and times the commands VS Code itself runs for hover, completion, definitions
 * and symbols, plus the round trip from an edit to the diagnostics it draws. It needs no display —
 * VS Code runs with `--ozone-platform=headless`:
 *
 *     code --user-data-dir=/tmp/lye-vscode/user --extensions-dir=/tmp/lye-vscode/ext \
 *         --ozone-platform=headless --disable-gpu --no-sandbox --disable-workspace-trust \
 *         --extensionDevelopmentPath=$PWD --extensionTestsPath=$PWD/tests/benchmark.js \
 *         /path/to/workspace
 *
 * `LYE_BENCH_OUT` is where the JSON goes, `LYE_BENCH_FILE` picks the file to open (relative to the
 * workspace, `benchmark.lua` by default) and `LYE_BENCH_ITERATIONS` the sample count.
 */
const vscode = require("vscode");
const fs = require("node:fs");
const { performance } = require("node:perf_hooks");

const OUT = process.env.LYE_BENCH_OUT ?? "/tmp/lye-vscode/results.json";
const ITERATIONS = Number(process.env.LYE_BENCH_ITERATIONS ?? "30");

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function summarize(samples) {
	const sorted = [...samples].sort((a, b) => a - b);
	const at = (fraction) => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
	return {
		runs: sorted.length,
		min: +sorted[0].toFixed(3),
		p50: +at(0.5).toFixed(3),
		p95: +at(0.95).toFixed(3),
		max: +sorted.at(-1).toFixed(3),
		mean: +(sorted.reduce((sum, value) => sum + value, 0) / sorted.length).toFixed(3),
	};
}

async function run() {
	const report = { vscode: vscode.version, iterations: ITERATIONS, results: {}, checks: {} };
	try {
		await measure(report);
	} catch (error) {
		report.error = String(error?.stack ?? error);
	}
	fs.writeFileSync(OUT, `${JSON.stringify(report, null, "\t")}\n`);
}

/** @param {any} report */
async function measure(report) {
	const extension = vscode.extensions.getExtension("lde-org.lye");
	if (!extension) throw new Error("the lye extension is not installed");
	const activated = performance.now();
	await extension.activate();
	report.results["extension activation"] = summarize([performance.now() - activated]);

	const folder = vscode.workspace.workspaceFolders[0].uri;
	const uri = vscode.Uri.joinPath(folder, process.env.LYE_BENCH_FILE ?? "benchmark.lua");
	const document = await vscode.workspace.openTextDocument(uri);
	const editor = await vscode.window.showTextDocument(document);
	const text = document.getText();

	/** The first of several needles the file actually contains, so one benchmark runs on any file. */
	function firstOf(candidates) {
		for (const candidate of candidates) if (text.includes(candidate)) return candidate;
		throw new Error(`the file has none of ${candidates.join(", ")}`);
	}

	/** The position a few characters into one of several needles, which is where a cursor would be. */
	function inside(candidates, ahead) {
		const needle = firstOf(candidates);
		const at = text.indexOf(needle);
		const before = text.slice(0, at + (ahead ?? 0));
		return new vscode.Position(before.split("\n").length - 1, before.length - before.lastIndexOf("\n") - 1);
	}

	// The server needs a moment to open the document; hover is how we know it is answering.
	const opened = performance.now();
	let ready = false;
	while (performance.now() - opened < 30000) {
		const hovers = await vscode.commands.executeCommand("vscode.executeHoverProvider", uri, inside(["math.floor"], 6));
		const symbols = await vscode.commands.executeCommand("vscode.executeDocumentSymbolProvider", uri);
		if (hovers?.length && symbols?.length) {
			ready = true;
			report.results["server ready after open"] = summarize([performance.now() - opened]);
			break;
		}
		await sleep(50);
	}
	if (!ready) throw new Error("the language server never answered");

	/** @param {string} name @param {() => Promise<any>} action @param {(value: any) => void} check */
	async function bench(name, action, check) {
		await action();
		const samples = [];
		for (let index = 0; index < ITERATIONS; index++) {
			const started = performance.now();
			const value = await action();
			samples.push(performance.now() - started);
			if (index === 0 && check) check(value);
		}
		report.results[name] = summarize(samples);
	}

	const hoverPosition = inside(["math.floor"], 6);
	await bench("hover (stdlib call)", () => vscode.commands.executeCommand("vscode.executeHoverProvider", uri, hoverPosition), (hovers) => {
		report.checks.hover = hovers.map((hover) => hover.contents.map((part) => part.value ?? String(part)).join("")).join("\n");
	});

	const localHover = inside(["sum = sum", "scaled = value"], 2);
	await bench("hover (local)", () => vscode.commands.executeCommand("vscode.executeHoverProvider", uri, localHover), (hovers) => {
		report.checks["hover local"] = hovers.map((hover) => hover.contents.map((part) => part.value ?? String(part)).join("")).join("\n");
	});

	const mathDot = inside(["math.floor"], 5);
	await bench("completion after math.", () => vscode.commands.executeCommand("vscode.executeCompletionItemProvider", uri, mathDot, "."), (list) => {
		const labels = list.items.map((item) => item.label.toString());
		report.checks["completion math."] = { count: labels.length, has: ["floor", "abs", "pi"].filter((name) => labels.includes(name)) };
	});

	const localDot = inside(["second.y", "widget.id"], 7);
	await bench("completion after a local dot", () => vscode.commands.executeCommand("vscode.executeCompletionItemProvider", uri, localDot, "."), (list) => {
		const labels = list.items.map((item) => item.label.toString());
		report.checks["completion local dot"] = { count: labels.length, has: ["x", "y"].filter((name) => labels.includes(name)) };
	});

	const namePosition = inside(["return sum", "return tonumber"], 9);
	await bench("completion of a name", () => vscode.commands.executeCommand("vscode.executeCompletionItemProvider", uri, namePosition), (list) => {
		const labels = list.items.map((item) => item.label.toString());
		report.checks["completion name"] = {
			count: labels.length,
			has: ["math", "string", "table", "print", "numbers"].filter((name) => labels.includes(name)),
		};
	});

	await bench("go to definition", () => vscode.commands.executeCommand("vscode.executeDefinitionProvider", uri, inside(["total(numbers)", "step1(1)"], 3)), (locations) => {
		report.checks.definition = locations.length;
	});

	await bench("document symbols", () => vscode.commands.executeCommand("vscode.executeDocumentSymbolProvider", uri), (symbols) => {
		report.checks.symbols = symbols.length;
	});

	// The keystroke path: an edit, the incremental change, the analysis, the diagnostics.
	const typed = "local extra = numbers[1]\n";
	const line = Math.max(0, document.lineCount - 2);
	const samples = [];
	for (let index = 0; index < Math.min(ITERATIONS, 15); index++) {
		const started = performance.now();
		const drawn = new Promise((resolve) => {
			const subscription = vscode.languages.onDidChangeDiagnostics(() => {
				subscription.dispose();
				resolve();
			});
		});
		await editor.edit((edit) => edit.insert(new vscode.Position(line, 0), typed));
		await drawn;
		samples.push(performance.now() - started);
		await editor.edit((edit) => edit.delete(new vscode.Range(new vscode.Position(line, 0), new vscode.Position(line, typed.length - 1))));
		await sleep(20);
	}
	report.results["edit to diagnostics"] = summarize(samples);
	report.checks.diagnostics = vscode.languages.getDiagnostics(uri).map((diagnostic) => diagnostic.message);
}
module.exports = { run };

/**
 * The VS Code wrapper: start `lye` over stdio and let it answer.
 *
 * Everything the editor shows comes from the server, so this file only decides which documents
 * to attach to, where the executable is, and what to say when it is missing.
 */

import * as vscode from "vscode";
import {
	LanguageClient,
	LanguageClientOptions,
	ServerOptions,
	TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

/** `lye` with no arguments serves the protocol on stdio; a path argument would run a check. */
function serverOptions(command: string): ServerOptions {
	return { command, args: [], transport: TransportKind.stdio };
}

function clientOptions(): LanguageClientOptions {
	const selector = [
		{ scheme: "file", language: "lua" },
		{ scheme: "untitled", language: "lua" },
	];
	return { documentSelector: selector };
}

async function start(context: vscode.ExtensionContext): Promise<void> {
	const command = vscode.workspace.getConfiguration("lye").get<string>("serverPath", "lye");
	client = new LanguageClient("lye", "lye", serverOptions(command), clientOptions());
	// The client appends its own arguments, so what actually runs is not the command alone. A
	// start failure is otherwise reported without ever showing the command line that failed.
	client.outputChannel.appendLine(`lye: starting ${command}`);

	try {
		await client.start();
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		client = undefined;
		// The usual cause is that lye is not installed, and the server's own error is the
		// only thing that says which path it looked for.
		const choice = await vscode.window.showErrorMessage(
			`lye could not start: ${message}`,
			"Set the path",
			"Install instructions",
		);
		if (choice === "Set the path") {
			await vscode.commands.executeCommand("workbench.action.openSettings", "lye.serverPath");
		} else if (choice === "Install instructions") {
			await vscode.env.openExternal(
				vscode.Uri.parse("https://github.com/lde-org/lye#install"),
			);
		}
	}

	context.subscriptions.push(
		vscode.workspace.onDidChangeConfiguration(async (event) => {
			if (!event.affectsConfiguration("lye.serverPath")) return;
			await stop();
			await start(context);
		}),
	);
}

async function stop(): Promise<void> {
	const running = client;
	client = undefined;
	if (running) await running.stop();
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
	await start(context);
}

export async function deactivate(): Promise<void> {
	await stop();
}

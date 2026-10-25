// nedls in VS Code: starts ned's language server for the languages chosen (nedls.languages), passes the settings
// on, and restarts it when they change.
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client = null;
let output = null;

function options() {
  const c = vscode.workspace.getConfiguration('nedls');
  const o = {};
  for (const k of ['inlayHints', 'parameterHints', 'raisesHints', 'checkOnSave', 'liveDiagnostics', 'nedSettings']) {
    o[k] = c.get(k);
  }
  const w = c.get('formatLineLength');
  if (typeof w === 'number') o.formatLineLength = w;
  return o;
}

async function start() {
  const c = vscode.workspace.getConfiguration('nedls');
  const command = c.get('path') || 'nedls';
  const selector = [];
  for (const l of c.get('languages') || ['nim']) {
    selector.push({ scheme: 'file', language: l }, { scheme: 'untitled', language: l });
  }
  if (!output) output = vscode.window.createOutputChannel('nedls');
  client = new LanguageClient('nedls', 'nedls', { command, args: ['--stdio'] }, {
    documentSelector: selector,
    initializationOptions: options(),
    synchronize: {
      configurationSection: 'nedls',
      fileEvents: vscode.workspace.createFileSystemWatcher('**/{*.nim,*.nims,*.nimble,nim.cfg,.ned/settings.json}')
    },
    outputChannel: output
  });
  try {
    await client.start();
  } catch (e) {
    client = null;
    const pick = await vscode.window.showErrorMessage(
      `nedls did not start (${command}): ${e.message || e}. Is it installed? (nimble install ned, or set nedls.path)`,
      'Set nedls.path');
    if (pick) vscode.commands.executeCommand('workbench.action.openSettings', 'nedls.path');
  }
}

async function stop() {
  if (client) {
    const c = client;
    client = null;
    try { await c.stop(); } catch (_) { /* (it may have ended already) */ }
  }
}

async function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('nedls.restart', async () => { await stop(); await start(); }),
    vscode.commands.registerCommand('nedls.showOutput', () => output && output.show()),
    vscode.workspace.onDidChangeConfiguration(async (e) => {
      // (which program, which languages: a new server; the rest goes to the running one)
      if (e.affectsConfiguration('nedls.path') || e.affectsConfiguration('nedls.languages')) {
        await stop();
        await start();
      }
    }));
  await start();
}

function deactivate() { return stop(); }

module.exports = { activate, deactivate };

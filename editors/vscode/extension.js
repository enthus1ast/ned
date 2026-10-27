// nedls in VS Code: starts ned's language server for the languages chosen (nedls.languages), passes the settings
// on, and restarts it when they change. The language client is the extension's own (client.js, features.js,
// convert.js, lsp.js) — plain JavaScript and the vscode API, no npm packages — so the .vsix is made with Python
// alone (tests/build/vscode.sh).
'use strict';

const vscode = require('vscode');
const { Client } = require('./client');

let client = null;
let output = null;
let queue = Promise.resolve();

// the settings nedls reads at start (initializationOptions); the same ones go to it again when they change
function options() {
  const c = vscode.workspace.getConfiguration('nedls');
  const o = {};
  for (const k of ['inlayHints', 'parameterHints', 'raisesHints', 'checkOnSave', 'liveDiagnostics', 'workspaceDiagnostics',
                   'nedSettings']) {
    o[k] = c.get(k);
  }
  const w = c.get('formatLineLength');
  if (typeof w === 'number') o.formatLineLength = w;
  return o;
}

// (one start or stop at a time: a restart asked for twice must not leave two servers running)
function serial(fn) {
  const p = queue.then(fn);
  queue = p.catch(() => {});
  return p;
}

async function start() {
  const c = vscode.workspace.getConfiguration('nedls');
  const command = c.get('path') || 'nedls';
  const cl = new Client({
    command,
    languages: c.get('languages') || ['nim'],
    output,
    trace: c.get('trace.server') || 'off',
    initializationOptions: options(),
    onCrash: crashed
  });
  client = cl;
  try {
    await cl.start();
  } catch (e) {
    if (client === cl) client = null;
    if (cl.stopping) return;               // (stopped while it started: a restart, not a failure)
    cl.log(`nedls did not start: ${e.message || e}`);
    // (not awaited: the message stays up as long as the person likes, and nothing waits for it)
    vscode.window.showErrorMessage(
      `nedls did not start (${command}): ${e.message || e}. Is it installed? (nimble install ned, or set nedls.path)`,
      'Set nedls.path').then((pick) => {
      if (pick) vscode.commands.executeCommand('workbench.action.openSettings', 'nedls.path');
    });
  }
}

async function stop() {
  if (!client) return;
  const c = client;
  client = null;
  try {
    await c.stop();
  } catch (_) {
    // (it may have ended already)
  }
}

function restart() {
  return serial(async () => {
    await stop();
    await start();
  });
}

// The server ended on its own. It is not started again by itself — a server that crashes at once would crash
// again and again — the person gets a button for it, and its log.
function crashed(cl, code, signal) {
  if (client !== cl) return;
  client = null;
  const how = signal ? `signal ${signal}` : `exit code ${code}`;
  vscode.window.showErrorMessage(`nedls stopped unexpectedly (${how}).`, 'Restart', 'Show the log').then((pick) => {
    if (pick === 'Restart') restart();
    else if (pick === 'Show the log') output.show();
  });
}

async function activate(context) {
  output = vscode.window.createOutputChannel('nedls');
  context.subscriptions.push(
    vscode.commands.registerCommand('nedls.restart', restart),
    vscode.commands.registerCommand('nedls.showOutput', () => output.show()),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration('nedls')) return;
      // (which program, which languages: a new server; the rest goes to the running one)
      if (e.affectsConfiguration('nedls.path') || e.affectsConfiguration('nedls.languages')) {
        restart();
      } else if (client) {
        client.configurationChanged(e);
      }
    }));
  await serial(start);
}

// (the Output channel is closed last: stopping writes to it)
function deactivate() {
  return serial(stop).then(() => {
    if (output) output.dispose();
    output = null;
  });
}

module.exports = { activate, deactivate };

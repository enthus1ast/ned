// One run of nedls: the process, the initialize handshake, the documents kept in step with it, what it asks of
// VS Code (messages, edits, settings, progress), and the providers for what it can do (features.js). A restart is
// a new Client.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const { Connection, ErrorCodes, isCancel } = require('./lsp');
const p2c = require('./convert');
const { c2p } = p2c;
const features = require('./features');

// the files whose changes on disk matter to nedls: its project's modules, configuration and ned's settings
const WATCH = '**/{*.nim,*.nims,*.nimble,nim.cfg,.ned/settings.json}';

// textDocumentSync's kinds of change (1 is the whole text each time)
const SYNC_NONE = 0;
const SYNC_INCREMENTAL = 2;

function withTimeout(promise, ms) {
  let timer;
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`no answer in ${ms / 1000} s`)), ms);
  })]).finally(() => clearTimeout(timer));
}

function folderOf(f) {
  return { uri: f.uri.toString(), name: f.name };
}

// the settings under "nedls" as plain JSON (VS Code's configuration objects are proxies)
function settings(section, scope) {
  const v = vscode.workspace.getConfiguration(undefined, scope).get(section);
  return v === undefined ? null : JSON.parse(JSON.stringify(v));
}

class Client {
  // command: the program; languages: nedls.languages; output: the Output channel; trace: nedls.trace.server;
  // initializationOptions: the nedls.* settings for initialize; onCrash(client, code, signal): the server ended
  // on its own.
  constructor({ command, languages, output, trace, initializationOptions, onCrash }) {
    this.command = command;
    this.languages = languages;
    this.output = output;
    this.trace = trace || 'off';
    this.initializationOptions = initializationOptions;
    this.onCrash = onCrash;
    this.proc = null;
    this.conn = null;
    this.caps = {};
    this.ready = false;
    this.stopping = false;
    this.subs = [];
    this.open = new Set();          // the documents nedls was told about (didOpen), by URI
    this.refresh = {};              // the providers' change events, for the server's */refresh requests
    this.progress = new Map();      // work done progress shown in the status bar, by token
    this.diagnostics = vscode.languages.createDiagnosticCollection('nedls');
    this.selector = [];
    for (const l of this.languages) {
      this.selector.push({ scheme: 'file', language: l }, { scheme: 'untitled', language: l });
    }
  }

  log(line) {
    try {
      this.output.appendLine(line);
    } catch (_) {
      // (the channel is gone: VS Code is shutting the extension down)
    }
  }

  // ── starting ──

  // Resolves when nedls is running and VS Code has its providers; rejects (the process killed) when it could not
  // be started or did not answer initialize.
  async start() {
    try {
      await this.launch();
    } catch (e) {
      if (e && e.code === ErrorCodes.ConnectionClosed && this.exited) {
        // (it ended before it answered: how it ended says more than "the connection closed")
        await Promise.race([this.exited, new Promise((r) => setTimeout(r, 500))]);
        const p = this.proc;
        if (p && (p.exitCode !== null || p.signalCode !== null)) {
          e = new Error(`it ended at once (${p.signalCode ? 'signal ' + p.signalCode : 'exit code ' + p.exitCode})`);
        }
      }
      this.teardown();
      this.closeDiagnostics();
      if (this.proc && this.proc.exitCode === null && this.proc.signalCode === null) this.proc.kill();
      if (this.conn) this.conn.close();
      throw e;
    }
  }

  async launch() {
    const folders = vscode.workspace.workspaceFolders || [];
    const root = folders.find((f) => f.uri.scheme === 'file');
    const cwd = root && fs.existsSync(root.uri.fsPath) ? root.uri.fsPath : undefined;
    const proc = cp.spawn(this.command, ['--stdio'], { cwd, env: process.env, windowsHide: true });
    this.proc = proc;
    this.exited = new Promise((resolve) => {
      proc.on('exit', (code, signal) => {
        this.log(`nedls ended (${signal ? 'signal ' + signal : 'exit code ' + code})`);
        resolve();
        if (!this.stopping && this.ready) this.crashed(code, signal);
      });
      proc.on('error', () => { if (!proc.pid) resolve(); });   // (never started: there will be no exit)
    });
    // (a program that is not there: spawn says so with an event, not an exception)
    const failed = new Promise((_, reject) => {
      proc.on('error', (e) => reject(e));
      proc.on('exit', (code, signal) => reject(new Error(`it ended at once (${signal ? 'signal ' + signal
                                                                                     : 'exit code ' + code})`)));
    });
    failed.catch(() => {});
    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (s) => {                     // (nedls's own log)
      try { this.output.append(s); } catch (_) { /* (the channel is gone) */ }
    });

    const conn = new Connection(proc.stdout, proc.stdin, (line) => this.log(line));
    conn.trace = this.trace;
    this.conn = conn;
    this.handleServer(conn);
    if (proc.pid) this.log(`nedls started (pid ${proc.pid}): ${this.command} --stdio`);

    const init = await Promise.race([withTimeout(conn.request('initialize', this.initializeParams(folders)), 60000),
                                     failed]);
    if (this.stopping) throw new Error('stopped while starting');
    this.caps = (init && init.capabilities) || {};
    const info = init && init.serverInfo;
    if (info) this.log(`${info.name}${info.version ? ' ' + info.version : ''} is running`);
    if (this.caps.positionEncoding && this.caps.positionEncoding !== 'utf-16') {
      this.log(`nedls chose positions in ${this.caps.positionEncoding}, which this client did not offer`);
    }
    conn.notify('initialized', {});
    this.ready = true;

    features.register(this, this.caps, this.selector, this.subs);
    this.syncDocuments();
    this.watchFiles();
    const wf = this.caps.workspace && this.caps.workspace.workspaceFolders;
    if (wf && wf.changeNotifications) {
      this.subs.push(vscode.workspace.onDidChangeWorkspaceFolders((e) => this.notify(
        'workspace/didChangeWorkspaceFolders',
        { event: { added: e.added.map(folderOf), removed: e.removed.map(folderOf) } })));
    }
  }

  initializeParams(folders) {
    const first = folders[0];
    return {
      processId: process.pid,
      clientInfo: { name: vscode.env.appName || 'VS Code', version: vscode.version },
      locale: vscode.env.language,
      rootPath: first && first.uri.scheme === 'file' ? first.uri.fsPath : null,
      rootUri: first ? first.uri.toString() : null,
      workspaceFolders: folders.length ? folders.map(folderOf) : null,
      capabilities: features.clientCapabilities(),
      initializationOptions: this.initializationOptions,
      trace: this.trace
    };
  }

  // ── what nedls asks and tells ──

  handleServer(conn) {
    conn.onNotification('textDocument/publishDiagnostics', (p) => {
      if (this.diagnostics) this.diagnostics.set(p2c.uri(p.uri), (p.diagnostics || []).map(p2c.diagnostic));
    });
    conn.onNotification('window/logMessage', (p) => {
      const level = ['', 'Error', 'Warning', 'Info', 'Log', 'Debug'][p.type] || 'Log';
      this.log(`[${level} - ${new Date().toLocaleTimeString()}] ${p.message}`);
    });
    conn.onNotification('window/showMessage', (p) => { this.show(p.type, p.message, []); });
    conn.onRequest('window/showMessageRequest', async (p) => {
      // (the button picked goes back as nedls sent it, with any properties of its own)
      const pick = await this.show(p.type, p.message, Array.isArray(p.actions) ? p.actions : []);
      return pick || null;
    });
    conn.onRequest('window/workDoneProgress/create', () => null);
    conn.onNotification('$/progress', (p) => this.showProgress(p));
    conn.onNotification('$/logTrace', (p) => this.log(p.message + (p.verbose ? '\n' + p.verbose : '')));
    conn.onRequest('workspace/applyEdit', (p) => this.applyEdit(p));
    conn.onRequest('workspace/configuration', (p) => (p.items || []).map((it) =>
      (it.section ? settings(it.section, it.scopeUri ? vscode.Uri.parse(it.scopeUri) : undefined) : null)));
    conn.onRequest('workspace/workspaceFolders', () => {
      const folders = vscode.workspace.workspaceFolders;
      return folders ? folders.map(folderOf) : null;
    });
    // (we register nothing at run time — every capability is static — but a server may still ask: yes, nothing)
    conn.onRequest('client/registerCapability', () => null);
    conn.onRequest('client/unregisterCapability', () => null);
    for (const [method, name] of [['workspace/semanticTokens/refresh', 'semanticTokens'],
                                  ['workspace/inlayHint/refresh', 'inlayHints'],
                                  ['workspace/codeLens/refresh', 'codeLens']]) {
      conn.onRequest(method, () => {
        if (this.refresh[name]) this.refresh[name].fire();
        return null;
      });
    }
  }

  show(type, message, items) {
    const w = vscode.window;
    if (type === 1) return w.showErrorMessage(message, ...items);
    if (type === 2) return w.showWarningMessage(message, ...items);
    return w.showInformationMessage(message, ...items);
  }

  // Work done progress, in the status bar: "begin" shows it, "report" changes its message, "end" takes it away.
  showProgress(p) {
    const key = JSON.stringify(p.token);
    const v = p.value || {};
    const say = (x) => (typeof x.percentage === 'number' ? `${x.message || ''} ${x.percentage}%`.trim() : x.message);
    if (v.kind === 'begin') {
      if (this.progress.has(key)) return;
      let finish;
      const ended = new Promise((resolve) => { finish = resolve; });
      const entry = { report: null, finish, first: say(v) };
      this.progress.set(key, entry);
      vscode.window.withProgress({ location: vscode.ProgressLocation.Window, title: v.title || 'nedls' }, (progress) => {
        entry.report = (m) => progress.report({ message: m });
        if (entry.first) entry.report(entry.first);
        return ended;
      });
    } else if (v.kind === 'report') {
      const entry = this.progress.get(key);
      if (!entry) return;
      if (entry.report) entry.report(say(v));
      else entry.first = say(v);
    } else if (v.kind === 'end') {
      const entry = this.progress.get(key);
      if (!entry) return;
      this.progress.delete(key);
      entry.finish();
    }
  }

  async applyEdit(p) {
    const we = (p && p.edit) || {};
    // An edit made for a text that has changed since is refused, not put on the wrong lines.
    for (const ch of we.documentChanges || []) {
      if (!ch.textDocument || typeof ch.textDocument.version !== 'number') continue;
      const u = p2c.uri(ch.textDocument.uri).toString();
      const doc = vscode.workspace.textDocuments.find((d) => d.uri.toString() === u);
      if (doc && doc.version !== ch.textDocument.version) {
        return { applied: false, failureReason: `${doc.uri.fsPath || u} has changed since` };
      }
    }
    try {
      const applied = await vscode.workspace.applyEdit(p2c.workspaceEdit(we));
      return applied ? { applied: true } : { applied: false, failureReason: 'VS Code did not apply the edit' };
    } catch (e) {
      return { applied: false, failureReason: String(e && e.message || e) };
    }
  }

  // ── requests from the providers ──

  // A request and its answer converted for VS Code. Nothing (undefined) when there is no answer: a failure is
  // written to the log, and a request VS Code cancelled is not a failure.
  ask(method, params, token, convert) {
    if (!this.conn || !this.ready) return Promise.resolve(undefined);
    return this.conn.request(method, params, token).then(
      (r) => (r === null || r === undefined ? undefined : convert(r)),
      (e) => {
        if (!isCancel(e) && e.code !== ErrorCodes.ConnectionClosed) this.log(`${method}: ${e.message || e}`);
        return undefined;
      }).catch((e) => {
      this.log(`${method}: nedls's answer could not be used: ${e && e.stack || e}`);
      return undefined;
    });
  }

  // The same, for the requests whose failure VS Code shows the person (rename): the server's error is thrown.
  // nullMessage: what to throw when the answer is null (prepareRename: nothing to rename there).
  async askOrThrow(method, params, token, convert, nullMessage) {
    if (!this.conn || !this.ready) throw new Error('nedls is not running');
    let r;
    try {
      r = await this.conn.request(method, params, token);
    } catch (e) {
      if (isCancel(e)) return undefined;
      throw new Error(e.message || String(e));
    }
    if (r === null || r === undefined) {
      if (nullMessage) throw new Error(nullMessage);
      return undefined;
    }
    return convert(r);
  }

  notify(method, params) {
    if (this.conn && this.ready) this.conn.notify(method, params);
  }

  // ── documents ──

  wanted(doc) {
    const s = doc.uri.scheme;
    return (s === 'file' || s === 'untitled') && this.languages.includes(doc.languageId);
  }

  // textDocumentSync is a number (the kind of change) or options; the didOpen/didChange/didSave/didClose that
  // nedls asks for, for the documents of nedls.languages.
  syncDocuments() {
    const s = this.caps.textDocumentSync;
    let openClose = false;
    let change = SYNC_NONE;
    let save = null;
    if (typeof s === 'number') {
      openClose = s !== SYNC_NONE;
      change = s;
      save = s !== SYNC_NONE ? { includeText: false } : null;
    } else if (s && typeof s === 'object') {
      openClose = !!s.openClose;
      change = typeof s.change === 'number' ? s.change : SYNC_NONE;
      save = s.save ? (typeof s.save === 'object' ? s.save : { includeText: false }) : null;
    }
    this.syncKind = change;
    if (!openClose) return;
    const ws = vscode.workspace;
    this.subs.push(
      ws.onDidOpenTextDocument((doc) => this.didOpen(doc)),
      ws.onDidChangeTextDocument((e) => this.didChange(e)),
      ws.onDidCloseTextDocument((doc) => this.didClose(doc)));
    if (save) this.subs.push(ws.onDidSaveTextDocument((doc) => this.didSave(doc, !!save.includeText)));
    for (const doc of ws.textDocuments) this.didOpen(doc);
  }

  didOpen(doc) {
    const u = doc.uri.toString();
    if (!this.wanted(doc) || this.open.has(u)) return;
    this.open.add(u);
    this.notify('textDocument/didOpen',
                { textDocument: { uri: u, languageId: doc.languageId, version: doc.version, text: doc.getText() } });
  }

  didChange(e) {
    const doc = e.document;
    const u = doc.uri.toString();
    if (!this.open.has(u) || e.contentChanges.length === 0 || this.syncKind === SYNC_NONE) return;
    // (VS Code lists one edit's changes from the end of the document backwards, so applied one after the other,
    // as LSP applies them, each range is still where it was)
    const contentChanges = this.syncKind === SYNC_INCREMENTAL
      ? e.contentChanges.map((c) => ({ range: c2p.range(c.range), text: c.text }))
      : [{ text: doc.getText() }];
    this.notify('textDocument/didChange', { textDocument: { uri: u, version: doc.version }, contentChanges });
  }

  didSave(doc, includeText) {
    const u = doc.uri.toString();
    if (!this.open.has(u)) return;
    const params = { textDocument: { uri: u } };
    if (includeText) params.text = doc.getText();
    this.notify('textDocument/didSave', params);
  }

  didClose(doc) {
    const u = doc.uri.toString();
    if (!this.open.delete(u)) return;
    this.notify('textDocument/didClose', { textDocument: { uri: u } });
  }

  // Files changed on disk (by git, a build, another program), sent in batches: a checkout changes many at once.
  watchFiles() {
    const w = vscode.workspace.createFileSystemWatcher(WATCH);
    let batch = [];
    let timer = null;
    const flush = () => {
      timer = null;
      const changes = batch;
      batch = [];
      if (changes.length) this.notify('workspace/didChangeWatchedFiles', { changes });
    };
    const add = (type) => (u) => {
      batch.push({ uri: u.toString(), type });
      if (!timer) timer = setTimeout(flush, 100);
    };
    this.subs.push(w, w.onDidCreate(add(1)), w.onDidChange(add(2)), w.onDidDelete(add(3)),
                   { dispose: () => { if (timer) clearTimeout(timer); } });
  }

  // ── settings ──

  configurationChanged(e) {
    if (e.affectsConfiguration('nedls.trace.server')) {
      this.trace = vscode.workspace.getConfiguration('nedls').get('trace.server') || 'off';
      if (this.conn) this.conn.trace = this.trace;
      this.notify('$/setTrace', { value: this.trace });
    }
    this.notify('workspace/didChangeConfiguration', { settings: { nedls: settings('nedls') } });
  }

  // ── stopping ──

  // what the server added to VS Code, taken away: providers, listeners, problems, progress
  teardown() {
    this.ready = false;
    for (const s of this.subs.splice(0)) {
      try { s.dispose(); } catch (_) { /* (gone already) */ }
    }
    for (const entry of this.progress.values()) entry.finish();
    this.progress.clear();
    this.open.clear();
    if (this.diagnostics) this.diagnostics.clear();
  }

  // (its problems go with the server that found them; disposed once — VS Code throws on a second time)
  closeDiagnostics() {
    if (!this.diagnostics) return;
    const d = this.diagnostics;
    this.diagnostics = null;
    d.dispose();
  }

  crashed(code, signal) {
    this.teardown();
    this.closeDiagnostics();
    if (this.conn) this.conn.close();
    if (this.onCrash) this.onCrash(this, code, signal);
  }

  // shutdown, then exit, as the protocol asks; a server that does not end in time is killed
  async stop() {
    if (this.stopping) return;
    this.stopping = true;
    const wasReady = this.ready;
    this.teardown();
    this.closeDiagnostics();
    const conn = this.conn;
    const proc = this.proc;
    if (!proc) return;
    const running = () => proc.exitCode === null && proc.signalCode === null;
    if (conn && !conn.closed && wasReady) {
      try {
        await withTimeout(conn.request('shutdown'), 2000);
      } catch (e) {
        this.log(`shutdown: ${e.message || e}`);
      }
      conn.notify('exit');
    } else if (running() && proc.pid) {
      proc.kill();                         // (still starting: there is nothing to shut down yet)
    }
    if (running() && proc.pid) {
      try {
        await withTimeout(this.exited, 2000);
      } catch (_) {
        this.log('nedls did not end: stopped');
        proc.kill();
        await withTimeout(this.exited, 2000).catch(() => {});
      }
    }
    if (conn) conn.close();
  }
}

module.exports = { Client };

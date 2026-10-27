// A stand-in for the `vscode` module, so the extension runs under plain Node: the parts of VS Code's API it uses,
// with what it registers (providers, commands, diagnostics, messages, edits) kept where the test can look. The
// classes check what VS Code checks (a document symbol's name inside its range, a command registered twice, a
// disposed diagnostic collection used) so a mistake that would throw in VS Code throws here too.
'use strict';

// ── basics ──

class Disposable {
  constructor(fn) { this.fn = fn; }
  dispose() { if (this.fn) { const f = this.fn; this.fn = null; f(); } }
  static from(...ds) { return new Disposable(() => ds.forEach((d) => d.dispose())); }
}

class EventEmitter {
  constructor() {
    this.listeners = new Set();
    this.event = (fn, thisArg, disposables) => {
      const l = thisArg ? fn.bind(thisArg) : fn;
      this.listeners.add(l);
      const d = new Disposable(() => this.listeners.delete(l));
      if (disposables) disposables.push(d);
      return d;
    };
  }
  fire(x) { for (const l of [...this.listeners]) l(x); }
  dispose() { this.listeners.clear(); }
}

class CancellationTokenSource {
  constructor() {
    const ev = new EventEmitter();
    this.ev = ev;
    this.token = { isCancellationRequested: false, onCancellationRequested: ev.event };
  }
  cancel() {
    if (this.token.isCancellationRequested) return;
    this.token.isCancellationRequested = true;
    this.ev.fire();
  }
  dispose() { this.ev.dispose(); }
}

class Uri {
  constructor(scheme, authority, path) {
    this.scheme = scheme;
    this.authority = authority || '';
    this.path = path;
    this.query = '';
    this.fragment = '';
  }
  get fsPath() { return this.path; }
  static parse(s) {
    const m = /^([a-zA-Z][\w+.-]*):(?:\/\/([^/]*))?([^?#]*)/.exec(s);
    if (!m) throw new Error('not a URI: ' + s);
    return new Uri(m[1], m[2], decodeURIComponent(m[3]));
  }
  static file(p) { return new Uri('file', '', p); }
  toString() {
    const p = this.path.split('/').map((x) => encodeURIComponent(x)).join('/');
    return this.scheme === 'file' ? `file://${this.authority}${p}` : `${this.scheme}:${p}`;
  }
  toJSON() { return this.toString(); }
}

class Position {
  constructor(line, character) {
    if (line < 0 || character < 0) throw new Error('Illegal argument: line and character must be non-negative');
    this.line = line;
    this.character = character;
  }
  isBefore(o) { return this.line < o.line || (this.line === o.line && this.character < o.character); }
  isAfter(o) { return o.isBefore(this); }
  isEqual(o) { return this.line === o.line && this.character === o.character; }
  isBeforeOrEqual(o) { return !this.isAfter(o); }
}

class Range {
  constructor(a, b, c, d) {
    if (typeof a === 'number') { a = new Position(a, b); b = new Position(c, d); }
    if (b.isBefore(a)) { const t = a; a = b; b = t; }
    this.start = a;
    this.end = b;
  }
  get isEmpty() { return this.start.isEqual(this.end); }
  contains(x) {
    if (x instanceof Range) return this.contains(x.start) && this.contains(x.end);
    return !x.isBefore(this.start) && !this.end.isBefore(x);
  }
  isEqual(o) { return this.start.isEqual(o.start) && this.end.isEqual(o.end); }
}

class Location {
  constructor(uri, r) { this.uri = uri; this.range = r instanceof Position ? new Range(r, r) : r; }
}

class MarkdownString {
  constructor(value, supportThemeIcons) { this.value = value || ''; this.supportThemeIcons = supportThemeIcons; }
  appendText(t) { this.value += t.replace(/[\\`*_{}[\]()#+\-.!<>]/g, '\\$&'); return this; }
  appendMarkdown(t) { this.value += t; return this; }
  appendCodeblock(code, lang) { this.value += '\n```' + (lang || '') + '\n' + code + '\n```\n'; return this; }
}

class SnippetString {
  constructor(value) { this.value = value || ''; }
}

// ── the language feature types ──

const DiagnosticSeverity = { Error: 0, Warning: 1, Information: 2, Hint: 3 };
const DiagnosticTag = { Unnecessary: 1, Deprecated: 2 };
class Diagnostic {
  constructor(range, message, severity) {
    if (!(range instanceof Range)) throw new Error('Diagnostic: range expected');
    this.range = range;
    this.message = message;
    this.severity = severity === undefined ? DiagnosticSeverity.Error : severity;
  }
}
class DiagnosticRelatedInformation {
  constructor(location, message) { this.location = location; this.message = message; }
}

const names = (list) => Object.fromEntries(list.map((n, i) => [n, i]));
const CompletionItemKind = names(['Text', 'Method', 'Function', 'Constructor', 'Field', 'Variable', 'Class',
  'Interface', 'Module', 'Property', 'Unit', 'Value', 'Enum', 'Keyword', 'Snippet', 'Color', 'File', 'Reference',
  'Folder', 'EnumMember', 'Constant', 'Struct', 'Event', 'Operator', 'TypeParameter', 'User', 'Issue']);
const SymbolKind = names(['File', 'Module', 'Namespace', 'Package', 'Class', 'Method', 'Property', 'Field',
  'Constructor', 'Enum', 'Interface', 'Function', 'Variable', 'Constant', 'String', 'Number', 'Boolean', 'Array',
  'Object', 'Key', 'Null', 'EnumMember', 'Struct', 'Event', 'Operator', 'TypeParameter']);
const CompletionItemTag = { Deprecated: 1 };
const SymbolTag = { Deprecated: 1 };
const DocumentHighlightKind = { Text: 0, Read: 1, Write: 2 };
const FoldingRangeKind = { Comment: 1, Imports: 2, Region: 3 };
const InlayHintKind = { Type: 1, Parameter: 2 };
const ProgressLocation = { SourceControl: 1, Window: 10, Notification: 15 };
const CompletionTriggerKind = { Invoke: 0, TriggerCharacter: 1, TriggerForIncompleteCompletions: 2 };
const SignatureHelpTriggerKind = { Invoke: 1, TriggerCharacter: 2, ContentChange: 3 };
const CodeActionTriggerKind = { Invoke: 1, Automatic: 2 };

class CompletionItem {
  constructor(label, kind) { this.label = label; this.kind = kind; }
}
class CompletionList {
  constructor(items, isIncomplete) { this.items = items || []; this.isIncomplete = !!isIncomplete; }
}
class Hover {
  constructor(contents, range) { this.contents = Array.isArray(contents) ? contents : [contents]; this.range = range; }
}
class SignatureHelp {
  constructor() { this.signatures = []; this.activeSignature = 0; this.activeParameter = 0; }
}
class SignatureInformation {
  constructor(label, documentation) { this.label = label; this.documentation = documentation; this.parameters = []; }
}
class ParameterInformation {
  constructor(label, documentation) { this.label = label; this.documentation = documentation; }
}
class DocumentHighlight {
  constructor(range, kind) { this.range = range; this.kind = kind === undefined ? DocumentHighlightKind.Text : kind; }
}
class SymbolInformation {
  constructor(name, kind, containerName, location) {
    this.name = name; this.kind = kind; this.containerName = containerName; this.location = location;
  }
}
class DocumentSymbol {
  constructor(name, detail, kind, range, selectionRange) {
    if (!name) throw new Error('name must not be falsy');
    if (!range.contains(selectionRange)) throw new Error('selectionRange must be contained in fullRange');
    this.name = name; this.detail = detail; this.kind = kind; this.range = range;
    this.selectionRange = selectionRange; this.children = [];
  }
}
class CodeActionKind {
  constructor(value) { this.value = value; }
  append(parts) { return new CodeActionKind(this.value ? this.value + '.' + parts : parts); }
  contains(other) { return this.value === other.value || other.value.startsWith(this.value + '.'); }
}
CodeActionKind.Empty = new CodeActionKind('');
CodeActionKind.QuickFix = CodeActionKind.Empty.append('quickfix');
CodeActionKind.Refactor = CodeActionKind.Empty.append('refactor');
CodeActionKind.Source = CodeActionKind.Empty.append('source');
class CodeAction {
  constructor(title, kind) { this.title = title; this.kind = kind; }
}
class CodeLens {
  constructor(range, command) { this.range = range; this.command = command; }
  get isResolved() { return !!this.command; }
}
class TextEdit {
  constructor(range, newText) { this.range = range; this.newText = newText; }
  static replace(r, t) { return new TextEdit(r, t); }
  static insert(p, t) { return new TextEdit(new Range(p, p), t); }
  static delete(r) { return new TextEdit(r, ''); }
}
class WorkspaceEdit {
  constructor() { this.ops = []; }            // (in order: {type: 'text'|'create'|'rename'|'delete', …})
  replace(uri, range, newText) { this.ops.push({ type: 'text', uri, edit: new TextEdit(range, newText) }); }
  insert(uri, pos, newText) { this.replace(uri, new Range(pos, pos), newText); }
  delete(uri, range) { this.replace(uri, range, ''); }
  set(uri, edits) { for (const e of edits) this.replace(uri, e.range, e.newText); }
  createFile(uri, options) { this.ops.push({ type: 'create', uri, options }); }
  renameFile(from, to, options) { this.ops.push({ type: 'rename', from, to, options }); }
  deleteFile(uri, options) { this.ops.push({ type: 'delete', uri, options }); }
  get size() { return new Set(this.ops.map((o) => String(o.uri || o.from))).size; }
  entries() {
    const m = new Map();
    for (const o of this.ops) {
      if (o.type !== 'text') continue;
      const k = o.uri.toString();
      if (!m.has(k)) m.set(k, [o.uri, []]);
      m.get(k)[1].push(o.edit);
    }
    return [...m.values()];
  }
}
class FoldingRange {
  constructor(start, end, kind) { this.start = start; this.end = end; this.kind = kind; }
}
class SelectionRange {
  constructor(range, parent) {
    if (parent && !parent.range.contains(range)) throw new Error('Invalid argument: parent must contain range');
    this.range = range; this.parent = parent;
  }
}
class InlayHint {
  constructor(position, label, kind) { this.position = position; this.label = label; this.kind = kind; }
}
class InlayHintLabelPart {
  constructor(value) { this.value = value; }
}
class SemanticTokensLegend {
  constructor(tokenTypes, tokenModifiers) { this.tokenTypes = tokenTypes; this.tokenModifiers = tokenModifiers || []; }
}
class SemanticTokens {
  constructor(data, resultId) {
    if (!(data instanceof Uint32Array)) throw new Error('SemanticTokens: Uint32Array expected');
    this.data = data; this.resultId = resultId;
  }
}
class SemanticTokensEdit {
  constructor(start, deleteCount, data) {
    if (typeof start !== 'number' || typeof deleteCount !== 'number') throw new Error('SemanticTokensEdit: numbers expected');
    if (data !== undefined && !(data instanceof Uint32Array)) throw new Error('SemanticTokensEdit: Uint32Array expected');
    this.start = start; this.deleteCount = deleteCount; this.data = data;
  }
}
class SemanticTokensEdits {
  constructor(edits, resultId) {
    if (!Array.isArray(edits) || !edits.every((e) => e instanceof SemanticTokensEdit)) {
      throw new Error('SemanticTokensEdits: SemanticTokensEdit[] expected');
    }
    this.edits = edits; this.resultId = resultId;
  }
}
class CallHierarchyItem {
  constructor(kind, name, detail, uri, range, selectionRange) {
    Object.assign(this, { kind, name, detail, uri, range, selectionRange });
  }
}
class CallHierarchyIncomingCall {
  constructor(from, fromRanges) { this.from = from; this.fromRanges = fromRanges; }
}
class CallHierarchyOutgoingCall {
  constructor(to, fromRanges) { this.to = to; this.fromRanges = fromRanges; }
}
class TypeHierarchyItem {
  constructor(kind, name, detail, uri, range, selectionRange) {
    Object.assign(this, { kind, name, detail, uri, range, selectionRange });
  }
}
class DocumentLink {
  constructor(range, target) { this.range = range; this.target = target; }
}
class LinkedEditingRanges {
  constructor(ranges, wordPattern) { this.ranges = ranges; this.wordPattern = wordPattern; }
}

// ── documents ──

class TextDocument {
  constructor(uri, languageId, text) {
    this.uri = uri;
    this.languageId = languageId;
    this.version = 1;
    this.text = text;
    this.isClosed = false;
  }
  get fileName() { return this.uri.fsPath; }
  get isUntitled() { return this.uri.scheme === 'untitled'; }
  get lineCount() { return this.text.split('\n').length; }
  offsetAt(p) {
    const lines = this.text.split('\n');
    let off = 0;
    for (let i = 0; i < p.line && i < lines.length; i++) off += lines[i].length + 1;
    return off + Math.min(p.character, (lines[p.line] || '').length);
  }
  positionAt(off) {
    const before = this.text.slice(0, off).split('\n');
    return new Position(before.length - 1, before[before.length - 1].length);
  }
  getText(r) { return r ? this.text.slice(this.offsetAt(r.start), this.offsetAt(r.end)) : this.text; }
}

// ── the registry the test reads ──

const state = {
  settings: {},                 // 'nedls.path' → value …
  providers: [],                // {kind, selector, provider, args}
  commands: new Map(),
  executed: [],                 // commands run that nobody registered (openSettings …)
  messages: [],                 // {type, message, items}
  answer: () => undefined,      // (type, message, items) → the item a person picks
  progress: [],                 // {title, messages, done}
  edits: [],                    // the WorkspaceEdits applied
  collections: [],
  outputs: [],
  watchers: []
};

const events = {
  open: new EventEmitter(), change: new EventEmitter(), save: new EventEmitter(), close: new EventEmitter(),
  config: new EventEmitter(), folders: new EventEmitter(), willRename: new EventEmitter()
};

function configuration(section) {
  const full = (k) => (section ? section + '.' + k : k);
  return {
    get(key, def) {
      const k = full(key);
      if (k in state.settings) return state.settings[k];
      // (a section: the object of every setting under it, as VS Code gives it)
      const obj = {};
      let found = false;
      for (const [name, v] of Object.entries(state.settings)) {
        if (!name.startsWith(k + '.')) continue;
        found = true;
        let o = obj;
        const parts = name.slice(k.length + 1).split('.');
        for (const p of parts.slice(0, -1)) o = o[p] = o[p] || {};
        o[parts[parts.length - 1]] = v;
      }
      return found ? obj : def;
    },
    has(key) { return full(key) in state.settings; },
    update(key, value) { setSetting(full(key), value); return Promise.resolve(); }
  };
}

function setSetting(key, value) {
  state.settings[key] = value;
  events.config.fire({ affectsConfiguration: (s) => key === s || key.startsWith(s + '.') });
}

function register(kind) {
  return (...args) => {
    const entry = { kind, selector: typeof args[0] === 'object' && !args[0].provideWorkspaceSymbols ? args[0] : null,
                    provider: kind === 'workspaceSymbol' ? args[0] : args[1], args };
    state.providers.push(entry);
    return new Disposable(() => { state.providers = state.providers.filter((x) => x !== entry); });
  };
}

const workspace = {
  workspaceFolders: undefined,
  textDocuments: [],
  getConfiguration: (section) => configuration(section),
  onDidOpenTextDocument: events.open.event,
  onDidChangeTextDocument: events.change.event,
  onDidSaveTextDocument: events.save.event,
  onDidCloseTextDocument: events.close.event,
  onDidChangeConfiguration: events.config.event,
  onDidChangeWorkspaceFolders: events.folders.event,
  onWillRenameFiles: events.willRename.event,
  createFileSystemWatcher(glob) {
    const w = { glob, create: new EventEmitter(), change: new EventEmitter(), del: new EventEmitter(), disposed: false };
    w.onDidCreate = w.create.event;
    w.onDidChange = w.change.event;
    w.onDidDelete = w.del.event;
    w.dispose = () => { w.disposed = true; };
    state.watchers.push(w);
    return w;
  },
  applyEdit(edit) {
    state.edits.push(edit);
    return Promise.resolve(true);
  }
};

const window = {
  createOutputChannel(name) {
    const ch = { name, text: '', disposed: false, shown: 0 };
    ch.append = (s) => { if (ch.disposed) throw new Error('Channel has been closed'); ch.text += s; };
    ch.appendLine = (s) => ch.append(s + '\n');
    ch.show = () => { ch.shown++; };
    ch.clear = () => { ch.text = ''; };
    ch.dispose = () => { ch.disposed = true; };
    state.outputs.push(ch);
    return ch;
  },
  withProgress(options, task) {
    const p = { title: options.title, location: options.location, messages: [], done: false };
    state.progress.push(p);
    const cts = new CancellationTokenSource();
    return Promise.resolve(task({ report: (v) => p.messages.push(v.message) }, cts.token)).then((r) => {
      p.done = true;
      return r;
    });
  }
};
for (const [fn, type] of [['showErrorMessage', 1], ['showWarningMessage', 2], ['showInformationMessage', 3]]) {
  window[fn] = (message, ...items) => {
    state.messages.push({ type, message, items });
    return Promise.resolve(state.answer(type, message, items));
  };
}

const languages = {
  createDiagnosticCollection(name) {
    const m = new Map();
    const c = {
      name,
      disposed: false,
      check() { if (c.disposed) throw new Error('illegal state - object is disposed'); },
      set(uri, ds) { c.check(); m.set(uri.toString(), ds || []); },
      get(uri) { return m.get(uri.toString()); },
      delete(uri) { c.check(); m.delete(uri.toString()); },
      clear() { c.check(); m.clear(); },
      forEach(fn) { for (const [k, v] of m) fn(Uri.parse(k), v, c); },
      dispose() { if (!c.disposed) { c.disposed = true; m.clear(); } }
    };
    state.collections.push(c);
    return c;
  }
};
for (const kind of ['completion', 'hover', 'signatureHelp', 'definition', 'declaration', 'typeDefinition',
  'implementation', 'reference', 'documentHighlight', 'documentSymbol', 'workspaceSymbol', 'codeActions', 'codeLens',
  'documentFormatting', 'documentRangeFormatting', 'onTypeFormatting', 'rename', 'foldingRange', 'selectionRange',
  'inlayHints', 'documentSemanticTokens', 'documentRangeSemanticTokens', 'callHierarchy', 'typeHierarchy',
  'documentLink', 'linkedEditingRange']) {
  const fn = 'register' + kind[0].toUpperCase() + kind.slice(1) +
             (['codeActions', 'documentSemanticTokens', 'documentRangeSemanticTokens'].includes(kind) ? 'Provider'
              : kind === 'completion' ? 'ItemProvider'
              : kind === 'documentFormatting' || kind === 'documentRangeFormatting' || kind === 'onTypeFormatting'
                ? 'EditProvider' : 'Provider');
  languages[fn] = register(kind);
}

const commands = {
  registerCommand(id, fn) {
    if (state.commands.has(id)) throw new Error(`command '${id}' already exists`);
    state.commands.set(id, fn);
    return new Disposable(() => state.commands.delete(id));
  },
  executeCommand(id, ...args) {
    const fn = state.commands.get(id);
    if (fn) return Promise.resolve(fn(...args));
    state.executed.push([id, ...args]);
    return Promise.resolve();
  },
  getCommands() { return Promise.resolve([...state.commands.keys()]); }
};

// ── what the test does as VS Code would ──

const test = {
  state,
  events,
  setSetting,
  openDocument(where, languageId, text) {       // (where: a path, or a Uri)
    const doc = new TextDocument(typeof where === 'string' ? Uri.file(where) : where, languageId, text);
    workspace.textDocuments.push(doc);
    events.open.fire(doc);
    return doc;
  },
  // an edit typed: each change's range is in the text before the edit; listed from the end backwards, as VS Code
  // lists them
  editDocument(doc, changes) {
    const sorted = changes.slice().sort((a, b) => doc.offsetAt(b.range.start) - doc.offsetAt(a.range.start));
    const contentChanges = sorted.map((c) => ({ range: c.range, rangeOffset: doc.offsetAt(c.range.start),
                                                 rangeLength: doc.offsetAt(c.range.end) - doc.offsetAt(c.range.start),
                                                 text: c.text }));
    for (const c of contentChanges) {
      doc.text = doc.text.slice(0, c.rangeOffset) + c.text + doc.text.slice(c.rangeOffset + c.rangeLength);
    }
    doc.version++;
    events.change.fire({ document: doc, contentChanges, reason: undefined });
  },
  saveDocument(doc) { events.save.fire(doc); },
  closeDocument(doc) {
    workspace.textDocuments = workspace.textDocuments.filter((d) => d !== doc);
    doc.isClosed = true;
    events.close.fire(doc);
  },
  providers(kind) { return state.providers.filter((p) => p.kind === kind); },
  provider(kind) {
    const ps = test.providers(kind);
    if (ps.length !== 1) throw new Error(`${ps.length} ${kind} providers registered, one expected`);
    return ps[0].provider;
  }
};

module.exports = {
  Disposable, EventEmitter, CancellationTokenSource, Uri, Position, Range, Location, MarkdownString, SnippetString,
  Diagnostic, DiagnosticSeverity, DiagnosticTag, DiagnosticRelatedInformation, CompletionItem, CompletionItemKind,
  CompletionItemTag, CompletionList, CompletionTriggerKind, Hover, SignatureHelp, SignatureInformation,
  ParameterInformation, SignatureHelpTriggerKind, DocumentHighlight, DocumentHighlightKind, SymbolInformation,
  SymbolKind, SymbolTag, DocumentSymbol, CodeAction, CodeActionKind, CodeActionTriggerKind, CodeLens, TextEdit,
  WorkspaceEdit, FoldingRange, FoldingRangeKind, SelectionRange, InlayHint, InlayHintKind, InlayHintLabelPart,
  SemanticTokensLegend, SemanticTokens, SemanticTokensEdit, SemanticTokensEdits, CallHierarchyItem,
  CallHierarchyIncomingCall, CallHierarchyOutgoingCall,
  TypeHierarchyItem, DocumentLink, LinkedEditingRanges, ProgressLocation,
  workspace, window, languages, commands,
  env: { appName: 'Mock Code', language: 'en' },
  version: '1.95.0',
  _test: test
};

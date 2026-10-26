#!/usr/bin/env node
// The VS Code extension (editors/vscode) run under plain Node, with a stand-in for VS Code (mock_vscode.js), against
// the real nedls on a small Nim project in a temporary folder — and against a fake server (written here) for what
// nedls rarely does: asks with buttons, edits that create, rename and delete files, progress, a request nobody
// knows, a crash.
//
//     node tests/vscode/test_extension.js ./nedls
//
// No npm packages: Node 18 or newer. Each check prints PASS or FAIL; the exit code is 1 when one fails. The checks
// that need Nim itself (completion from std/strutils, the compiler's problems) are skipped when `nim` is not on
// PATH.
'use strict';

const Module = require('module');
const path = require('path');
const fs = require('fs');
const os = require('os');

const repo = path.resolve(__dirname, '..', '..');
const mockPath = path.join(__dirname, 'mock_vscode.js');
const resolve0 = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  return request === 'vscode' ? mockPath : resolve0.call(this, request, ...rest);
};
const vscode = require(mockPath);
const T = vscode._test;
const ext = require(path.join(repo, 'editors', 'vscode', 'extension.js'));

const nedls = path.resolve(process.argv[2] || path.join(repo, 'nedls'));
const haveNim = (process.env.PATH || '').split(path.delimiter).some((d) => d && fs.existsSync(path.join(d, 'nim')));

// ── checks ──

const results = [];

function check(name, ok, detail) {
  results.push([name, !!ok]);
  let s = (ok ? 'PASS  ' : 'FAIL  ') + name;
  if (!ok && detail !== undefined) {
    let d;
    try { d = typeof detail === 'string' ? detail : JSON.stringify(detail); } catch (_) { d = String(detail); }
    s += '  — ' + String(d).slice(0, 400);
  }
  console.log(s);
  return !!ok;
}

function skip(name, why) {
  console.log(`SKIP  ${name} (${why})`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(pred, ms = 20000) {
  const end = Date.now() + ms;
  for (;;) {
    let v;
    try { v = pred(); } catch (_) { v = undefined; }
    if (v || Date.now() > end) return v;
    await sleep(50);
  }
}

// (the provider's answer, or the error it threw, with a time limit: a provider that hangs is a failure too)
async function call(fn, ms = 30000) {
  let timer;
  try {
    return await Promise.race([Promise.resolve().then(fn), new Promise((_, rej) => {
      timer = setTimeout(() => rej(new Error(`no answer in ${ms} ms`)), ms);
    })]);
  } catch (e) {
    return { error: e };
  } finally {
    clearTimeout(timer);
  }
}

function token() {
  return new vscode.CancellationTokenSource().token;
}

function output() {
  const chs = T.state.outputs;
  return chs.length ? chs[chs.length - 1].text : '';
}

// the pid of the server started last (from the log)
function lastPid() {
  const all = [...output().matchAll(/nedls started \(pid (\d+)\)/g)];
  return all.length ? +all[all.length - 1][1] : 0;
}

function count(text, needle) {
  return text.split(needle).length - 1;
}

// the position `after` UTF-16 units into the nth occurrence of needle (JavaScript strings are UTF-16, as LSP's
// and VS Code's columns are)
function pos(text, needle, after = 0, nth = 0) {
  let k = -1;
  for (let i = 0; i <= nth; i++) {
    k = text.indexOf(needle, k + 1);
    if (k < 0) throw new Error(`${needle} not found`);
  }
  k += after;
  const before = text.slice(0, k).split('\n');
  return new vscode.Position(before.length - 1, before[before.length - 1].length);
}

function offset(text, p) {
  const lines = text.split('\n');
  let off = 0;
  for (let i = 0; i < p.line; i++) off += lines[i].length + 1;
  return off + p.character;
}

function rangeText(text, r) {
  return text.slice(offset(text, r.start), offset(text, r.end));
}

function applyEdits(text, edits) {
  const es = edits.slice().sort((a, b) => offset(text, b.range.start) - offset(text, a.range.start));
  for (const e of es) text = text.slice(0, offset(text, e.range.start)) + e.newText + text.slice(offset(text, e.range.end));
  return text;
}

function editsFor(we, uri) {
  const e = we.entries().find(([u]) => u.toString() === uri.toString());
  return e ? e[1] : [];
}

function mdText(x) {
  return typeof x === 'string' ? x : x && x.value !== undefined ? x.value : '';
}

function diagnostics(uri) {
  const live = T.state.collections.filter((c) => !c.disposed);
  return live.length ? live[live.length - 1].get(uri) : undefined;
}

// ── the project ──

const SHAPES = `## Shapes for the tests.

type
  Shape* = object
    name*: string
    width*, height*: int
  Color* = enum
    red, green, blue

proc area*(s: Shape): int =
  ## The area of a shape.
  s.width * s.height

proc newShape*(name: string, w, h: int): Shape =
  ## Makes a shape.
  Shape(name: name, width: w, height: h)
`;

const APP = `import std/strutils
import shapes

let greeting = "héllo wörld 🎉 ünïcode"; let sq = newShape("square", 2, 2)

proc describe(s: Shape): string =
  result = s.name & ": " & $s.area

let total = sq.area + 1
let s = "text"
echo s.
echo describe(sq), total, greeting
`;

const ANIMALS = `type
  Animal* = ref object of RootObj
    name*: string
  Dog* = ref object of Animal
  Cat* = ref object of Animal

method speak*(a: Animal): string {.base.} = "…"
method speak*(d: Dog): string = "woof"
method speak*(c: Cat): string = "meow"
`;

const BAD = `import shapes

let sh = newShape("x", 1, 2)
echoo sh.width
`;

const FMT = `proc  f( a:int ):int=a+1
echo   f(2)
`;

function settings(serverPath, trace) {
  return {
    'nedls.path': serverPath,
    'nedls.languages': ['nim', 'nimscript', 'nimble'],
    'nedls.inlayHints': true,
    'nedls.parameterHints': 'literals',
    'nedls.raisesHints': false,
    'nedls.checkOnSave': true,
    'nedls.liveDiagnostics': true,
    'nedls.formatLineLength': null,
    'nedls.nedSettings': false,
    'nedls.trace.server': trace,
    'files.trimTrailingWhitespace': false,
    'files.insertFinalNewline': false,
    'files.trimFinalNewlines': false
  };
}

// ── against nedls ──

async function withNedls(root) {
  const src = path.join(root, 'src');
  const files = { 'shapes.nim': SHAPES, 'app.nim': APP, 'animals.nim': ANIMALS, 'bad.nim': BAD, 'fmt.nim': FMT };
  for (const [n, t] of Object.entries(files)) fs.writeFileSync(path.join(src, n), t);
  fs.writeFileSync(path.join(root, 'proj.nimble'), 'version = "0.1.0"\nauthor = "t"\ndescription = "t"\n' +
                   'license = "MIT"\nsrcDir = "src"\n');

  T.state.settings = settings(nedls, 'verbose');
  vscode.workspace.workspaceFolders = [{ uri: vscode.Uri.file(root), name: 'proj', index: 0 }];
  const context = { subscriptions: [] };

  // activation starts the server and registers what it can do
  const act = await call(() => ext.activate(context), 90000);
  check('activate: resolves', !(act && act.error), act && act.error && act.error.message);
  const pid0 = +((/nedls started \(pid (\d+)\)/.exec(output()) || [])[1] || 0);
  check('activate: nedls started (its pid in the log)', pid0 > 0, output().slice(0, 300));
  check('activate: initialize sent with the nedls.* settings as initializationOptions',
        /Sending request 'initialize - \(1\)'/.test(output()) && /"nedSettings": false/.test(output()) &&
        /"parameterHints": "literals"/.test(output()), output().slice(0, 600));
  check('initialize: the client offers UTF-16 positions only', /"positionEncodings": \[\s*"utf-16"\s*\]/.test(output()));
  const kinds = ['completion', 'hover', 'signatureHelp', 'definition', 'declaration', 'typeDefinition',
                 'implementation', 'reference', 'documentHighlight', 'documentSymbol', 'workspaceSymbol',
                 'codeActions', 'codeLens', 'documentFormatting', 'documentRangeFormatting', 'onTypeFormatting', 'rename',
                 'foldingRange', 'selectionRange', 'inlayHints', 'documentSemanticTokens',
                 'documentRangeSemanticTokens', 'callHierarchy', 'typeHierarchy', 'documentLink'];
  const missing = kinds.filter((k) => T.providers(k).length !== 1);
  check('providers: one for each of nedls\'s capabilities', missing.length === 0, missing);
  check('providers: for nim, nimscript and nimble, file and untitled documents',
        JSON.stringify(T.providers('hover')[0].selector) === JSON.stringify(
          ['nim', 'nimscript', 'nimble'].flatMap((l) => [{ scheme: 'file', language: l },
                                                         { scheme: 'untitled', language: l }])),
        T.providers('hover')[0].selector);
  const cmds = ['nedls.run', 'nedls.lintRuleOff', 'nedls.aiFix'].filter((c) => !T.state.commands.has(c));
  check('the server\'s commands (executeCommandProvider) are VS Code commands', cmds.length === 0, cmds);
  check('completion trigger characters from the server',
        T.providers('completion')[0].args.slice(2).join('') === '.>:<"#@/', T.providers('completion')[0].args.slice(2));
  const sh = T.providers('signatureHelp')[0].args[2];
  check('signature help trigger characters from the server',
        sh && sh.triggerCharacters.join('') === '(,' && sh.retriggerCharacters.join('') === ',', sh);
  const legend = T.providers('documentSemanticTokens')[0].args[2];
  check('semantic tokens: the legend is the server\'s', legend && legend.tokenTypes.includes('function'), legend);
  check('workspace/configuration: answered with the nedls settings',
        await waitFor(() => /Sending response 'workspace\/configuration - \(nedls-\d+\)'/.test(output()) &&
                            /"checkOnSave": true/.test(output().split("Sending response 'workspace/configuration")[1])),
        output().slice(-500));
  check('a file watcher for Nim files and settings',
        T.state.watchers.some((w) => w.glob === '**/{*.nim,*.nims,*.nimble,nim.cfg,.ned/settings.json}'));

  // documents: didOpen for the languages chosen only
  const p = (n) => path.join(src, n);
  const shapes = T.openDocument(p('shapes.nim'), 'nim', SHAPES);
  const app = T.openDocument(p('app.nim'), 'nim', APP);
  T.openDocument(p('notes.txt'), 'plaintext', 'not Nim');
  const untitled = T.openDocument(vscode.Uri.parse('untitled:Untitled-1'), 'nim', 'echo 1\n');
  check('didOpen: sent for the Nim documents, not for a plain text one',
        count(output(), "Sending notification 'textDocument/didOpen'") === 3 && !/notes\.txt/.test(output()),
        count(output(), "Sending notification 'textDocument/didOpen'"));
  check('didOpen: an untitled document too', /"uri": "untitled:Untitled-1"/.test(output()));
  T.closeDocument(untitled);

  // hover on a name after a non-ASCII string: the columns are UTF-16's on both sides
  const hv = await call(() => T.provider('hover').provideHover(app, pos(APP, 'newShape', 2), token()));
  const hvText = hv && hv.contents ? hv.contents.map(mdText).join('\n') : '';
  check('hover: the documentation, as Markdown', hv instanceof vscode.Hover && /Makes a shape/.test(hvText) &&
        hv.contents[0] instanceof vscode.MarkdownString, hv);
  check('hover: its range is the name (UTF-16 columns after "🎉")', hv && hv.range &&
        rangeText(APP, hv.range) === 'newShape', hv && hv.range);

  // definition across modules
  const def = await call(() => T.provider('definition').provideDefinition(app, pos(APP, 'newShape', 2), token()));
  const defs = Array.isArray(def) ? def : def ? [def] : [];
  const d0 = defs[0] || {};
  const dUri = d0.targetUri || d0.uri;
  const dRange = d0.targetSelectionRange || d0.range;
  check('definition: newShape in shapes.nim, on its name', dUri && dUri.toString() === shapes.uri.toString() &&
        dRange.start.line === 13 && rangeText(SHAPES, dRange) === 'newShape', def);
  const decl = await call(() => T.provider('declaration').provideDeclaration(app, pos(APP, 'newShape', 2), token()));
  check('declaration: answers', Array.isArray(decl) ? decl.length > 0 : !!decl, decl);
  const tdef = await call(() => T.provider('typeDefinition').provideTypeDefinition(app, pos(APP, 'sq.area'), token()));
  const t0 = (Array.isArray(tdef) ? tdef : [tdef])[0] || {};
  check('typeDefinition: sq → type Shape', (t0.uri || t0.targetUri || '').toString() === shapes.uri.toString() &&
        (t0.range || t0.targetRange).start.line === 3, tdef);

  // completion right after `s.` (s a string, std/strutils imported), and the item's documentation resolved
  if (haveNim) {
    const at = pos(APP, 'echo s.', 7);
    const cl = await call(() => T.provider('completion').provideCompletionItems(app, at, token(),
      { triggerKind: vscode.CompletionTriggerKind.TriggerCharacter, triggerCharacter: '.' }));
    const items = cl && cl.items ? cl.items : [];
    const up = items.find((i) => i.label === 'toUpperAscii');
    check('completion after `s.`: toUpperAscii from std/strutils', cl instanceof vscode.CompletionList && up,
          items.slice(0, 10).map((i) => i.label));
    check('completion item: a function, inserted over the range the server gave',
          up && up.kind === vscode.CompletionItemKind.Function && up.range && up.range.start.isEqual(at) &&
          (typeof up.insertText === 'string' ? up.insertText : up.insertText.value).startsWith('toUpperAscii'), up);
    check('completion item: sortText, filterText and detail kept', up && up.sortText && up.filterText &&
          up.detail, up);
    if (up) {
      const r = await call(() => T.provider('completion').resolveCompletionItem(up, token()));
      check('completionItem/resolve: documentation, as Markdown', r === up && mdText(up.documentation).length > 10,
            r && r.error ? r.error.message : up.documentation);
    }
  } else {
    skip('completion after `s.`', 'nim is not on PATH: no standard library');
  }

  // signature help: newShape("square", 2|, 2) — the second parameter
  const sg = await call(() => T.provider('signatureHelp').provideSignatureHelp(app, pos(APP, 'newShape("square", 2', 20),
    token(), { triggerKind: vscode.SignatureHelpTriggerKind.Invoke, isRetrigger: false }));
  check('signature help: the signature and its active parameter', sg instanceof vscode.SignatureHelp &&
        /newShape\(/.test(sg.signatures[0].label) && sg.activeParameter === 1, sg);

  // references, highlights
  const refs = await call(() => T.provider('reference').provideReferences(shapes, pos(SHAPES, 'area*', 1),
    { includeDeclaration: true }, token()));
  const inApp = (refs || []).filter((l) => l.uri.toString() === app.uri.toString());
  check('references: across modules, on the name', Array.isArray(refs) && inApp.length === 2 &&
        inApp.every((l) => l instanceof vscode.Location && rangeText(APP, l.range) === 'area') &&
        refs.some((l) => l.uri.toString() === shapes.uri.toString()), refs);
  const hl = await call(() => T.provider('documentHighlight').provideDocumentHighlights(app, pos(APP, 'sq.area'), token()));
  check('document highlights: every sq in the file', Array.isArray(hl) && hl.length === 3 &&
        hl.every((h) => h instanceof vscode.DocumentHighlight && rangeText(APP, h.range) === 'sq'), hl);

  // symbols
  const syms = await call(() => T.provider('documentSymbol').provideDocumentSymbols(shapes, token()));
  const byName = Object.fromEntries((Array.isArray(syms) ? syms : []).map((s) => [s.name, s]));
  check('document symbols: a tree (Shape holds its fields, Color its values)',
        byName.Shape instanceof vscode.DocumentSymbol &&
        byName.Shape.children.map((c) => c.name).join() === 'name,width,height' &&
        byName.Color.children.map((c) => c.name).join() === 'red,green,blue' &&
        byName.area.kind === vscode.SymbolKind.Function, syms);
  const ws = await call(() => T.provider('workspaceSymbol').provideWorkspaceSymbols('newsha', token()));
  check('workspace symbols', Array.isArray(ws) && ws.some((s) => s instanceof vscode.SymbolInformation &&
        s.name === 'newShape' && s.location.uri.toString() === shapes.uri.toString()), ws);

  // folding, selection ranges
  const fr = await call(() => T.provider('foldingRange').provideFoldingRanges(shapes, {}, token()));
  const frs = (fr || []).map((f) => `${f.start}-${f.end}`);
  check('folding ranges: the type section, the object, the procs', ['2-7', '3-5', '9-11', '13-15'].every(
    (x) => frs.includes(x)), frs);
  const sel = await call(() => T.provider('selectionRange').provideSelectionRanges(app, [pos(APP, 's.name', 3)], token()));
  const chain = [];
  for (let n = sel && sel[0]; n; n = n.parent) chain.push(rangeText(APP, n.range));
  check('selection ranges: the name, then bigger pieces', chain[0] === 'name' && chain.length >= 4, chain);

  // semantic tokens
  const st = await call(() => T.provider('documentSemanticTokens').provideDocumentSemanticTokens(app, token()));
  check('semantic tokens (full): numbers in fives', st instanceof vscode.SemanticTokens && st.data.length > 0 &&
        st.data.length % 5 === 0, st);
  const str = await call(() => T.provider('documentRangeSemanticTokens').provideDocumentRangeSemanticTokens(app,
    new vscode.Range(5, 0, 7, 0), token()));
  check('semantic tokens (range)', str instanceof vscode.SemanticTokens && str.data.length % 5 === 0 &&
        str.data.length > 0 && str.data[0] === 5, str);

  // inlay hints
  const all = new vscode.Range(0, 0, APP.split('\n').length, 0);
  const ih = await call(() => T.provider('inlayHints').provideInlayHints(app, all, token()));
  const labels = (ih || []).map((h) => `${h.position.line}${typeof h.label === 'string' ? h.label
                                                                                        : h.label.map((x) => x.value).join('')}`);
  check('inlay hints: the types of lets', labels.includes('3: Shape') && labels.includes('8: int') &&
        (ih || []).every((h) => h instanceof vscode.InlayHint), labels);
  const sqHint = (ih || []).find((h) => h.label === ': Shape');
  check('inlay hint position after a non-ASCII string (UTF-16)', sqHint &&
        APP.split('\n')[3].slice(0, sqHint.position.character).endsWith('let sq'), sqHint && sqHint.position);

  // rename across modules, with prepareRename; a keyword refused with the server's message
  const rp = T.provider('rename');
  const prep = await call(() => rp.prepareRename(shapes, pos(SHAPES, 'area*', 1), token()));
  check('prepareRename: the name and its placeholder', prep && prep.placeholder === 'area' &&
        rangeText(SHAPES, prep.range) === 'area', prep);
  const ren = await call(() => rp.provideRenameEdits(shapes, pos(SHAPES, 'area*', 1), 'surface', token()));
  let ok = ren instanceof vscode.WorkspaceEdit;
  if (ok) {
    const a2 = applyEdits(APP, editsFor(ren, app.uri));
    const s2 = applyEdits(SHAPES, editsFor(ren, shapes.uri));
    ok = !/\barea\b/.test(a2) && count(a2, 'surface') === 2 && s2.includes('proc surface*');
  }
  check('rename: edits in both modules', ok, ren && ren.ops);
  const bad = await call(() => rp.provideRenameEdits(shapes, pos(SHAPES, 'area*', 1), 'proc', token()));
  check('rename to a keyword: refused with the server\'s message (an error VS Code shows)',
        bad && bad.error instanceof Error && bad.error.message.length > 0, bad);

  // formatting
  const fmt = T.openDocument(p('fmt.nim'), 'nim', FMT);
  const fe = await call(() => T.provider('documentFormatting').provideDocumentFormattingEdits(fmt,
    { tabSize: 2, insertSpaces: true }, token()));
  const formatted = Array.isArray(fe) ? applyEdits(FMT, fe) : '';
  check('formatting: ned\'s formatter', fe && fe.every((e) => e instanceof vscode.TextEdit) &&
        formatted.includes('proc f(a: int): int =') && formatted.includes('echo f(2)'), formatted || fe);
  const rfe = await call(() => T.provider('documentRangeFormatting').provideDocumentRangeFormattingEdits(fmt,
    new vscode.Range(1, 0, 2, 0), { tabSize: 2, insertSpaces: true }, token()));
  const rf = Array.isArray(rfe) ? applyEdits(FMT, rfe) : '';
  check('range formatting: only those lines', rf.split('\n')[0] === FMT.split('\n')[0] && rf.includes('echo f(2)'),
        rf || rfe);

  // call and type hierarchy, implementations, document links, code lenses
  const ch = T.provider('callHierarchy');
  const items = await call(() => ch.prepareCallHierarchy(shapes, pos(SHAPES, 'area*', 1), token()));
  check('call hierarchy: the routine', Array.isArray(items) && items[0] instanceof vscode.CallHierarchyItem &&
        items[0].name === 'area', items);
  if (Array.isArray(items) && items[0]) {
    const inc = await call(() => ch.provideCallHierarchyIncomingCalls(items[0], token()));
    const callers = (inc || []).filter((c) => c.from.uri.toString() === app.uri.toString()).map((c) => c.from.name).sort();
    check('call hierarchy: incoming calls (the item sent back whole)', callers.includes('describe') &&
          (inc || []).every((c) => c instanceof vscode.CallHierarchyIncomingCall && c.fromRanges.length > 0), inc);
    const d = (inc || []).find((c) => c.from.name === 'describe');
    if (d) {
      const out = await call(() => ch.provideCallHierarchyOutgoingCalls(d.from, token()));
      check('call hierarchy: outgoing calls', (out || []).some((c) => c instanceof vscode.CallHierarchyOutgoingCall &&
            c.to.name === 'area'), out);
    }
  }
  const animals = T.openDocument(p('animals.nim'), 'nim', ANIMALS);
  const th = T.provider('typeHierarchy');
  const titems = await call(() => th.prepareTypeHierarchy(animals, pos(ANIMALS, 'Dog* ='), token()));
  check('type hierarchy: the type', Array.isArray(titems) && titems[0] instanceof vscode.TypeHierarchyItem &&
        titems[0].name === 'Dog', titems);
  if (Array.isArray(titems) && titems[0]) {
    const sup = await call(() => th.provideTypeHierarchySupertypes(titems[0], token()));
    check('type hierarchy: supertypes', Array.isArray(sup) && sup.map((x) => x.name).join() === 'Animal', sup);
    if (Array.isArray(sup) && sup[0]) {
      const sub = await call(() => th.provideTypeHierarchySubtypes(sup[0], token()));
      check('type hierarchy: subtypes', (sub || []).map((x) => x.name).sort().join() === 'Cat,Dog', sub);
    }
  }
  const impl = await call(() => T.provider('implementation').provideImplementation(animals,
    pos(ANIMALS, 'speak*(a: Animal)', 1), token()));
  check('implementation: the base method\'s overrides', Array.isArray(impl) && impl.length === 2, impl);
  const links = await call(() => T.provider('documentLink').provideDocumentLinks(app, token()));
  check('document links: `import shapes` → shapes.nim', (links || []).some((l) => l instanceof vscode.DocumentLink &&
        l.target && l.target.toString() === shapes.uri.toString() && rangeText(APP, l.range) === 'shapes'), links);
  const lensText = 'when isMainModule:\n  echo "hi"\n';
  const lensDoc = T.openDocument(p('main.nim'), 'nim', lensText);
  const lenses = await call(() => T.provider('codeLens').provideCodeLenses(lensDoc, token()));
  check('code lens: "Run the file" on when isMainModule, with the server\'s command (a registered VS Code command)',
        (lenses || []).some((l) => l instanceof vscode.CodeLens && l.command && /Run the file/.test(l.command.title) &&
                             T.state.commands.has(l.command.command)), lenses);

  // diagnostics for a file with a mistake; a quick fix for it; the mistake fixed by an incremental edit
  const badDoc = T.openDocument(p('bad.nim'), 'nim', BAD);
  // (the problems come from nim check: none without nim)
  const ds = !haveNim ? undefined : await waitFor(() => {
    const x = diagnostics(badDoc.uri);
    return x && x.some((d) => /echoo/.test(d.message)) ? x : undefined;
  }, 60000);
  const err = (ds || []).find((d) => /echoo/.test(d.message));
  if (haveNim) {
    check('diagnostics: the undeclared name, an error, on the name', err instanceof vscode.Diagnostic &&
          err.severity === vscode.DiagnosticSeverity.Error && rangeText(BAD, err.range) === 'echoo',
          ds || diagnostics(badDoc.uri));
  } else {
    skip('diagnostics, and their quick fix', 'nim is not on PATH: no compiler to check with');
  }
  if (err) {
    const acts = await call(() => T.provider('codeActions').provideCodeActions(badDoc, err.range,
      { diagnostics: [err], only: undefined, triggerKind: vscode.CodeActionTriggerKind.Invoke }, token()));
    const fix = (acts || []).find((a) => a instanceof vscode.CodeAction && a.kind && a.kind.value === 'quickfix' &&
                                         /\becho\b/.test(a.title) && a.edit);
    check('code action: a quick fix for it, with its edit', fix &&
          applyEdits(BAD, editsFor(fix.edit, badDoc.uri)).includes('echo sh.width'), (acts || []).map((a) => a.title));
  }
  // a refactoring listed without its edit: the edit comes when it is picked (codeAction/resolve)
  const exprRange = new vscode.Range(pos(APP, 'sq.area + 1'), pos(APP, 'sq.area + 1', 11));
  const refs2 = await call(() => T.provider('codeActions').provideCodeActions(app, exprRange,
    { diagnostics: [], only: undefined, triggerKind: vscode.CodeActionTriggerKind.Invoke }, token()));
  const lazy = (refs2 || []).find((a) => a instanceof vscode.CodeAction && !a.edit && !a.command);
  if (lazy) {
    const res = await call(() => T.provider('codeActions').resolveCodeAction(lazy, token()));
    check(`codeAction/resolve: "${lazy.title}" gets its edit when picked`, res === lazy &&
          lazy.edit instanceof vscode.WorkspaceEdit && lazy.edit.entries().length > 0, res);
  } else {
    check('code actions on an expression: a refactoring listed without its edit (to resolve)', false,
          (refs2 || []).map((a) => a.title));
  }
  const changesBefore = count(output(), "Sending notification 'textDocument/didChange'");
  T.editDocument(badDoc, [{ range: new vscode.Range(3, 4, 3, 5), text: '' }]);     // echoo → echo
  check('didChange: incremental (the range and its text, the new version)',
        count(output(), "Sending notification 'textDocument/didChange'") === changesBefore + 1 &&
        /"version": 2\s*\},\s*"contentChanges": \[\s*\{\s*"range": \{\s*"start": \{\s*"line": 3,\s*"character": 4/
          .test(output().split("Sending notification 'textDocument/didChange'").pop()),
        output().split("Sending notification 'textDocument/didChange'").pop().slice(0, 400));
  if (haveNim) {
    const fixed = await waitFor(() => {
      const x = diagnostics(badDoc.uri);
      return x && !x.some((d) => d.severity === vscode.DiagnosticSeverity.Error) ? x : undefined;
    }, 60000);
    check('diagnostics: the error goes away after the edit', fixed !== undefined, diagnostics(badDoc.uri));
  }

  // cancellation: VS Code no longer wants the answer — nedls is told, the provider gives nothing
  const cts = new vscode.CancellationTokenSource();
  const asked = T.provider('hover').provideHover(app, pos(APP, 'describe', 1), cts.token);   // (sent now …)
  cts.cancel();                                                                               // (… then not wanted)
  const t1 = Date.now();
  const cancelled = await call(() => asked, 5000);
  check('cancellation: $/cancelRequest sent, the provider answers nothing at once', cancelled === undefined &&
        Date.now() - t1 < 1000 && /Sending notification '\$\/cancelRequest'[\s\S]*"id": \d+/.test(output()),
        cancelled);
  const early = new vscode.CancellationTokenSource();
  early.cancel();
  const sentBefore = count(output(), "Sending request 'textDocument/hover");
  const none = await call(() => T.provider('hover').provideHover(app, pos(APP, 'describe', 1), early.token));
  check('cancelled before it is asked: nothing sent', none === undefined &&
        count(output(), "Sending request 'textDocument/hover") === sentBefore, none);

  // settings: a change goes to the running server (inlay hints off, then on again)
  T.setSetting('nedls.inlayHints', false);
  check('a setting changed: workspace/didChangeConfiguration with the nedls settings',
        /Sending notification 'workspace\/didChangeConfiguration'[\s\S]*"inlayHints": false/.test(output()));
  const off = await call(() => T.provider('inlayHints').provideInlayHints(app, all, token()));
  T.setSetting('nedls.inlayHints', true);
  const on = await call(() => T.provider('inlayHints').provideInlayHints(app, all, token()));
  check('… and nedls follows it (no inlay hints, then hints again)', Array.isArray(off) && off.length === 0 &&
        Array.isArray(on) && on.length > 0, [off, on && on.length]);

  // save, close, files changed on disk
  T.saveDocument(app);
  check('didSave', /Sending notification 'textDocument\/didSave'/.test(output()));
  T.closeDocument(badDoc);
  check('didClose', /Sending notification 'textDocument\/didClose'[\s\S]*bad\.nim/.test(output()));
  const w = T.state.watchers.find((x) => !x.disposed);
  w.change.fire(vscode.Uri.file(path.join(root, 'proj.nimble')));
  w.create.fire(vscode.Uri.file(p('extra.nim')));
  check('files changed on disk: didChangeWatchedFiles, the two in one notification', await waitFor(() =>
    /Sending notification 'workspace\/didChangeWatchedFiles'[\s\S]*proj\.nimble[\s\S]*"type": 2[\s\S]*extra\.nim[\s\S]*"type": 1/
      .test(output()), 3000));

  // a module renamed in the Explorer: the imports that name it follow (workspace/willRenameFiles, before the rename)
  const waits = [];
  T.events.willRename.fire({ files: [{ oldUri: shapes.uri, newUri: vscode.Uri.file(p('geometry.nim')) }],
                             waitUntil: (x) => waits.push(x), token: token() });
  const renameEdit = waits.length === 1 ? await call(() => waits[0]) : undefined;
  check('a module renamed: the import in app.nim follows', renameEdit instanceof vscode.WorkspaceEdit &&
        applyEdits(APP, editsFor(renameEdit, app.uri)).includes('import geometry'), renameEdit || waits.length);
  T.events.willRename.fire({ files: [{ oldUri: vscode.Uri.file(p('notes.txt')), newUri: vscode.Uri.file(p('n.txt')) }],
                             waitUntil: (x) => waits.push(x), token: token() });
  check('a file the server\'s filters leave out: not sent', waits.length === 1, waits.length);

  // a folder added to the workspace; the trace setting changed
  T.events.folders.fire({ added: [{ uri: vscode.Uri.file(path.join(root, 'more')), name: 'more', index: 1 }],
                         removed: [] });
  check('workspace folders changed: didChangeWorkspaceFolders',
        /Sending notification 'workspace\/didChangeWorkspaceFolders'[\s\S]*"name": "more"/.test(output()));
  T.setSetting('nedls.trace.server', 'verbose');
  check('the trace setting changed: $/setTrace', /Sending notification '\$\/setTrace'[\s\S]*"value": "verbose"/
    .test(output()));

  // restart: a new server, the old one gone, the providers and documents carried over
  const opensBefore = count(output(), "Sending notification 'textDocument/didOpen'");
  await call(() => vscode.commands.executeCommand('nedls.restart'), 60000);
  const pid1 = lastPid();
  check('restart: a new nedls', pid1 > 0 && pid1 !== pid0, pid1);
  check('restart: the old one ended cleanly (shutdown, exit → exit code 0)', !alive(pid0) &&
        /nedls ended \(exit code 0\)/.test(output()));
  check('restart: one provider of each kind, not two', kinds.every((k) => T.providers(k).length === 1),
        kinds.filter((k) => T.providers(k).length !== 1));
  check('restart: the open documents opened in the new server',
        count(output(), "Sending notification 'textDocument/didOpen'") - opensBefore === 5,
        count(output(), "Sending notification 'textDocument/didOpen'") - opensBefore);
  const hv2 = await call(() => T.provider('hover').provideHover(app, pos(APP, 'newShape', 2), token()));
  check('restart: the new server answers', hv2 && /Makes a shape/.test(hv2.contents.map(mdText).join('')), hv2);

  // nedls.languages changed: a new server, for those languages only
  const startsBefore = count(output(), 'nedls started');
  T.setSetting('nedls.languages', ['nim']);
  const relang = await waitFor(() => count(output(), 'nedls started') === startsBefore + 1 &&
                                     T.providers('hover').length === 1 && T.providers('hover')[0].selector.length === 2,
                               30000);
  check('nedls.languages changed: restarted, its providers for nim only', relang &&
        JSON.stringify(T.providers('hover')[0].selector) === JSON.stringify([{ scheme: 'file', language: 'nim' },
                                                                             { scheme: 'untitled', language: 'nim' }]),
        T.providers('hover').map((x) => x.selector));
  await waitFor(() => /is running[\s\S]*Sending notification 'textDocument\/didOpen'/.test(
    output().split('nedls started').pop()), 30000);
  const pid2 = lastPid();
  check('nedls.languages changed: the server before it ended', pid2 !== pid1 && !alive(pid1), [pid1, pid2]);

  // deactivate: shutdown and exit, nothing left behind
  const ended = count(output(), 'nedls ended (exit code 0)');
  const ch0 = T.state.outputs[T.state.outputs.length - 1];
  const de = await call(() => ext.deactivate(), 15000);
  check('deactivate: resolves', !(de && de.error), de && de.error && de.error.message);
  check('deactivate: nedls ended cleanly (exit code 0)', count(ch0.text, 'nedls ended (exit code 0)') === ended + 1 &&
        !alive(pid2), ch0.text.slice(-300));
  check('deactivate: providers, server commands, watcher and problems gone', T.state.providers.length === 0 &&
        !T.state.commands.has('nedls.run') && T.state.watchers.every((x) => x.disposed) &&
        T.state.collections.every((c) => c.disposed), T.state.providers.map((x) => x.kind));
  for (const d of context.subscriptions) d.dispose();
  for (const d of vscode.workspace.textDocuments.slice()) T.closeDocument(d);
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

// ── against a fake server: what nedls rarely asks, and a crash ──

const FAKE = String.raw`
'use strict';
if (process.env.FAKE_DIE) process.exit(5);
const fs = require('fs');
const report = process.env.FAKE_REPORT;
const dir = process.env.FAKE_DIR;
const state = { received: [], answers: {}, done: false, init: null };
const save = () => fs.writeFileSync(report, JSON.stringify(state));
let buf = Buffer.alloc(0);
let nextId = 0;
let shut = false;
const waiting = new Map();
function send(m) {
  const b = Buffer.from(JSON.stringify(m));
  process.stdout.write(Buffer.concat([Buffer.from('Content-Length: ' + b.length + '\r\n\r\n'), b]));
}
function request(method, params) {
  const id = 'fake-' + (++nextId);
  send({ jsonrpc: '2.0', id, method, params });
  return new Promise((r) => waiting.set(id, r));
}
const notify = (method, params) => send({ jsonrpc: '2.0', method, params });
process.stdin.on('data', (c) => {
  buf = Buffer.concat([buf, c]);
  for (;;) {
    const e = buf.indexOf('\r\n\r\n');
    if (e < 0) return;
    const n = +/Content-Length: (\d+)/i.exec(buf.toString('ascii', 0, e))[1];
    if (buf.length < e + 4 + n) return;
    const msg = JSON.parse(buf.toString('utf8', e + 4, e + 4 + n));
    buf = buf.subarray(e + 4 + n);
    handle(msg);
  }
});
process.stdin.on('end', () => process.exit(1));
const CAPS = { textDocumentSync: 1, hoverProvider: true, renameProvider: true,
               completionProvider: { triggerCharacters: ['.'] }, executeCommandProvider: { commands: ['fake.cmd'] } };
function handle(m) {
  if (m.method === undefined) {
    const r = waiting.get(m.id);
    if (r) { waiting.delete(m.id); r(m); }
    return;
  }
  if (m.id !== undefined) {
    if (m.method === 'initialize') {
      state.init = m.params;
      save();
      send({ jsonrpc: '2.0', id: m.id, result: { capabilities: CAPS, serverInfo: { name: 'fake', version: '0' } } });
    } else if (m.method === 'shutdown') {
      shut = true;
      send({ jsonrpc: '2.0', id: m.id, result: null });
    } else if (m.method === 'textDocument/hover') {
      process.exit(3);                                  // (a crash)
    } else if (m.method === 'textDocument/completion') {
      send({ jsonrpc: '2.0', id: m.id, result: [{ label: 'fakeItem', kind: 3, insertText: 'fakeItem($1)',
                                                  insertTextFormat: 2, documentation: { kind: 'markdown', value: '**bold**' },
                                                  labelDetails: { detail: '(x)' } }] });
    } else if (m.method === 'workspace/executeCommand') {
      state.executed = m.params;
      save();
      send({ jsonrpc: '2.0', id: m.id, result: 42 });
    } else if (m.method === 'textDocument/rename') {
      send({ jsonrpc: '2.0', id: m.id, error: { code: -32602, message: 'fake says no' } });
    } else {
      send({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'no ' + m.method } });
    }
    return;
  }
  state.received.push({ method: m.method, params: m.params });
  save();
  if (m.method === 'exit') process.exit(shut ? 0 : 1);
  if (m.method === 'initialized' && !process.env.FAKE_QUIET) script().then(() => { state.done = true; save(); });
}
async function script() {
  const a = state.answers;
  const u = (f) => 'file://' + dir + '/' + f;
  const r0 = { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } };
  notify('window/logMessage', { type: 3, message: 'fake log line' });
  notify('window/showMessage', { type: 2, message: 'fake warning' });
  a.pick = await request('window/showMessageRequest', { type: 1, message: 'pick one',
                                                         actions: [{ title: 'A' }, { title: 'B', extra: 7 }] });
  a.config = await request('workspace/configuration', { items: [{ section: 'nedls' }, { section: 'nedls.inlayHints' },
                                                               { section: 'nedls.trace.server' }] });
  a.create = await request('window/workDoneProgress/create', { token: 'p1' });
  notify('$/progress', { token: 'p1', value: { kind: 'begin', title: 'Fake work', message: 'starting' } });
  notify('$/progress', { token: 'p1', value: { kind: 'report', message: 'half', percentage: 50 } });
  notify('$/progress', { token: 'p1', value: { kind: 'end', message: 'done' } });
  a.register = await request('client/registerCapability', { registrations: [{ id: 'w', method: 'workspace/didChangeWatchedFiles',
                                                                               registerOptions: { watchers: [] } }] });
  a.unknown = await request('fake/unknownRequest', {});
  a.folders = await request('workspace/workspaceFolders', null);
  a.refresh = await request('workspace/semanticTokens/refresh', null);
  a.edit = await request('workspace/applyEdit', { label: 'fake', edit: { documentChanges: [
    { kind: 'create', uri: u('new.nim'), options: { ignoreIfExists: true } },
    { textDocument: { uri: u('new.nim'), version: null }, edits: [{ range: r0, newText: 'echo 1\n' }] },
    { kind: 'rename', oldUri: u('new.nim'), newUri: u('renamed.nim'), options: { overwrite: true } },
    { kind: 'delete', uri: u('old.nim'), options: { ignoreIfNotExists: true } }] } });
  a.stale = await request('workspace/applyEdit', { edit: { documentChanges: [
    { textDocument: { uri: u('main.nim'), version: 999 }, edits: [{ range: r0, newText: 'x' }] }] } });
  a.changes = await request('workspace/applyEdit', { edit: { changes: { [u('main.nim')]: [{ range: r0, newText: '# hi\n' }] } } });
}
`;

async function withFake(root) {
  const fake = path.join(root, 'fakels.js');
  fs.writeFileSync(fake, `#!${process.execPath}\n${FAKE}`);
  fs.chmodSync(fake, 0o755);
  const reportPath = path.join(root, 'report.json');
  process.env.FAKE_REPORT = reportPath;
  process.env.FAKE_DIR = root;
  const report = () => { try { return JSON.parse(fs.readFileSync(reportPath, 'utf8')); } catch (_) { return null; } };

  T.state.settings = settings(fake, 'messages');
  T.state.messages = [];
  T.state.edits = [];
  T.state.progress = [];
  vscode.workspace.workspaceFolders = [{ uri: vscode.Uri.file(root), name: 'fake', index: 0 }];
  const mainText = 'echo "main"\n';
  const main = T.openDocument(path.join(root, 'main.nim'), 'nim', mainText);     // (open before it starts)
  T.state.answer = (type, message, items) => (message === 'pick one' ? items[1] : undefined);
  const context = { subscriptions: [] };
  const act = await call(() => ext.activate(context), 30000);
  check('fake server: activate', !(act && act.error), act && act.error);
  const r = await waitFor(() => { const x = report(); return x && x.done ? x : undefined; }, 20000);
  check('fake server: its requests were all answered', r && r.done, report());
  if (!r) return;
  const a = r.answers;
  const init = r.init || {};
  check('initialize: rootUri, workspace folders, client info, trace, the documents\' capabilities',
        init.rootUri === vscode.Uri.file(root).toString() && init.workspaceFolders[0].name === 'fake' &&
        init.clientInfo && init.trace === 'messages' && init.processId === process.pid &&
        init.capabilities.textDocument.synchronization.didSave === true, init);
  check('initialize: the type hierarchy offered only where VS Code has it',
        !!init.capabilities.textDocument.typeHierarchy === !!vscode.languages.registerTypeHierarchyProvider);
  check('window/logMessage → the log', /fake log line/.test(output()));
  check('window/showMessage → a warning', T.state.messages.some((m) => m.type === 2 && m.message === 'fake warning'));
  check('window/showMessageRequest → buttons; the one picked goes back whole',
        T.state.messages.some((m) => m.type === 1 && m.message === 'pick one' && m.items.map((i) => i.title).join() === 'A,B') &&
        JSON.stringify(a.pick.result) === JSON.stringify({ title: 'B', extra: 7 }), a.pick);
  check('workspace/configuration → the nedls settings, by section', Array.isArray(a.config.result) &&
        a.config.result[0].path === T.state.settings['nedls.path'] && a.config.result[0].trace.server === 'messages' &&
        a.config.result[1] === true && a.config.result[2] === 'messages', a.config);
  check('window/workDoneProgress/create → null; $/progress shown and ended', a.create.result === null &&
        await waitFor(() => T.state.progress.some((x) => x.title === 'Fake work' && x.done &&
                                                       x.messages.join() === 'starting,half 50%'), 3000),
        T.state.progress);
  check('client/registerCapability → null', a.register.result === null && !a.register.error, a.register);
  check('an unknown request → MethodNotFound, not silence', a.unknown.error && a.unknown.error.code === -32601,
        a.unknown);
  check('workspace/workspaceFolders → the folders', Array.isArray(a.folders.result) &&
        a.folders.result[0].uri === vscode.Uri.file(root).toString(), a.folders);
  check('workspace/semanticTokens/refresh → null', a.refresh.result === null, a.refresh);
  const e0 = T.state.edits[0];
  check('workspace/applyEdit: files created, renamed and deleted, in order, among the text edits',
        a.edit.result && a.edit.result.applied === true && e0 &&
        e0.ops.map((o) => o.type).join() === 'create,text,rename,delete' &&
        e0.ops[0].options.ignoreIfExists === true && e0.ops[2].options.overwrite === true &&
        e0.ops[3].options.ignoreIfNotExists === true && e0.ops[1].edit.newText === 'echo 1\n', [a.edit, e0 && e0.ops]);
  check('workspace/applyEdit: an edit for an older version of an open document is refused',
        a.stale.result && a.stale.result.applied === false && T.state.edits.length === 2, a.stale);
  check('workspace/applyEdit: changes (by URI)', a.changes.result && a.changes.result.applied === true &&
        T.state.edits[1].ops[0].uri.toString() === main.uri.toString(), a.changes);

  // full sync (the server asked for textDocumentSync 1): the whole text each time
  T.editDocument(main, [{ range: new vscode.Range(0, 6, 0, 10), text: 'MAIN' }]);
  T.saveDocument(main);
  const got = await waitFor(() => {
    const x = report();
    return x && x.received.some((m) => m.method === 'textDocument/didSave') ? x : undefined;
  }, 5000);
  const opened = got && got.received.find((m) => m.method === 'textDocument/didOpen');
  const changed = got && got.received.find((m) => m.method === 'textDocument/didChange');
  const saved = got && got.received.find((m) => m.method === 'textDocument/didSave');
  check('a document open before the server started: didOpen', opened &&
        opened.params.textDocument.text === mainText && opened.params.textDocument.languageId === 'nim', opened);
  check('full sync: didChange carries the whole text, no range', changed &&
        JSON.stringify(changed.params.contentChanges) === JSON.stringify([{ text: 'echo "MAIN"\n' }]) &&
        changed.params.textDocument.version === 2, changed);
  check('didSave without the text (not asked for)', saved && saved.params.text === undefined, saved);

  // a completion item as a snippet, its label details, its Markdown documentation
  const cl = await call(() => T.provider('completion').provideCompletionItems(main, new vscode.Position(0, 0), token(),
    { triggerKind: vscode.CompletionTriggerKind.Invoke }));
  const it = cl && cl.items && cl.items[0];
  check('completion: a snippet (SnippetString), label details, Markdown documentation', it &&
        it.insertText instanceof vscode.SnippetString && it.insertText.value === 'fakeItem($1)' &&
        it.label.label === 'fakeItem' && it.label.detail === '(x)' && it.documentation.value === '**bold**' &&
        it.kind === vscode.CompletionItemKind.Function, it);
  check('completion: no resolve when the server offers none',
        typeof T.provider('completion').resolveCompletionItem !== 'function');
  const ex = await call(() => vscode.commands.executeCommand('fake.cmd', 'one', 2));
  check('a server command run from VS Code → workspace/executeCommand with its arguments', ex === 42 &&
        JSON.stringify((report() || {}).executed) === JSON.stringify({ command: 'fake.cmd', arguments: ['one', 2] }),
        [ex, (report() || {}).executed]);
  const rn = await call(() => T.provider('rename').provideRenameEdits(main, new vscode.Position(0, 1), 'x', token()));
  check('rename refused by the server: its message thrown', rn && rn.error && rn.error.message === 'fake says no', rn);
  check('only the providers the server has', T.state.providers.map((x) => x.kind).sort().join() ===
        'completion,hover,rename', T.state.providers.map((x) => x.kind));

  // a crash: the waiting request answered (nothing), a message with Restart, and no restart on its own
  const hv = await call(() => T.provider('hover').provideHover(main, new vscode.Position(0, 1), token()), 10000);
  check('a crash: the request waiting gets no answer, at once (not a hang)', hv === undefined, hv);
  const msg = await waitFor(() => T.state.messages.find((m) => /stopped unexpectedly/.test(m.message)), 5000);
  check('a crash: "nedls stopped unexpectedly (exit code 3)" with Restart and Show the log', msg &&
        /exit code 3/.test(msg.message) && msg.items.join() === 'Restart,Show the log', msg);
  check('a crash: its providers and server commands gone', T.state.providers.length === 0 &&
        !T.state.commands.has('fake.cmd'));
  await sleep(1500);
  check('a crash: not started again on its own', count(output(), 'nedls started') === 1, count(output(), 'nedls started'));
  process.env.FAKE_QUIET = '1';
  await call(() => vscode.commands.executeCommand('nedls.restart'), 20000);
  check('Restart (the command): running again', count(output(), 'nedls started') === 2 &&
        T.providers('hover').length === 1, count(output(), 'nedls started'));
  // the second crash answered with the button: started once more, and only once
  T.state.answer = (type, message, items) => (/stopped unexpectedly/.test(message) ? 'Restart' : undefined);
  await call(() => T.provider('hover').provideHover(main, new vscode.Position(0, 1), token()), 10000);
  await waitFor(() => count(output(), 'nedls started') === 3 && T.providers('hover').length === 1, 10000);
  await sleep(1000);
  check('the Restart button: started again, once', count(output(), 'nedls started') === 3 &&
        T.providers('hover').length === 1, count(output(), 'nedls started'));
  const ch0 = T.state.outputs[T.state.outputs.length - 1];
  const de = await call(() => ext.deactivate(), 15000);
  check('fake server: deactivate ends it cleanly', !(de && de.error) && /nedls ended \(exit code 0\)\n$/.test(ch0.text),
        ch0.text.slice(-200));
  for (const d of context.subscriptions) d.dispose();
  for (const d of vscode.workspace.textDocuments.slice()) T.closeDocument(d);
  delete process.env.FAKE_QUIET;
}

// ── the framing, without a server ──

async function framing() {
  const { PassThrough } = require('stream');
  const { Connection } = require(path.join(repo, 'editors', 'vscode', 'lsp.js'));
  const input = new PassThrough();
  const output = new PassThrough();
  const conn = new Connection(input, output, () => {});
  const got = [];
  conn.onNotification('t/n', (p) => got.push(p));
  const frame = (msg, header) => {
    const body = Buffer.from(JSON.stringify(msg), 'utf8');
    return Buffer.concat([Buffer.from((header || 'Content-Length') + ': ' + body.length +
                                      '\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n'), body]);
  };
  const big = 'é🎉'.repeat(100000);
  const all = Buffer.concat([frame({ jsonrpc: '2.0', method: 't/n', params: { k: 1, s: 'héllo 🎉' } }),
                             frame({ jsonrpc: '2.0', method: 't/n', params: { k: 2 } }, 'content-length'),
                             frame({ jsonrpc: '2.0', method: 't/n', params: { k: 3, s: big } })]);
  // byte by byte through the first two messages (a UTF-8 character split between pieces), then pieces of 1000
  const firstTwo = all.indexOf('{"jsonrpc":"2.0","method":"t/n","params":{"k":3');
  for (let i = 0; i < firstTwo; i++) input.write(all.subarray(i, i + 1));
  for (let i = firstTwo; i < all.length; i += 1000) input.write(all.subarray(i, i + 1000));
  await waitFor(() => got.length === 3, 5000);
  check('framing: messages split anywhere (inside a UTF-8 character too), headers in any case, a long one in ' +
        'many pieces', got.length === 3 && got[0].s === 'héllo 🎉' && got[1].k === 2 && got[2].s === big,
        got.map((x) => x.k));
  // two answers in one piece; an unknown request answered MethodNotFound
  const sent = [];
  output.on('data', (d) => sent.push(d.toString('utf8')));
  const a = conn.request('t/a', {});
  const b = conn.request('t/b', {});
  input.write(Buffer.concat([frame({ jsonrpc: '2.0', id: 2, result: 'B' }), frame({ jsonrpc: '2.0', id: 1, result: 'A' }),
                             frame({ jsonrpc: '2.0', id: 'x', method: 't/unknown' })]));
  const [ra, rb] = await Promise.all([a, b]);
  await waitFor(() => sent.join('').includes('-32601'), 2000);
  check('framing: answers matched to their requests by id, in any order', ra === 'A' && rb === 'B', [ra, rb]);
  check('framing: an unknown request → MethodNotFound', /"id":"x","error":\{"code":-32601/.test(sent.join('')),
        sent.join(''));
  const c = conn.request('t/c', {});
  input.end();
  const rc = await c.then(() => 'answered', (e) => e.message);
  check('framing: the stream closed → the request waiting gets an error', /closed/.test(rc), rc);
}

// ── a program that is not there ──

async function withMissing(root) {
  T.state.settings = settings(path.join(root, 'no-such-nedls'), 'off');
  T.state.messages = [];
  T.state.answer = (type, message, items) => (/did not start/.test(message) ? items[0] : undefined);
  const context = { subscriptions: [] };
  const act = await call(() => ext.activate(context), 15000);
  check('nedls missing: activate still resolves', !(act && act.error), act && act.error);
  const m = await waitFor(() => T.state.messages.find((x) => /did not start/.test(x.message)), 3000);
  check('nedls missing: "nedls did not start (…): … ENOENT … Is it installed?" with Set nedls.path', m &&
        m.type === 1 && /ENOENT/.test(m.message) && /Is it installed\?/.test(m.message) &&
        m.items.join() === 'Set nedls.path', m);
  check('nedls missing: the button opens the setting', await waitFor(() => T.state.executed.some(
    (x) => x[0] === 'workbench.action.openSettings' && x[1] === 'nedls.path'), 2000));
  check('nedls missing: nothing registered', T.state.providers.length === 0);
  const de = await call(() => ext.deactivate(), 5000);
  check('nedls missing: deactivate resolves', !(de && de.error), de);
  for (const d of context.subscriptions) d.dispose();

  // a server that ends before it answers initialize: how it ended, in the message
  T.state.settings = settings(path.join(root, 'fake', 'fakels.js'), 'off');
  T.state.messages = [];
  process.env.FAKE_DIE = '1';
  const ctx2 = { subscriptions: [] };
  await call(() => ext.activate(ctx2), 15000);
  const m2 = await waitFor(() => T.state.messages.find((x) => /did not start/.test(x.message)), 5000);
  check('a server that ends at once: "nedls did not start (…): it ended at once (exit code 5)"', m2 &&
        /it ended at once \(exit code 5\)/.test(m2.message), m2);
  await call(() => ext.deactivate(), 5000);
  for (const d of ctx2.subscriptions) d.dispose();
  delete process.env.FAKE_DIE;
}

async function main() {
  if (!fs.existsSync(nedls)) {
    console.log(`no nedls at ${nedls} — usage: node tests/vscode/test_extension.js ./nedls`);
    process.exit(2);
  }
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'nedls-vscode-'));
  // (nobody's settings, and a cache of its own)
  process.env.XDG_CONFIG_HOME = path.join(root, 'config');
  process.env.XDG_CACHE_HOME = path.join(root, 'cache');
  const proj = path.join(root, 'proj');
  const fakeDir = path.join(root, 'fake');
  for (const d of [path.join(proj, 'src'), fakeDir, process.env.XDG_CONFIG_HOME]) fs.mkdirSync(d, { recursive: true });
  let failedHard = null;
  try {
    await framing();
    await withNedls(proj);
    await withFake(fakeDir);
    await withMissing(root);
  } catch (e) {
    failedHard = e;
    check('the test ran to its end', false, e && e.stack);
  }
  const failed = results.filter((r) => !r[1]);
  console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`);
  if (failed.length === 0 && !failedHard) fs.rmSync(root, { recursive: true, force: true });
  else {
    console.log(`(the project and the log are kept in ${root})`);
    const ch = T.state.outputs.map((c) => c.text).join('\n---\n');
    fs.writeFileSync(path.join(root, 'output.log'), ch);
  }
  process.exit(failed.length || failedHard ? 1 : 0);
}

main();

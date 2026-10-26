// Between LSP's JSON and VS Code's types, both ways. Positions need no arithmetic: an LSP character offset counts
// UTF-16 code units (the protocol's default, and the only encoding this client offers in initialize), and so does
// VS Code's Position.character — a line with "é" or "🎉" in it has the same columns on both sides.
//
// Some things the server sends must come back to it whole, with fields VS Code has no place for (a completion
// item's data, a code action's data, a call hierarchy item's data …): the VS Code object made from each is mapped
// to the JSON it was made from (`originals`), and that JSON is what goes back.
'use strict';

const vscode = require('vscode');

const originals = new WeakMap();

function original(x) {
  return x ? originals.get(x) : undefined;
}

// ── LSP → VS Code ──

function position(p) {
  // (VS Code throws on a negative line or column: a bad answer must not take a whole feature down)
  return new vscode.Position(Math.max(0, p.line | 0), Math.max(0, p.character | 0));
}

function range(r) {
  return r ? new vscode.Range(position(r.start), position(r.end)) : undefined;
}

function ranges(rs) {
  return (rs || []).map(range);
}

function uri(s) {
  return vscode.Uri.parse(s);
}

function location(l) {
  // (a workspace symbol may name its file only, with no range: its start then)
  return new vscode.Location(uri(l.uri), l.range ? range(l.range) : new vscode.Position(0, 0));
}

function locationLink(l) {
  return {
    originSelectionRange: range(l.originSelectionRange),
    targetUri: uri(l.targetUri),
    targetRange: range(l.targetRange),
    targetSelectionRange: range(l.targetSelectionRange || l.targetRange)
  };
}

// definition, declaration, type definition, implementation: a Location, Locations, or LocationLinks
function definition(r) {
  if (!Array.isArray(r)) return location(r);
  return r.map((x) => (x.targetUri !== undefined ? locationLink(x) : location(x)));
}

function locations(r) {
  return (Array.isArray(r) ? r : [r]).map(location);
}

// documentation: a plain string is plain text in LSP; MarkupContent says which it is
function documentation(d) {
  if (d === undefined || d === null) return undefined;
  if (typeof d === 'string') return d;
  if (d.kind === 'markdown') return new vscode.MarkdownString(d.value);
  return d.value;
}

function markdown(m) {
  if (typeof m === 'string') return new vscode.MarkdownString(m);          // (a MarkedString: Markdown)
  if (m.kind === 'markdown') return new vscode.MarkdownString(m.value);
  if (m.kind === 'plaintext') return new vscode.MarkdownString().appendText(m.value);
  return new vscode.MarkdownString().appendCodeblock(m.value, m.language);  // ({language, value})
}

function hover(h) {
  const contents = Array.isArray(h.contents) ? h.contents.map(markdown) : [markdown(h.contents)];
  return new vscode.Hover(contents, range(h.range));
}

function command(c) {
  const x = { title: c.title, command: c.command };
  if (c.arguments) x.arguments = c.arguments;
  if (c.tooltip) x.tooltip = c.tooltip;
  return x;
}

const severities = {
  1: vscode.DiagnosticSeverity.Error,
  2: vscode.DiagnosticSeverity.Warning,
  3: vscode.DiagnosticSeverity.Information,
  4: vscode.DiagnosticSeverity.Hint
};

function diagnostic(d) {
  const x = new vscode.Diagnostic(range(d.range), d.message || '',
                                  severities[d.severity] !== undefined ? severities[d.severity]
                                                                       : vscode.DiagnosticSeverity.Error);
  if (d.code !== undefined && d.code !== null) {
    x.code = d.codeDescription && d.codeDescription.href ? { value: d.code, target: uri(d.codeDescription.href) }
                                                        : d.code;
  }
  if (d.source) x.source = d.source;
  if (Array.isArray(d.relatedInformation)) {
    x.relatedInformation = d.relatedInformation.map(
      (r) => new vscode.DiagnosticRelatedInformation(location(r.location), r.message));
  }
  if (Array.isArray(d.tags)) {
    const tags = [];
    for (const t of d.tags) {
      if (t === 1) tags.push(vscode.DiagnosticTag.Unnecessary);       // (drawn faded)
      else if (t === 2) tags.push(vscode.DiagnosticTag.Deprecated);   // (drawn struck through)
    }
    if (tags.length) x.tags = tags;
  }
  originals.set(x, d);
  return x;
}

function textEdit(e) {
  return new vscode.TextEdit(range(e.range), e.newText);
}

function textEdits(es) {
  return (es || []).map(textEdit);
}

// A WorkspaceEdit: documentChanges when there are (they keep their order, files created, renamed and deleted
// among the text edits), else changes.
function workspaceEdit(we) {
  const edit = new vscode.WorkspaceEdit();
  if (!we) return edit;
  if (Array.isArray(we.documentChanges)) {
    for (const ch of we.documentChanges) {
      const o = ch.options || {};
      if (ch.kind === 'create') {
        edit.createFile(uri(ch.uri), { overwrite: !!o.overwrite, ignoreIfExists: !!o.ignoreIfExists });
      } else if (ch.kind === 'rename') {
        edit.renameFile(uri(ch.oldUri), uri(ch.newUri), { overwrite: !!o.overwrite, ignoreIfExists: !!o.ignoreIfExists });
      } else if (ch.kind === 'delete') {
        edit.deleteFile(uri(ch.uri), { recursive: !!o.recursive, ignoreIfNotExists: !!o.ignoreIfNotExists });
      } else if (ch.textDocument) {
        const u = uri(ch.textDocument.uri);
        for (const e of ch.edits || []) edit.replace(u, range(e.range), e.newText);
      }
    }
  } else if (we.changes) {
    for (const u of Object.keys(we.changes)) {
      const target = uri(u);
      for (const e of we.changes[u] || []) edit.replace(target, range(e.range), e.newText);
    }
  }
  return edit;
}

// LSP's kinds count from 1, VS Code's enums from 0 (and are otherwise in the same order)
function completionKind(k) {
  return typeof k === 'number' && k >= 1 && k <= 25 ? k - 1 : undefined;
}

function symbolKind(k) {
  return typeof k === 'number' && k >= 1 && k <= 26 ? k - 1 : vscode.SymbolKind.Property;
}

function symbolTags(tags) {
  return Array.isArray(tags) && tags.includes(1) ? [vscode.SymbolTag.Deprecated] : undefined;
}

// A completion item. The list's itemDefaults are put into it first, so the item sent back to be resolved is
// the whole of it.
function completionItem(i, defaults) {
  if (defaults) {
    i = Object.assign({}, i);
    if (i.commitCharacters === undefined && defaults.commitCharacters) i.commitCharacters = defaults.commitCharacters;
    if (i.insertTextFormat === undefined && defaults.insertTextFormat !== undefined) {
      i.insertTextFormat = defaults.insertTextFormat;
    }
    if (i.insertTextMode === undefined && defaults.insertTextMode !== undefined) i.insertTextMode = defaults.insertTextMode;
    if (i.data === undefined && defaults.data !== undefined) i.data = defaults.data;
    if (i.textEdit === undefined && defaults.editRange) {
      const text = i.textEditText !== undefined ? i.textEditText : i.insertText !== undefined ? i.insertText : i.label;
      i.textEdit = defaults.editRange.insert
        ? { newText: text, insert: defaults.editRange.insert, replace: defaults.editRange.replace }
        : { newText: text, range: defaults.editRange };
    }
  }
  const label = i.labelDetails
    ? { label: i.label, detail: i.labelDetails.detail, description: i.labelDetails.description }
    : i.label;
  const item = new vscode.CompletionItem(label);
  const kind = completionKind(i.kind);
  if (kind !== undefined) item.kind = kind;
  if (i.detail) item.detail = i.detail;
  const doc = documentation(i.documentation);
  if (doc !== undefined) item.documentation = doc;
  if (i.sortText !== undefined) item.sortText = i.sortText;
  if (i.filterText !== undefined) item.filterText = i.filterText;
  if (i.preselect) item.preselect = true;
  if (i.deprecated || (Array.isArray(i.tags) && i.tags.includes(1))) item.tags = [vscode.CompletionItemTag.Deprecated];
  const snippet = i.insertTextFormat === 2;
  const text = (s) => (snippet ? new vscode.SnippetString(s) : s);
  if (i.textEdit) {
    item.insertText = text(i.textEdit.newText);
    item.range = i.textEdit.range
      ? range(i.textEdit.range)
      : { inserting: range(i.textEdit.insert), replacing: range(i.textEdit.replace) };
  } else if (i.insertText !== undefined && i.insertText !== null) {
    item.insertText = text(i.insertText);
  }
  if (i.additionalTextEdits) item.additionalTextEdits = textEdits(i.additionalTextEdits);
  if (Array.isArray(i.commitCharacters)) item.commitCharacters = i.commitCharacters.slice();
  if (i.command) item.command = command(i.command);
  if (i.insertTextMode === 1) item.keepWhitespace = true;     // (asIs: the text goes in as it is, not re-indented)
  originals.set(item, i);
  return item;
}

function completionList(r) {
  const list = Array.isArray(r) ? { isIncomplete: false, items: r } : r;
  const items = (list.items || []).map((i) => completionItem(i, list.itemDefaults));
  return new vscode.CompletionList(items, !!list.isIncomplete);
}

// what completionItem/resolve adds to an item VS Code already shows: its documentation, its detail, the edits
// it makes elsewhere (the import it adds) and a command — what is shown and inserted stays as it was
function resolvedCompletion(item, r) {
  originals.set(item, r);
  if (r.detail) item.detail = r.detail;
  const doc = documentation(r.documentation);
  if (doc !== undefined) item.documentation = doc;
  if (r.additionalTextEdits) item.additionalTextEdits = textEdits(r.additionalTextEdits);
  if (r.command) item.command = command(r.command);
  return item;
}

function signatureHelp(s) {
  if (!Array.isArray(s.signatures) || s.signatures.length === 0) return undefined;
  const h = new vscode.SignatureHelp();
  h.signatures = s.signatures.map((sig) => {
    const si = new vscode.SignatureInformation(sig.label, documentation(sig.documentation));
    si.parameters = (sig.parameters || []).map((p) => new vscode.ParameterInformation(p.label,
                                                                                      documentation(p.documentation)));
    if (typeof sig.activeParameter === 'number') si.activeParameter = sig.activeParameter;
    return si;
  });
  h.activeSignature = typeof s.activeSignature === 'number' ? s.activeSignature : 0;
  h.activeParameter = typeof s.activeParameter === 'number' ? s.activeParameter : 0;
  return h;
}

function documentHighlights(hs) {
  return hs.map((h) => new vscode.DocumentHighlight(
    range(h.range), typeof h.kind === 'number' && h.kind >= 1 && h.kind <= 3 ? h.kind - 1 : undefined));
}

function symbolInformation(s) {
  const x = new vscode.SymbolInformation(s.name, symbolKind(s.kind), s.containerName || '', location(s.location));
  const tags = symbolTags(s.tags || (s.deprecated ? [1] : undefined));
  if (tags) x.tags = tags;
  return x;
}

function documentSymbol(s) {
  const r = range(s.range);
  let sel = range(s.selectionRange || s.range);
  if (!r.contains(sel)) sel = r;           // (VS Code refuses a symbol whose name lies outside it)
  const x = new vscode.DocumentSymbol(s.name || '?', s.detail || '', symbolKind(s.kind), r, sel);
  const tags = symbolTags(s.tags || (s.deprecated ? [1] : undefined));
  if (tags) x.tags = tags;
  x.children = (s.children || []).map(documentSymbol);
  return x;
}

// documentSymbol answers with a tree (DocumentSymbol) or a flat list (SymbolInformation, which has a location)
function documentSymbols(r) {
  if (r.length === 0) return [];
  return r[0].location !== undefined ? r.map(symbolInformation) : r.map(documentSymbol);
}

function codeAction(a) {
  if (typeof a.command === 'string') return command(a);        // (a bare Command)
  const x = new vscode.CodeAction(a.title, typeof a.kind === 'string' ? vscode.CodeActionKind.Empty.append(a.kind)
                                                                      : undefined);
  if (Array.isArray(a.diagnostics)) x.diagnostics = a.diagnostics.map(diagnostic);
  if (a.edit) x.edit = workspaceEdit(a.edit);
  if (a.command) x.command = command(a.command);
  if (a.isPreferred !== undefined) x.isPreferred = !!a.isPreferred;
  if (a.disabled) x.disabled = { reason: a.disabled.reason || '' };
  originals.set(x, a);
  return x;
}

function codeLens(l) {
  const x = new vscode.CodeLens(range(l.range), l.command ? command(l.command) : undefined);
  originals.set(x, l);
  return x;
}

const foldingKinds = {
  comment: vscode.FoldingRangeKind.Comment,
  imports: vscode.FoldingRangeKind.Imports,
  region: vscode.FoldingRangeKind.Region
};

function foldingRange(f) {
  return new vscode.FoldingRange(f.startLine, f.endLine, foldingKinds[f.kind]);
}

function selectionRange(s) {
  return new vscode.SelectionRange(range(s.range), s.parent ? selectionRange(s.parent) : undefined);
}

function tooltip(t) {
  if (typeof t === 'string') return t;
  return t && t.kind === 'markdown' ? new vscode.MarkdownString(t.value) : t && t.value;
}

function inlayLabelPart(p) {
  const x = new vscode.InlayHintLabelPart(p.value);
  if (p.tooltip !== undefined) x.tooltip = tooltip(p.tooltip);
  if (p.location) x.location = location(p.location);
  if (p.command) x.command = command(p.command);
  return x;
}

function inlayHint(h) {
  const label = typeof h.label === 'string' ? h.label : (h.label || []).map(inlayLabelPart);
  const kind = h.kind === 1 ? vscode.InlayHintKind.Type : h.kind === 2 ? vscode.InlayHintKind.Parameter : undefined;
  const x = new vscode.InlayHint(position(h.position), label, kind);
  if (h.tooltip !== undefined) x.tooltip = tooltip(h.tooltip);
  if (h.paddingLeft) x.paddingLeft = true;
  if (h.paddingRight) x.paddingRight = true;
  if (h.textEdits) x.textEdits = textEdits(h.textEdits);
  originals.set(x, h);
  return x;
}

// what inlayHint/resolve fills in: the tooltip, the edits a double-click makes, the label parts' extras
function resolvedInlayHint(hint, r) {
  originals.set(hint, r);
  if (r.tooltip !== undefined) hint.tooltip = tooltip(r.tooltip);
  if (r.textEdits) hint.textEdits = textEdits(r.textEdits);
  if (Array.isArray(r.label) && Array.isArray(hint.label) && r.label.length === hint.label.length) {
    hint.label = r.label.map(inlayLabelPart);
  }
  return hint;
}

function semanticTokens(t) {
  return new vscode.SemanticTokens(new Uint32Array(t.data || []), t.resultId);
}

function callHierarchyItem(i) {
  const x = new vscode.CallHierarchyItem(symbolKind(i.kind), i.name, i.detail || '', uri(i.uri), range(i.range),
                                         range(i.selectionRange || i.range));
  const tags = symbolTags(i.tags);
  if (tags) x.tags = tags;
  originals.set(x, i);
  return x;
}

function typeHierarchyItem(i) {
  const x = new vscode.TypeHierarchyItem(symbolKind(i.kind), i.name, i.detail || '', uri(i.uri), range(i.range),
                                         range(i.selectionRange || i.range));
  const tags = symbolTags(i.tags);
  if (tags) x.tags = tags;
  originals.set(x, i);
  return x;
}

function documentLink(l) {
  const x = new vscode.DocumentLink(range(l.range), l.target ? uri(l.target) : undefined);
  if (l.tooltip) x.tooltip = l.tooltip;
  originals.set(x, l);
  return x;
}

// ── VS Code → LSP ──

const c2p = {
  position(p) {
    return { line: p.line, character: p.character };
  },

  range(r) {
    return { start: c2p.position(r.start), end: c2p.position(r.end) };
  },

  diagnostic(d) {
    const o = originals.get(d);
    if (o) return o;                       // (ours: sent back as nedls sent it, data and all)
    const x = { range: c2p.range(d.range), message: d.message };
    if (typeof d.severity === 'number') x.severity = d.severity + 1;
    if (d.code !== undefined && d.code !== null) {
      if (typeof d.code === 'object') {
        x.code = d.code.value;
        if (d.code.target) x.codeDescription = { href: d.code.target.toString() };
      } else {
        x.code = d.code;
      }
    }
    if (d.source) x.source = d.source;
    if (Array.isArray(d.relatedInformation)) {
      x.relatedInformation = d.relatedInformation.map((r) => ({
        location: { uri: r.location.uri.toString(), range: c2p.range(r.location.range) }, message: r.message }));
    }
    if (Array.isArray(d.tags)) {
      x.tags = d.tags.map((t) => (t === vscode.DiagnosticTag.Unnecessary ? 1 : 2));
    }
    return x;
  },

  markup(m) {
    if (m === undefined || m === null) return undefined;
    if (typeof m === 'string') return m;
    return { kind: 'markdown', value: m.value };
  },

  // the signature help VS Code shows, sent along when it asks again while typing the call
  signatureHelp(h) {
    return {
      signatures: h.signatures.map((s) => {
        const x = { label: s.label, parameters: (s.parameters || []).map((p) => ({
          label: p.label, documentation: c2p.markup(p.documentation) })) };
        if (s.documentation !== undefined) x.documentation = c2p.markup(s.documentation);
        if (typeof s.activeParameter === 'number') x.activeParameter = s.activeParameter;
        return x;
      }),
      activeSignature: h.activeSignature,
      activeParameter: h.activeParameter
    };
  },

  hierarchyItem(x) {
    return originals.get(x) || {
      name: x.name, kind: x.kind + 1, detail: x.detail, uri: x.uri.toString(), range: c2p.range(x.range),
      selectionRange: c2p.range(x.selectionRange), tags: x.tags && x.tags.length ? [1] : undefined
    };
  }
};

module.exports = {
  original, position, range, ranges, uri, location, locations, definition, documentation, hover, command,
  diagnostic, textEdit, textEdits, workspaceEdit, completionItem, completionList, resolvedCompletion,
  signatureHelp, documentHighlights, symbolInformation, documentSymbols, codeAction, codeLens, foldingRange,
  selectionRange, inlayHint, resolvedInlayHint, semanticTokens, callHierarchyItem, typeHierarchyItem, documentLink,
  tooltip, c2p
};

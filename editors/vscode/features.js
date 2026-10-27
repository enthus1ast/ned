// What VS Code asks the language server: one provider for each feature the server says it has (its capabilities
// in the initialize answer), and only those — a provider for a feature nedls lacks would only send it requests it
// answers with an error.
'use strict';

const vscode = require('vscode');
const fs = require('fs');
const p2c = require('./convert');
const { c2p } = p2c;

// (a capability is on when it is true or an options object)
function on(cap) {
  return cap !== undefined && cap !== null && cap !== false;
}

function opts(cap) {
  return cap && typeof cap === 'object' ? cap : {};
}

function td(doc) {
  return { uri: doc.uri.toString() };
}

function at(doc, pos) {
  return { textDocument: td(doc), position: c2p.position(pos) };
}

// LSP's FormattingOptions: the editor's indentation, and the files.* settings the formatter may follow
function formatting(doc, options) {
  const files = vscode.workspace.getConfiguration('files', doc.uri);
  const o = { tabSize: options.tabSize, insertSpaces: options.insertSpaces };
  if (files.get('trimTrailingWhitespace')) o.trimTrailingWhitespace = true;
  if (files.get('insertFinalNewline')) o.insertFinalNewline = true;
  if (files.get('trimFinalNewlines')) o.trimFinalNewlines = true;
  return o;
}

// A glob of LSP's (**, *, ?, {a,b}, [a-z]) as a regular expression, for the file operation filters.
function globToRegExp(glob, ignoreCase) {
  let re = '';
  let group = 0;
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++;
        if (glob[i + 1] === '/') { i++; re += '(?:.*/)?'; } else re += '.*';
      } else {
        re += '[^/]*';
      }
    } else if (c === '?') {
      re += '[^/]';
    } else if (c === '{') {
      re += '(?:';
      group++;
    } else if (c === '}' && group > 0) {
      re += ')';
      group--;
    } else if (c === ',' && group > 0) {
      re += '|';
    } else if (c === '[' && glob.indexOf(']', i + 1) > i + 1) {
      const j = glob.indexOf(']', i + 1);
      let cls = glob.slice(i + 1, j).replace(/\\/g, '\\\\');
      if (cls[0] === '!') cls = '^' + cls.slice(1);
      re += '[' + cls + ']';
      i = j;
    } else {
      re += c.replace(/[.+^$()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp('^' + re + '$', ignoreCase ? 'i' : '');
}

function matchesFilter(filters, u) {
  for (const f of filters || []) {
    if (f.scheme && f.scheme !== u.scheme) continue;
    const pat = f.pattern || {};
    if (!pat.glob || !globToRegExp(pat.glob, pat.options && pat.options.ignoreCase).test(u.path)) continue;
    if (pat.matches && u.scheme === 'file') {
      try {
        const dir = fs.statSync(u.fsPath).isDirectory();
        if ((pat.matches === 'folder') !== dir) continue;
      } catch (_) {
        continue;
      }
    }
    return true;
  }
  return false;
}

// Registers the providers for the server's capabilities `caps`, for the documents `selector` picks. client.ask
// sends a request and converts its answer (nothing, when it failed or VS Code no longer wants it). What is to be
// disposed when the server stops goes into `subs` as it is made (so a failure halfway leaves nothing behind).
function register(client, caps, selector, subs) {
  const L = vscode.languages;
  const ask = (method, params, token, convert) => client.ask(method, params, token, convert);

  if (on(caps.completionProvider)) {
    const o = opts(caps.completionProvider);
    subs.push(L.registerCompletionItemProvider(selector, {
      provideCompletionItems(doc, pos, token, context) {
        const params = at(doc, pos);
        // (VS Code's trigger kinds count from 0, LSP's from 1)
        params.context = { triggerKind: context.triggerKind + 1 };
        if (context.triggerCharacter !== undefined) params.context.triggerCharacter = context.triggerCharacter;
        return ask('textDocument/completion', params, token, p2c.completionList);
      },
      resolveCompletionItem: o.resolveProvider ? (item, token) => {
        const i = p2c.original(item);
        if (!i) return item;
        return ask('completionItem/resolve', i, token, (r) => p2c.resolvedCompletion(item, r)).then((x) => x || item);
      } : undefined
    }, ...(o.triggerCharacters || [])));
  }

  if (on(caps.hoverProvider)) {
    subs.push(L.registerHoverProvider(selector, {
      provideHover: (doc, pos, token) => ask('textDocument/hover', at(doc, pos), token, p2c.hover)
    }));
  }

  if (on(caps.signatureHelpProvider)) {
    const o = opts(caps.signatureHelpProvider);
    subs.push(L.registerSignatureHelpProvider(selector, {
      provideSignatureHelp(doc, pos, token, context) {
        const params = at(doc, pos);
        params.context = { triggerKind: context.triggerKind, isRetrigger: context.isRetrigger };
        if (context.triggerCharacter !== undefined) params.context.triggerCharacter = context.triggerCharacter;
        if (context.activeSignatureHelp) params.context.activeSignatureHelp = c2p.signatureHelp(context.activeSignatureHelp);
        return ask('textDocument/signatureHelp', params, token, p2c.signatureHelp);
      }
    }, { triggerCharacters: o.triggerCharacters || [], retriggerCharacters: o.retriggerCharacters || [] }));
  }

  if (on(caps.definitionProvider)) {
    subs.push(L.registerDefinitionProvider(selector, {
      provideDefinition: (doc, pos, token) => ask('textDocument/definition', at(doc, pos), token, p2c.definition)
    }));
  }
  if (on(caps.declarationProvider)) {
    subs.push(L.registerDeclarationProvider(selector, {
      provideDeclaration: (doc, pos, token) => ask('textDocument/declaration', at(doc, pos), token, p2c.definition)
    }));
  }
  if (on(caps.typeDefinitionProvider)) {
    subs.push(L.registerTypeDefinitionProvider(selector, {
      provideTypeDefinition: (doc, pos, token) => ask('textDocument/typeDefinition', at(doc, pos), token,
                                                      p2c.definition)
    }));
  }
  if (on(caps.implementationProvider)) {
    subs.push(L.registerImplementationProvider(selector, {
      provideImplementation: (doc, pos, token) => ask('textDocument/implementation', at(doc, pos), token,
                                                      p2c.definition)
    }));
  }

  if (on(caps.referencesProvider)) {
    subs.push(L.registerReferenceProvider(selector, {
      provideReferences(doc, pos, context, token) {
        const params = at(doc, pos);
        params.context = { includeDeclaration: !!context.includeDeclaration };
        return ask('textDocument/references', params, token, p2c.locations);
      }
    }));
  }

  if (on(caps.documentHighlightProvider)) {
    subs.push(L.registerDocumentHighlightProvider(selector, {
      provideDocumentHighlights: (doc, pos, token) => ask('textDocument/documentHighlight', at(doc, pos), token,
                                                          p2c.documentHighlights)
    }));
  }

  if (on(caps.documentSymbolProvider)) {
    subs.push(L.registerDocumentSymbolProvider(selector, {
      provideDocumentSymbols: (doc, token) => ask('textDocument/documentSymbol', { textDocument: td(doc) }, token,
                                                  p2c.documentSymbols)
    }, { label: 'nedls' }));
  }

  if (on(caps.workspaceSymbolProvider)) {
    subs.push(L.registerWorkspaceSymbolProvider({
      provideWorkspaceSymbols: (query, token) => ask('workspace/symbol', { query }, token,
                                                     (r) => r.map(p2c.symbolInformation))
    }));
  }

  if (on(caps.codeActionProvider)) {
    const o = opts(caps.codeActionProvider);
    const kinds = Array.isArray(o.codeActionKinds)
      ? o.codeActionKinds.map((k) => vscode.CodeActionKind.Empty.append(k)) : undefined;
    subs.push(L.registerCodeActionsProvider(selector, {
      provideCodeActions(doc, rng, context, token) {
        const params = { textDocument: td(doc), range: c2p.range(rng),
                         context: { diagnostics: context.diagnostics.map(c2p.diagnostic) } };
        if (context.only) params.context.only = [context.only.value];
        if (context.triggerKind !== undefined) params.context.triggerKind = context.triggerKind;
        return ask('textDocument/codeAction', params, token, (r) => r.map(p2c.codeAction));
      },
      // (an action listed without its edit: the edit worked out when it is picked)
      resolveCodeAction: o.resolveProvider ? (action, token) => {
        const a = p2c.original(action);
        if (!a || a.edit) return action;
        return ask('codeAction/resolve', a, token, (r) => {
          if (r.edit) action.edit = p2c.workspaceEdit(r.edit);
          if (r.command && !action.command) action.command = p2c.command(r.command);
          return action;
        }).then((x) => x || action);
      } : undefined
    }, kinds ? { providedCodeActionKinds: kinds } : undefined));
  }

  if (on(caps.codeLensProvider)) {
    const o = opts(caps.codeLensProvider);
    const changed = new vscode.EventEmitter();
    client.refresh.codeLens = changed;
    subs.push(changed, L.registerCodeLensProvider(selector, {
      onDidChangeCodeLenses: changed.event,
      provideCodeLenses: (doc, token) => ask('textDocument/codeLens', { textDocument: td(doc) }, token,
                                             (r) => r.map(p2c.codeLens)),
      resolveCodeLens: o.resolveProvider ? (lens, token) => {
        const l = p2c.original(lens);
        if (!l || lens.command) return lens;
        return ask('codeLens/resolve', l, token, (r) => {
          if (r.command) lens.command = p2c.command(r.command);
          return lens;
        }).then((x) => x || lens);
      } : undefined
    }));
  }

  // The server's own commands (a code lens's "▶ Run", a rule turned off …): VS Code commands of the same names
  // that send workspace/executeCommand, so code lenses and code actions that name them just work.
  if (on(caps.executeCommandProvider)) {
    for (const name of opts(caps.executeCommandProvider).commands || []) {
      try {
        subs.push(vscode.commands.registerCommand(name, (...args) =>
          ask('workspace/executeCommand', { command: name, arguments: args }, undefined, (r) => r)));
      } catch (e) {
        client.log(`the command ${name} could not be registered: ${e.message || e}`);
      }
    }
  }

  if (on(caps.documentFormattingProvider)) {
    subs.push(L.registerDocumentFormattingEditProvider(selector, {
      provideDocumentFormattingEdits: (doc, options, token) => ask('textDocument/formatting',
        { textDocument: td(doc), options: formatting(doc, options) }, token, p2c.textEdits)
    }));
  }
  if (on(caps.documentRangeFormattingProvider)) {
    subs.push(L.registerDocumentRangeFormattingEditProvider(selector, {
      provideDocumentRangeFormattingEdits: (doc, rng, options, token) => ask('textDocument/rangeFormatting',
        { textDocument: td(doc), range: c2p.range(rng), options: formatting(doc, options) }, token, p2c.textEdits)
    }));
  }
  if (on(caps.documentOnTypeFormattingProvider)) {
    const o = opts(caps.documentOnTypeFormattingProvider);
    if (o.firstTriggerCharacter) {
      subs.push(L.registerOnTypeFormattingEditProvider(selector, {
        provideOnTypeFormattingEdits: (doc, pos, ch, options, token) => ask('textDocument/onTypeFormatting',
          { textDocument: td(doc), position: c2p.position(pos), ch, options: formatting(doc, options) }, token,
          p2c.textEdits)
      }, o.firstTriggerCharacter, ...(o.moreTriggerCharacter || [])));
    }
  }

  if (on(caps.renameProvider)) {
    const o = opts(caps.renameProvider);
    // (VS Code shows a rename's error to the person — "cannot rename to a keyword" — so these two throw it)
    subs.push(L.registerRenameProvider(selector, {
      provideRenameEdits: (doc, pos, newName, token) => client.askOrThrow('textDocument/rename',
        Object.assign(at(doc, pos), { newName }), token, p2c.workspaceEdit),
      prepareRename: o.prepareProvider ? (doc, pos, token) => client.askOrThrow('textDocument/prepareRename',
        at(doc, pos), token, (r) => {
          if (r.defaultBehavior) return undefined;            // (VS Code's own: the word there)
          if (r.range) return { range: p2c.range(r.range), placeholder: r.placeholder };
          return p2c.range(r);
        }, 'There is nothing to rename here.') : undefined
    }));
  }

  if (on(caps.foldingRangeProvider)) {
    subs.push(L.registerFoldingRangeProvider(selector, {
      provideFoldingRanges: (doc, context, token) => ask('textDocument/foldingRange', { textDocument: td(doc) },
                                                         token, (r) => r.map(p2c.foldingRange))
    }));
  }

  if (on(caps.selectionRangeProvider)) {
    subs.push(L.registerSelectionRangeProvider(selector, {
      provideSelectionRanges: (doc, positions, token) => ask('textDocument/selectionRange',
        { textDocument: td(doc), positions: positions.map(c2p.position) }, token, (r) => r.map(p2c.selectionRange))
    }));
  }

  if (on(caps.inlayHintProvider)) {
    const o = opts(caps.inlayHintProvider);
    const changed = new vscode.EventEmitter();
    client.refresh.inlayHints = changed;
    subs.push(changed, L.registerInlayHintsProvider(selector, {
      onDidChangeInlayHints: changed.event,
      provideInlayHints: (doc, rng, token) => ask('textDocument/inlayHint',
        { textDocument: td(doc), range: c2p.range(rng) }, token, (r) => r.map(p2c.inlayHint)),
      resolveInlayHint: o.resolveProvider ? (hint, token) => {
        const h = p2c.original(hint);
        if (!h) return hint;
        return ask('inlayHint/resolve', h, token, (r) => p2c.resolvedInlayHint(hint, r)).then((x) => x || hint);
      } : undefined
    }));
  }

  if (on(caps.semanticTokensProvider)) {
    const o = opts(caps.semanticTokensProvider);
    const lg = o.legend || {};
    const legend = new vscode.SemanticTokensLegend(lg.tokenTypes || [], lg.tokenModifiers || []);
    if (o.full) {
      const changed = new vscode.EventEmitter();
      client.refresh.semanticTokens = changed;
      // (with deltas: after an edit only what changed comes back, as edits of the tokens VS Code has)
      const delta = typeof o.full === 'object' && !!o.full.delta;
      subs.push(changed, L.registerDocumentSemanticTokensProvider(selector, {
        onDidChangeSemanticTokens: changed.event,
        provideDocumentSemanticTokens: (doc, token) => ask('textDocument/semanticTokens/full',
          { textDocument: td(doc) }, token, p2c.semanticTokens),
        provideDocumentSemanticTokensEdits: delta ? (doc, previousResultId, token) => ask(
          'textDocument/semanticTokens/full/delta', { textDocument: td(doc), previousResultId }, token,
          p2c.semanticTokensOrEdits) : undefined
      }, legend));
    }
    if (o.range) {
      subs.push(L.registerDocumentRangeSemanticTokensProvider(selector, {
        provideDocumentRangeSemanticTokens: (doc, rng, token) => ask('textDocument/semanticTokens/range',
          { textDocument: td(doc), range: c2p.range(rng) }, token, p2c.semanticTokens)
      }, legend));
    }
  }

  if (on(caps.callHierarchyProvider)) {
    subs.push(L.registerCallHierarchyProvider(selector, {
      prepareCallHierarchy: (doc, pos, token) => ask('textDocument/prepareCallHierarchy', at(doc, pos), token,
                                                     (r) => r.map(p2c.callHierarchyItem)),
      provideCallHierarchyIncomingCalls: (item, token) => ask('callHierarchy/incomingCalls',
        { item: c2p.hierarchyItem(item) }, token, (r) => r.map((c) => new vscode.CallHierarchyIncomingCall(
          p2c.callHierarchyItem(c.from), p2c.ranges(c.fromRanges)))),
      provideCallHierarchyOutgoingCalls: (item, token) => ask('callHierarchy/outgoingCalls',
        { item: c2p.hierarchyItem(item) }, token, (r) => r.map((c) => new vscode.CallHierarchyOutgoingCall(
          p2c.callHierarchyItem(c.to), p2c.ranges(c.fromRanges))))
    }));
  }

  // (the type hierarchy came in VS Code 1.75: an older one goes without it)
  if (on(caps.typeHierarchyProvider) && vscode.languages.registerTypeHierarchyProvider) {
    subs.push(L.registerTypeHierarchyProvider(selector, {
      prepareTypeHierarchy: (doc, pos, token) => ask('textDocument/prepareTypeHierarchy', at(doc, pos), token,
                                                     (r) => r.map(p2c.typeHierarchyItem)),
      provideTypeHierarchySupertypes: (item, token) => ask('typeHierarchy/supertypes',
        { item: c2p.hierarchyItem(item) }, token, (r) => r.map(p2c.typeHierarchyItem)),
      provideTypeHierarchySubtypes: (item, token) => ask('typeHierarchy/subtypes',
        { item: c2p.hierarchyItem(item) }, token, (r) => r.map(p2c.typeHierarchyItem))
    }));
  }

  if (on(caps.documentLinkProvider)) {
    const o = opts(caps.documentLinkProvider);
    subs.push(L.registerDocumentLinkProvider(selector, {
      provideDocumentLinks: (doc, token) => ask('textDocument/documentLink', { textDocument: td(doc) }, token,
                                                (r) => r.map(p2c.documentLink)),
      resolveDocumentLink: o.resolveProvider ? (link, token) => {
        const l = p2c.original(link);
        if (!l) return link;
        return ask('documentLink/resolve', l, token, (r) => {
          if (r.target) link.target = p2c.uri(r.target);
          if (r.tooltip) link.tooltip = r.tooltip;
          return link;
        }).then((x) => x || link);
      } : undefined
    }));
  }

  // HTML's tags renamed together (nedls answers it for HTML; for Nim there are none)
  if (on(caps.linkedEditingRangeProvider) && L.registerLinkedEditingRangeProvider) {
    subs.push(L.registerLinkedEditingRangeProvider(selector, {
      provideLinkedEditingRanges: (doc, pos, token) => ask('textDocument/linkedEditingRange', at(doc, pos), token,
        (r) => {
          let word;
          try { word = r.wordPattern ? new RegExp(r.wordPattern) : undefined; } catch (_) { word = undefined; }
          return new vscode.LinkedEditingRanges(p2c.ranges(r.ranges), word);
        })
    }));
  }

  // A module renamed or moved in the Explorer: the imports that name it follow (the edit nedls works out is made
  // with the rename, before it happens).
  const ops = caps.workspace && caps.workspace.fileOperations;
  if (ops && on(ops.willRename) && vscode.workspace.onWillRenameFiles) {
    const filters = opts(ops.willRename).filters;
    subs.push(vscode.workspace.onWillRenameFiles((e) => {
      const files = e.files.filter((f) => matchesFilter(filters, f.oldUri))
        .map((f) => ({ oldUri: f.oldUri.toString(), newUri: f.newUri.toString() }));
      if (files.length === 0) return;
      e.waitUntil(ask('workspace/willRenameFiles', { files }, e.token, p2c.workspaceEdit)
        .then((x) => x || new vscode.WorkspaceEdit()));
    }));
  }

  return subs;
}

// What the client can do, said honestly in initialize: what register() and client.js implement, nothing more.
function clientCapabilities() {
  const symbolKinds = { valueSet: Array.from({ length: 26 }, (_, i) => i + 1) };
  const caps = {
    general: { positionEncodings: ['utf-16'] },
    workspace: {
      applyEdit: true,
      workspaceEdit: { documentChanges: true, resourceOperations: ['create', 'rename', 'delete'],
                       failureHandling: 'textOnlyTransactional', normalizesLineEndings: true },
      didChangeConfiguration: { dynamicRegistration: false },
      didChangeWatchedFiles: { dynamicRegistration: false },
      symbol: { dynamicRegistration: false, symbolKind: symbolKinds, tagSupport: { valueSet: [1] } },
      executeCommand: { dynamicRegistration: false },
      configuration: true,
      workspaceFolders: true,
      semanticTokens: { refreshSupport: true },
      inlayHint: { refreshSupport: true },
      codeLens: { refreshSupport: true },
      diagnostics: { refreshSupport: true },
      fileOperations: { dynamicRegistration: false, willRename: true }
    },
    textDocument: {
      synchronization: { dynamicRegistration: false, willSave: false, willSaveWaitUntil: false, didSave: true },
      completion: {
        dynamicRegistration: false,
        contextSupport: true,
        completionItem: {
          snippetSupport: true,
          commitCharactersSupport: true,
          documentationFormat: ['markdown', 'plaintext'],
          deprecatedSupport: true,
          preselectSupport: true,
          tagSupport: { valueSet: [1] },
          insertReplaceSupport: true,
          resolveSupport: { properties: ['documentation', 'detail', 'additionalTextEdits'] },
          insertTextModeSupport: { valueSet: [1, 2] },
          labelDetailsSupport: true
        },
        completionItemKind: { valueSet: Array.from({ length: 25 }, (_, i) => i + 1) },
        completionList: { itemDefaults: ['commitCharacters', 'editRange', 'insertTextFormat', 'insertTextMode', 'data'] }
      },
      hover: { dynamicRegistration: false, contentFormat: ['markdown', 'plaintext'] },
      signatureHelp: {
        dynamicRegistration: false,
        contextSupport: true,
        signatureInformation: { documentationFormat: ['markdown', 'plaintext'],
                                parameterInformation: { labelOffsetSupport: true }, activeParameterSupport: true }
      },
      declaration: { dynamicRegistration: false, linkSupport: true },
      definition: { dynamicRegistration: false, linkSupport: true },
      typeDefinition: { dynamicRegistration: false, linkSupport: true },
      implementation: { dynamicRegistration: false, linkSupport: true },
      references: { dynamicRegistration: false },
      documentHighlight: { dynamicRegistration: false },
      documentSymbol: { dynamicRegistration: false, symbolKind: symbolKinds, hierarchicalDocumentSymbolSupport: true,
                        tagSupport: { valueSet: [1] } },
      codeAction: {
        dynamicRegistration: false,
        codeActionLiteralSupport: { codeActionKind: { valueSet: ['', 'quickfix', 'refactor', 'refactor.extract',
          'refactor.inline', 'refactor.rewrite', 'source', 'source.organizeImports', 'source.fixAll'] } },
        isPreferredSupport: true,
        disabledSupport: true,
        dataSupport: true,
        resolveSupport: { properties: ['edit'] }
      },
      codeLens: { dynamicRegistration: false },
      documentLink: { dynamicRegistration: false, tooltipSupport: true },
      formatting: { dynamicRegistration: false },
      rangeFormatting: { dynamicRegistration: false },
      onTypeFormatting: { dynamicRegistration: false },
      rename: { dynamicRegistration: false, prepareSupport: true, prepareSupportDefaultBehavior: 1 },
      publishDiagnostics: { relatedInformation: true, tagSupport: { valueSet: [1, 2] }, versionSupport: false,
                            codeDescriptionSupport: true, dataSupport: true },
      // (problems asked for: client.js's startPulling)
      diagnostic: { dynamicRegistration: false, relatedDocumentSupport: false },
      // (VS Code folds whole lines)
      foldingRange: { dynamicRegistration: false, rangeLimit: 5000, lineFoldingOnly: true,
                      foldingRangeKind: { valueSet: ['comment', 'imports', 'region'] } },
      selectionRange: { dynamicRegistration: false },
      callHierarchy: { dynamicRegistration: false },
      semanticTokens: {
        dynamicRegistration: false,
        requests: { range: true, full: { delta: true } },
        tokenTypes: ['namespace', 'type', 'class', 'enum', 'interface', 'struct', 'typeParameter', 'parameter',
                     'variable', 'property', 'enumMember', 'event', 'function', 'method', 'macro', 'keyword',
                     'modifier', 'comment', 'string', 'number', 'regexp', 'operator', 'decorator'],
        tokenModifiers: ['declaration', 'definition', 'readonly', 'static', 'deprecated', 'abstract', 'async',
                         'modification', 'documentation', 'defaultLibrary'],
        formats: ['relative'],
        overlappingTokenSupport: false,
        multilineTokenSupport: false,
        serverCancelSupport: false,          // (a request the server gives up is not asked again)
        augmentsSyntaxTokens: true
      },
      inlayHint: { dynamicRegistration: false,
                   resolveSupport: { properties: ['tooltip', 'textEdits', 'label.tooltip', 'label.location',
                                                  'label.command'] } }
    },
    window: {
      workDoneProgress: true,
      showMessage: { messageActionItem: { additionalPropertiesSupport: true } }
    }
  };
  if (vscode.languages.registerTypeHierarchyProvider) caps.textDocument.typeHierarchy = { dynamicRegistration: false };
  if (vscode.languages.registerLinkedEditingRangeProvider) {
    caps.textDocument.linkedEditingRange = { dynamicRegistration: false };
  }
  return caps;
}

module.exports = { register, clientCapabilities, globToRegExp };

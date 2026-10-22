## wordinfo-lsp — a language server written in NimScript, for text files.
##
## The plugin only says which files it serves; the server is server.nims (import nedlsp), which ned runs through
## `ned --lsp-bridge server.nims` — the same command makes it a language server for any editor (Helix, Neovim …).
import nedplugin

languageServerScript("plaintext", "server.nims")

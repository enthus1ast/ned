## md-links — a language server written in NimScript, for Markdown: this file says which files it serves; the
## server is server.nims beside it
import nedplugin

requiresNed(">= 6.31")

languageServerScript("markdown", "server.nims")

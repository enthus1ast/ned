## nedls — ned's built-in Nim engine as a language server (LSP over stdio), for any editor: VS Code, Neovim,
## Helix, Zed, Emacs, Kate, Sublime … instead of nimlangserver or nimsuggest. The answers are ned's own: the
## same code the editor runs (its Nim index, its formatter, its quick fixes, its checks), without its screen.
##
##   Build: nim c -d:release -o:nedls src/nedls.nim
##   Run  : nedls            (the editor starts it; it talks over stdin/stdout — nedls --help)

include "ned.nim"                  # the whole editor, without its main (nedls.nims: -d:nedNoMain)
include "ned/nedls/rpc.nim"
include "ned/nedls/docs.nim"
include "ned/nedls/features.nim"
include "ned/nedls/diags.nim"
include "ned/nedls/server.nim"

when isMainModule:
  quit nedlsMain()

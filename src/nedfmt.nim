## nedfmt — ned's formatters as a command of their own: Nim in nph's style (checked: a file it is not sure of is
## left alone), JSON, Markdown tables, CSS/SCSS, C, YAML, TOML, HTML and SQL. nph's options (--check, --diff, --out, --outDir,
## `-` for stdin, --exclude/--include), your nim.format.* settings, and a git pre-commit hook (--install-hook).
##
##   Build: nim c -d:release -o:nedfmt src/nedfmt.nim      (or: nimble nedfmt)
##   Use  : nedfmt src/  ·  nedfmt --check .  ·  nedfmt --diff x.nim  ·  cat x.nim | nedfmt -  ·  nedfmt --install-hook

when defined(windows): import ned/sys/winos as os
else: import std/os
import ned/version, ned/format/fmtcli

when isMainModule:
  quit fmtCliMain(commandLineParams(), "nedfmt", NedVersion)

## ned on Windows: std/os with '/' in the paths it gives back. ned's code joins, compares and shows paths with '/'
## (Windows takes it as well as '\'); std/os writes '\' when it joins or makes a path absolute — so the procs that
## make paths are these here, the same with '/'. Imported in place of std/os on Windows (ned.nim and the modules
## that work with paths); everything else is std/os's own.

when not defined(windows):
  {.error: "ned/sys/winos is the Windows side of std/os".}

import std/os except `/`, joinPath, getCurrentDir, absolutePath, expandFilename, getHomeDir, getTempDir,
  getAppFilename, getAppDir, getConfigDir, getCacheDir, walkDir, walkDirRec, walkFiles, walkDirs, walkPattern,
  relativePath, normalizedPath, normalizePath, findExe, DirSep, expandTilde, unixToNativePath,
  `/../`, parentDir, tailDir, splitPath, getCurrentCompilerExe
from std/os as stdos import nil
from std/strutils import replace
export stdos except `/`, joinPath, getCurrentDir, absolutePath, expandFilename, getHomeDir, getTempDir,
  getAppFilename, getAppDir, getConfigDir, getCacheDir, walkDir, walkDirRec, walkFiles, walkDirs, walkPattern,
  relativePath, normalizedPath, normalizePath, findExe, DirSep, expandTilde, unixToNativePath,
  `/../`, parentDir, tailDir, splitPath, getCurrentCompilerExe

const DirSep* = '/'

func slashes*(p: string): string {.inline.} = p.replace('\\', '/')

func joinPath*(head, tail: string): string = stdos.joinPath(head, tail).slashes
func joinPath*(parts: varargs[string]): string = stdos.joinPath(parts).slashes
func `/`*(head, tail: string): string = stdos.joinPath(head, tail).slashes
func `/../`*(head, tail: string): string = stdos.`/../`(head, tail).slashes
func parentDir*(path: string): string = stdos.parentDir(path).slashes
func tailDir*(path: string): string = stdos.tailDir(path).slashes
func splitPath*(path: string): tuple[head, tail: string] =
  let (h, t) = stdos.splitPath(path)
  (h.slashes, t)

proc getCurrentDir*(): string = stdos.getCurrentDir().slashes
proc absolutePath*(path: string, root = getCurrentDir()): string = stdos.absolutePath(path, root).slashes
proc expandFilename*(filename: string): string = stdos.expandFilename(filename).slashes
proc getHomeDir*(): string = stdos.getHomeDir().slashes
proc getTempDir*(): string = stdos.getTempDir().slashes
proc getAppFilename*(): string = stdos.getAppFilename().slashes
proc getAppDir*(): string = stdos.getAppDir().slashes
proc getConfigDir*(): string = stdos.getConfigDir().slashes
proc getCacheDir*(): string = stdos.getCacheDir().slashes
proc getCacheDir*(app: string): string = stdos.getCacheDir(app).slashes
proc getCurrentCompilerExe*(): string = stdos.getCurrentCompilerExe().slashes
proc expandTilde*(path: string): string = stdos.expandTilde(path).slashes
proc unixToNativePath*(path: string, drive = ""): string = path
proc relativePath*(path, base: string, sep = '/'): string = stdos.relativePath(path, base, sep).slashes
func normalizedPath*(path: string): string = stdos.normalizedPath(path).slashes
func normalizePath*(path: var string) =
  stdos.normalizePath(path)
  path = path.slashes
proc findExe*(exe: string, followSymlinks = true, extensions = ExeExts): string =
  stdos.findExe(exe, followSymlinks, extensions).slashes

iterator walkDir*(dir: string, relative = false, checkDir = false, skipSpecial = false):
                  tuple[kind: PathComponent, path: string] =
  for k, p in stdos.walkDir(dir, relative, checkDir, skipSpecial): yield (k, p.slashes)
iterator walkDirRec*(dir: string, yieldFilter = {pcFile}, followFilter = {pcDir}, relative = false,
                     checkDir = false, skipSpecial = false): string =
  for p in stdos.walkDirRec(dir, yieldFilter, followFilter, relative, checkDir, skipSpecial): yield p.slashes
iterator walkFiles*(pattern: string): string =
  for p in stdos.walkFiles(pattern): yield p.slashes
iterator walkDirs*(pattern: string): string =
  for p in stdos.walkDirs(pattern): yield p.slashes
iterator walkPattern*(pattern: string): string =
  for p in stdos.walkPattern(pattern): yield p.slashes

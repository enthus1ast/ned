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

# the path with every '\' turned into '/': what each proc below does to the result of its std/os original
func slashes*(p: string): string {.inline.} = p.replace('\\', '/')

# std/os's joinPath with '/' in the result, not '\'
func joinPath*(head, tail: string): string = stdos.joinPath(head, tail).slashes
# std/os's joinPath of several parts with '/' in the result, not '\'
func joinPath*(parts: varargs[string]): string = stdos.joinPath(parts).slashes
# std/os's `/` (joinPath) with '/' in the result, not '\'
func `/`*(head, tail: string): string = stdos.joinPath(head, tail).slashes
# std/os's `/../` (the head's parent folder joined with the tail, or the head itself when it has no parent) with '/' in
# the result, not '\'
func `/../`*(head, tail: string): string = stdos.`/../`(head, tail).slashes
# std/os's parentDir with '/' in the result, not '\'
func parentDir*(path: string): string = stdos.parentDir(path).slashes
# std/os's tailDir (the path without its first folder) with '/' in the result, not '\'
func tailDir*(path: string): string = stdos.tailDir(path).slashes
func splitPath*(path: string): tuple[head, tail: string] =
  ## std/os's splitPath with '/' in the head (the tail has no separator)
  let (h, t) = stdos.splitPath(path)
  (h.slashes, t)

# std/os's getCurrentDir with '/' in the result, not '\'
proc getCurrentDir*(): string = stdos.getCurrentDir().slashes
# std/os's absolutePath with '/' in the result, not '\'
proc absolutePath*(path: string, root = getCurrentDir()): string = stdos.absolutePath(path, root).slashes
# std/os's expandFilename with '/' in the result, not '\'
proc expandFilename*(filename: string): string = stdos.expandFilename(filename).slashes
# std/os's getHomeDir with '/' in the result, not '\'
proc getHomeDir*(): string = stdos.getHomeDir().slashes
# std/os's getTempDir with '/' in the result, not '\'
proc getTempDir*(): string = stdos.getTempDir().slashes
# std/os's getAppFilename with '/' in the result, not '\'
proc getAppFilename*(): string = stdos.getAppFilename().slashes
# std/os's getAppDir with '/' in the result, not '\'
proc getAppDir*(): string = stdos.getAppDir().slashes
# std/os's getConfigDir with '/' in the result, not '\'
proc getConfigDir*(): string = stdos.getConfigDir().slashes
# std/os's getCacheDir with '/' in the result, not '\'
proc getCacheDir*(): string = stdos.getCacheDir().slashes
# std/os's getCacheDir for an application's name with '/' in the result, not '\'
proc getCacheDir*(app: string): string = stdos.getCacheDir(app).slashes
# std/os's getCurrentCompilerExe with '/' in the result, not '\'
proc getCurrentCompilerExe*(): string = stdos.getCurrentCompilerExe().slashes
# std/os's expandTilde with '/' in the result, not '\'
proc expandTilde*(path: string): string = stdos.expandTilde(path).slashes
# the path as it is: ned's paths already use '/', which Windows takes, so there is nothing to convert
proc unixToNativePath*(path: string, drive = ""): string = path
# std/os's relativePath with '/' in the result, not '\'
proc relativePath*(path, base: string, sep = '/'): string = stdos.relativePath(path, base, sep).slashes
# std/os's normalizedPath with '/' in the result, not '\'
func normalizedPath*(path: string): string = stdos.normalizedPath(path).slashes
func normalizePath*(path: var string) =
  ## std/os's normalizePath, changing the path in place, with '/' in the result
  stdos.normalizePath(path)
  path = path.slashes
proc findExe*(exe: string, followSymlinks = true, extensions = ExeExts): string =
  ## std/os's findExe with '/' in the result, not '\'
  stdos.findExe(exe, followSymlinks, extensions).slashes

iterator walkDir*(dir: string, relative = false, checkDir = false, skipSpecial = false):
                  tuple[kind: PathComponent, path: string] =
  ## std/os's walkDir with '/' in each path it yields
  for k, p in stdos.walkDir(dir, relative, checkDir, skipSpecial): yield (k, p.slashes)
iterator walkDirRec*(dir: string, yieldFilter = {pcFile}, followFilter = {pcDir}, relative = false,
                     checkDir = false, skipSpecial = false): string =
  ## std/os's walkDirRec with '/' in each path it yields
  for p in stdos.walkDirRec(dir, yieldFilter, followFilter, relative, checkDir, skipSpecial): yield p.slashes
iterator walkFiles*(pattern: string): string =
  ## std/os's walkFiles with '/' in each path it yields
  for p in stdos.walkFiles(pattern): yield p.slashes
iterator walkDirs*(pattern: string): string =
  ## std/os's walkDirs with '/' in each path it yields
  for p in stdos.walkDirs(pattern): yield p.slashes
iterator walkPattern*(pattern: string): string =
  ## std/os's walkPattern with '/' in each path it yields
  for p in stdos.walkPattern(pattern): yield p.slashes

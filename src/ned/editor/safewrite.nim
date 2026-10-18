# ════════════════════════════════════════════════════════════════════════════
#  Buffer management
# ════════════════════════════════════════════════════════════════════════════

# ── safe writes, crash recovery (swap files), local history, line diffs ─────────

proc stateDir(): string = parentDir(stateFile())

func fnv(s: string): string =
  ## short stable file key for a path
  var h = 0xcbf29ce484222325'u64
  for c in s:
    h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  toHex(h, 16).toLowerAscii

proc cRename(a, b: cstring): cint {.importc: "rename", header: "<stdio.h>".}
var O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint

proc privateDir(d: string) =
  ## state folders hold copies of your files (recovery, history, chats): only you may read them
  createDir(d)
  try: setFilePermissions(d, {fpUserRead, fpUserWrite, fpUserExec})
  except CatchableError: discard

var lastInternalErr: (string, MonoTime)

proc internalError(where: string, e: ref Exception) =
  ## a bug must never take your work down: log it, say so once, keep editing
  let m = where & ": " & $e.name & ": " & e.msg
  if m == lastInternalErr[0] and msSince(lastInternalErr[1]) < 5000: return    # the same fault, again and again
  lastInternalErr = (m, getMonoTime())
  try:
    privateDir(stateDir())
    let log = stateDir() / "errors.log"
    if fileExists(log) and getFileSize(log) > 512 * 1024: moveFile(log, log & ".old")
    let f = open(log, fmAppend)
    f.writeLine(times.now().format("yyyy-MM-dd HH:mm:ss") & " ned " & Version & " " & m)
    let st = e.getStackTrace()
    if st.len > 0: f.write(st)
    f.close()
  except CatchableError: discard
  error("Internal error — " & truncTo(m, 120) & " (details in " & stateDir() / "errors.log" & ")")

var fileWrittenHook: proc(path: string) {.closure.} = nil   # set by remote folders: their files go to the server

proc fileWritten(path: string) =
  ## ned wrote a file of the project itself (not through the editor's save): a remote folder's goes to the server
  nxStatForget(path)                     # (the engine reads it again as it is now)
  if fileWrittenHook != nil: fileWrittenHook(path)

proc writeFileSafe0(path, content: string, newMode = 0o644) =
  ## crash-safe replace: temp file in the same folder, fsync, rename over the original.
  ## A phone that dies mid-save keeps either the old or the new file, never half of one.
  var target = path
  if symlinkExists(path):
    # write through the link (also a dangling one) instead of replacing it
    try:
      let t = expandSymlink(path)
      target = if t.isAbsolute: t else: parentDir(path) / t
    except CatchableError: discard
  var st: Stat
  let exists = stat(target.cstring, st) == 0
  if exists and st.st_nlink > 1:
    writeFile(target, content)            # hard links must keep sharing the inode
    return
  let mode = if exists: Mode(st.st_mode and 0o7777) else: Mode(newMode)
  let tmp = parentDir(target) / ("." & extractFilename(target) & ".ned~" & $getCurrentProcessId())
  var fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC, mode)
  if fd < 0 and errno == EEXIST:
    discard posix.unlink(tmp.cstring)     # left behind by a crash during an earlier save
    fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL or O_NOFOLLOW or O_CLOEXEC, mode)
  if fd < 0:
    if errno in [EACCES, EROFS, EPERM]:
      writeFile(target, content)          # folder not writable but the file is: write in place
      return
    raise newException(IOError, "cannot write " & tmp & ": " & $strerror(errno))
  discard fchmod(fd, mode)                # exact mode, whatever the umask says
  var off = 0
  while off < content.len:
    let n = posix.write(fd, unsafeAddr content[off], content.len - off)
    if n < 0:
      if errno == EINTR: continue
      let e = $strerror(errno)
      discard posix.close(fd)
      discard posix.unlink(tmp.cstring)
      raise newException(IOError, "write failed (" & e & ") — the original file is untouched")
    off += n
  if fsync(fd) != 0 and errno notin [EINVAL, EROFS]:
    let e = $strerror(errno)
    discard posix.close(fd)
    discard posix.unlink(tmp.cstring)
    raise newException(IOError, "fsync failed (" & e & ") — the original file is untouched")
  discard posix.close(fd)
  if exists: discard posix.chown(tmp.cstring, st.st_uid, st.st_gid)
  if cRename(tmp.cstring, target.cstring) != 0:
    let e = $strerror(errno)
    discard posix.unlink(tmp.cstring)
    raise newException(IOError, "rename failed: " & e)

proc writeFileSafe(path, content: string, newMode = 0o644) =
  writeFileSafe0(path, content, newMode)
  fileWritten(path)

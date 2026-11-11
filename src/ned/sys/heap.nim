## The heap: how much of the memory ned's allocator holds its objects take, and giving back to the system what it holds
## but no longer uses. On Linux and macOS ned is built on the system's allocator (`-d:useMalloc`, set in src/ned.nims):
## Nim's own never gives memory back once it has it — after a big file, or a long session, ned held three times what it
## used. On Android and Windows, and with `-d:nedNimAlloc`, it is on Nim's (nothing is given back; the sizes are Nim's).
##
## The C library's own calls are looked up when ned runs, not linked: glibc has malloc_trim and mallinfo2 (mallinfo
## before 2.33), Android's bionic mallopt(M_PURGE) and a mallinfo of size_t fields, macOS
## malloc_zone_pressure_relief; musl has none of them (its allocator gives memory back by itself, and the sizes are
## not known: -1).

when defined(useMalloc) and not defined(windows):
  import std/dynlib

  type
    MallinfoInt = object      # glibc's struct mallinfo
      arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost: cint
    MallinfoSize = object     # glibc's struct mallinfo2, bionic's struct mallinfo
      arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost: csize_t
    TrimFn = proc (pad: csize_t): cint {.cdecl, gcsafe, raises: [].}
    InfoIntFn = proc (): MallinfoInt {.cdecl, gcsafe, raises: [].}
    InfoSizeFn = proc (): MallinfoSize {.cdecl, gcsafe, raises: [].}
    MalloptFn = proc (param, value: cint): cint {.cdecl, gcsafe, raises: [].}
    ReliefFn = proc (zone: pointer, goal: csize_t): csize_t {.cdecl, gcsafe, raises: [].}

  var
    looked = false
    trimFn: TrimFn
    infoSizeFn: InfoSizeFn
    infoIntFn: InfoIntFn
    malloptFn: MalloptFn
    reliefFn: ReliefFn

  proc lookUp() =
    ## the C library's calls found, once (in the program and what it is linked with)
    if looked: return
    looked = true
    let lib = loadLib()
    if lib == nil: return              # (a static program: musl — nothing to find)
    trimFn = cast[TrimFn](lib.symAddr("malloc_trim"))
    when defined(android):
      infoSizeFn = cast[InfoSizeFn](lib.symAddr("mallinfo"))
      malloptFn = cast[MalloptFn](lib.symAddr("mallopt"))
    elif defined(macosx):
      reliefFn = cast[ReliefFn](lib.symAddr("malloc_zone_pressure_relief"))
    else:
      infoSizeFn = cast[InfoSizeFn](lib.symAddr("mallinfo2"))
      if infoSizeFn == nil: infoIntFn = cast[InfoIntFn](lib.symAddr("mallinfo"))

  proc heapInUse*(): int =
    ## bytes ned's objects take now on the heap (-1: not known here)
    lookUp()
    if infoSizeFn != nil:
      let m = infoSizeFn()
      return int(m.uordblks + m.hblkhd)
    if infoIntFn != nil:
      let m = infoIntFn()
      return int(cast[cuint](m.uordblks)) + int(cast[cuint](m.hblkhd))
    -1

  proc heapHeld*(): int =
    ## bytes the allocator holds from the system now (-1: not known here)
    lookUp()
    if infoSizeFn != nil:
      let m = infoSizeFn()
      return int(m.arena + m.hblkhd)
    if infoIntFn != nil:
      let m = infoIntFn()
      return int(cast[cuint](m.arena)) + int(cast[cuint](m.hblkhd))
    -1

  proc heapGiveBack*(): bool =
    ## gives back to the system the memory the allocator holds and no longer uses; false when there is no way here
    lookUp()
    if trimFn != nil:
      discard trimFn(0)
      return true
    when defined(android):
      if malloptFn != nil:
        discard malloptFn(-101, 0)     # (M_PURGE: Android 9 and newer; older ones answer 0 and do nothing)
        return true
    if reliefFn != nil:
      discard reliefFn(nil, 0)
      return true
    false

elif defined(useMalloc) and defined(windows):
  proc heapmin(): cint {.importc: "_heapmin", header: "<malloc.h>".}

  proc heapInUse*(): int =
    ## bytes ned's objects take now on the heap (-1: Windows does not say it cheaply)
    -1

  proc heapHeld*(): int =
    ## bytes the allocator holds from the system now (-1: not known)
    -1

  proc heapGiveBack*(): bool =
    ## gives back to the system the memory the C runtime's heap holds and no longer uses
    discard heapmin()
    true

else:
  proc heapInUse*(): int =
    ## bytes ned's objects take now on Nim's heap
    getOccupiedMem()

  proc heapHeld*(): int =
    ## bytes Nim's allocator holds from the system
    getTotalMem()

  proc heapGiveBack*(): bool =
    ## Nim's allocator keeps what it has: nothing to do
    false

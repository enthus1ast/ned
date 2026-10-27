# Nim tour · 13 of 16 · Async
# notebook: compiled
#
# A program that waits — for the network, a file, a timer — can do other work while it waits. `async` procs
# (std/asyncdispatch) are written like ordinary ones, with `await` where they wait; one thread runs them all, each
# going on when what it waits for is ready. A Future is the promise of a value that is not there yet.

# %% A first async proc
# `{.async.}` makes a proc async: calling it gives a Future at once. `await` waits for one inside an async proc;
# `waitFor` waits for one from ordinary code, running the event loop until it is done.
import std/asyncdispatch
proc greetLater(name: string) {.async.} =
  await sleepAsync(10)                 # wait 10 ms without blocking anything else
  echo "hello, ", name
waitFor greetLater("Ada")
#> hello, Ada

# %% Two at once
# Started together, two async procs wait at the same time: the short wait finishes first, though it started second.
# `all` gives a Future that is done when every one of them is.
proc task(name: string, ms: int) {.async.} =
  echo name, " starts"
  await sleepAsync(ms)
  echo name, " is done after ", ms, " ms"
waitFor all(task("slow", 120), task("quick", 20))
#> slow starts
#> quick starts
#> quick is done after 20 ms
#> slow is done after 120 ms

# %% Values from the future
# An async proc gives back `Future[T]`; `await` gives the T.
proc fetchPrice(item: string): Future[int] {.async.} =
  await sleepAsync(5)
  return item.len * 10
proc basket(): Future[int] {.async.} =
  let a = await fetchPrice("apple")
  let b = await fetchPrice("fig")
  return a + b
echo waitFor basket()
#> 80

# %% Errors cross the await
# An exception raised in an async proc is raised again where it is awaited, so `try` works as usual. (While you
# develop, its message also says where it went through: the first line is the message it was raised with.)
import std/strutils
proc mayFail(fail: bool): Future[string] {.async.} =
  await sleepAsync(5)
  if fail: raise newException(IOError, "the server did not answer")
  return "the page"
proc load() {.async.} =
  for fail in [false, true]:
    try:
      echo "got ", await mayFail(fail)
    except IOError as e:
      echo "failed: ", e.msg.splitLines[0]
waitFor load()
#> got the page
#> failed: the server did not answer

# %% Running in the background
# `asyncCheck` starts a Future and lets it run on its own (an error in it stops the program). The work happens only
# while the event loop runs: `poll`, `waitFor` or `runForever` run it.
var ticks = 0
proc ticker() {.async.} =
  for _ in 1 .. 3:
    await sleepAsync(10)
    inc ticks
asyncCheck ticker()
echo "ticks so far: ", ticks
waitFor sleepAsync(100)
echo "ticks after 100 ms: ", ticks
#> ticks so far: 0
#> ticks after 100 ms: 3

# %% A web server
# std/asynchttpserver answers web requests with the same `await`. This cell only defines the server — it would run
# for ever, and a notebook cell should end. In a program of your own, `waitFor serve(8080)` starts it: then open
# http://localhost:8080 in a browser. (std/httpclient's AsyncHttpClient fetches pages the same way. Work that keeps
# the processor busy, rather than waiting, is better in threads: std/typedthreads.)
import std/asynchttpserver
proc serve(port: int) {.async.} =
  let server = newAsyncHttpServer()
  proc answer(req: Request) {.async.} =
    await req.respond(Http200, "Hello from Nim, at " & req.url.path)
  server.listen(Port(port))
  while true:
    if server.shouldAcceptRequest(): await server.acceptRequest(answer)
    else: await sleepAsync(500)
echo "serve is ready: ", typeof(serve(0)) is Future[void]
#> serve is ready: true

# %% Exercise: double them all
# Write `doubleLater`: wait 10 ms, then give back twice `x`. The check runs three of them at once.
proc doubleLater(x: int): Future[int] {.async.} =
  return 0
# Check:
let results = waitFor all(doubleLater(1), doubleLater(2), doubleLater(21))
if results == @[2, 4, 42]: echo "✓ doubleLater works"
else: echo "not yet: doubleLater of 1, 2 and 21 gives ", results
# Answer:
  # proc doubleLater(x: int): Future[int] {.async.} =
  #   await sleepAsync(10)
  #   return x * 2

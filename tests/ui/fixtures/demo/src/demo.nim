## demo — entry point
import demo/[utils, types]

proc greet*(who: string): string =
  "Hello, " & who & "!"

when isMainModule:
  let p = Person(name: "Ann", age: 30)
  echo greet(p.name)
  echo shout("done")

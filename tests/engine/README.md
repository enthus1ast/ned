# ned's Nim engine against nimsuggest

The numbers in the README's *How good it is* come from here. `compare.py` asks ned's built-in engine and
nimsuggest the same questions about one file and counts where they agree:

1. **type hints** — every `let` / `var` / `const` written without a type: ned's hint against nimsuggest's
   `inlayHints`;
2. **go to definition** at random identifiers, against nimsuggest's `def`;
3. **the types of the variables** among them, against the type `def` reports;
4. **member completion** at random `x.member` places: is the member written there offered right after the dot?

```sh
./build.sh                                   # the engine driver, from this checkout's source → ./ned-engine
./compare.py ~/src/myproject/src/app.nim     # one file
./corpus.sh /tmp/out 120                     # the standard library, nimble packages and the compiler
```

`NED_PKGS` is the nimble packages folder (default `~/.nimble/pkgs2`); `corpus.txt` lists the files, and a
package that is not installed is skipped (`nimble install chronos jsony pixie jester cligen karax vmath` for
all of them). nimsuggest comes from `PATH`.

`NED_NS_CACHE=/tmp/ns-cache` keeps nimsuggest's answers: the next run on unchanged files (with the same
nimsuggest) asks it nothing, so comparing a new build of the engine over the whole corpus takes a minute instead
of an hour. The times reported for nimsuggest are the ones it took when it answered.

Where the two disagree, either can be the one that is wrong: nimsuggest answers nothing (`:`) inside some
templates, and it crashes on some files (the count is in each report; it is started again). Types are compared
after small differences in how they are written are taken out: `system.int` is `int`, `lent string` is
`string`, `array[0..1, T]` is `array[2, T]`, `tuple[a, b: int]` is `tuple[a: int, b: int]`, pragmas of proc
types are left out.

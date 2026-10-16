import os, sys
W = sys.argv[1]
os.makedirs(W + '/src', exist_ok=True)
open(W + '/src/app.nim', 'w').write('''import std/os

proc load(path: string): string =
  # TODO: handle CRLF line endings
  readFile(path)

proc save(path, s: string) =
  ## FIXME(foxoman): this overwrites the file without a backup
  writeFile(path, s)

let msg = "TODO: not a tag, a string"
# the TODO in this sentence is prose, not a tag
echo load("x")  # BUG: crashes when the file is missing
#[ HACK: a workaround until the parser is fixed ]#
# NOTE: keep this order
''')
open(W + '/src/util.py', 'w').write('''def f():
    # NOTE: python comments work too
    return 1  # TODO: return the real value
''')
open(W + '/src/x.c', 'w').write('''int main(void) {
  /* XXX: magic number */
  return 42; // TODO make it configurable
}
''')

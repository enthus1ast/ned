#!/usr/bin/env python3
"""A real vim as ned's oracle: the same file, the same keys — where vim's cursor, text and register end up.

vim runs headless (`nvim -es`, or `vim`, whichever is on PATH) with a small script: it puts the cursor where a case
starts, gives it the case's keys (`feedkeys(..., 'xt')`, which reads them as normal-mode keys and waits for each), and
writes down what the state was after them — the line, the column, the whole text, the unnamed register and whether it
was linewise, and the visual mode. Nothing is timed and nothing is read from a screen, so a case answers the same thing
every run: 300 cases take a few seconds, not minutes.

    o = Oracle()
    o.need()                        # the UI suite's Skip when there is no vim to ask
    a = o.ask('d j', 1, 1, path=f)  # one case: what vim left behind, as a dict
    o.answers(cases, path, cache)   # many (keys, line, col) cases, kept in a JSON file while vim is the same

An answer's `col` is vim's own `col('.')`: on a line that starts with a tab it counts the tab's display columns, where
ned's status bar counts characters — `vimcases.vcol` turns one into the other.

    python3 tests/ui/vimoracle.py --json OUT    # every case of vimcases.py, answered by vim, written to OUT

Exit status: 0 when every case answered, 2 when there is no vim, 1 when one case did not answer.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# the script one case is given. `%(keys)s` is the case's keys as one Vim string, `%(line)d`/`%(col)d` where it starts,
# `%(out)s` the file the answer goes to.
SCRIPT = r"""
let v:errmsg = ''
" (the settings a case is about — the ones ned starts with unless the test set them: 4-space indents, a tab four
" columns wide, no autoindent. A bare `-u NONE` vim shifts by a tab, autoindents and draws a tab eight columns wide, which
" is not the vim ned is checked against)
set expandtab shiftwidth=4 softtabstop=0 tabstop=4 noautoindent nosmartindent nocindent
call cursor(%(line)d, %(col)d)
" (one string, one go: in ex mode vim's own key reading never echoes a pending operator between two feedkeys calls, so
" a text object's `i` and `(` would be read as motions — one string is the case as it is typed)
silent! call feedkeys(%(keys)s, 'xt')
let g:reg = getreginfo('"')
let g:out = {
      \ 'line': line('.'),
      \ 'col': col('.'),
      \ 'text': getline(1, '$'),
      \ 'visual': visualmode(),
      \ 'pending': mode(1) !=# 'cv',
      \ 'err': v:errmsg,
      \ }
try
  let g:out.reg = g:reg.regcontents
  let g:out.regtype = g:reg.regtype
catch
  let g:out.reg = []
  let g:out.regtype = ''
endtry
call writefile([json_encode(g:out)], %(out)s)
qa!
"""


def which_editor():
    """'nvim' or 'vim', whichever is on PATH, or None — vim's `feedkeys(..., 'xt')` is what the cases are given with"""
    for e in ('nvim', 'vim'):
        if shutil.which(e): return e
    return None


def vim_version(editor=None):
    """the editor's first version line: what the cached answers were given by"""
    e = editor or which_editor()
    if not e: return ''
    try:
        return subprocess.run([e, '--version'], capture_output=True, text=True, timeout=10).stdout.split('\n')[0]
    except (OSError, subprocess.SubprocessError):
        return ''


def vim_str(s):
    """a Python string as a double-quoted Vim script string a case's keys survive: an escape stays an escape (a `\\<Esc>`
    is the Escape key), a backslash and a quote are escaped for Vim"""
    out = []
    for ch in s:
        if ch == '\\': out.append('\\\\')
        elif ch == '"': out.append('\\"')
        elif ch == '\x1b': out.append('\\<Esc>')
        elif ch == '\t': out.append('\\t')
        elif ch == '\n': out.append('\\n')
        elif ch == '\r': out.append('\\r')
        elif ord(ch) < 32: out.append('\\x%02x' % ord(ch))
        else: out.append(ch)
    return '"' + ''.join(out) + '"'


class Oracle:
    """vim, run headless, answering where a case's keys leave its cursor, its text and its register"""

    def __init__(self, editor=None):
        self.editor = editor or which_editor()

    def need(self):
        """raise the UI suite's Skip when there is no vim to ask (a test that needs the oracle says so)"""
        if not self.editor:
            raise _skip('nvim or vim on PATH (the vim oracle)')

    def ask(self, keys, line=1, col=1, text=None, path=None):
        """one case in one vim: the file's `text` (or a copy of `path`), the cursor at `line`/`col` from 1, the case's
        `keys` as vim writes them ('d j', 'x', 'yi('), and what vim's state was after them"""
        self.need()
        d = tempfile.mkdtemp(prefix='ned-vimoracle-')
        try:
            f = os.path.join(d, 'file.txt')
            if path is not None: shutil.copyfile(path, f)
            else:
                with open(f, 'w', encoding='utf-8', newline='') as fh: fh.write(text if text is not None else '')
            out = os.path.join(d, 'out.json')
            script = os.path.join(d, 'case.vim')
            with open(script, 'w', encoding='utf-8') as fh:
                fh.write(SCRIPT % {'line': line, 'col': col, 'keys': vim_str(keys), 'out': vim_str(out)})
            r = subprocess.run([self.editor, '--clean', '-u', 'NONE', '-i', 'NONE', '-n', '-es', '-S', script, f],
                               capture_output=True, text=True, timeout=120, cwd=d)
            if not os.path.exists(out):
                raise RuntimeError('%s gave no answer to %r:\n%s%s' % (self.editor, keys, r.stdout[-300:],
                                                                       r.stderr[-300:]))
            a = json.load(open(out, encoding='utf-8'))
            a['linewise'] = 'V' in a.get('regtype', '')
            a['keys'] = keys
            return a
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def answers(self, cases, path, cache=None):
        """the answers to many cases — each `(keys, line, col)` — in the order asked. With `cache` (a JSON file) they are
        kept there and given back while vim's version and the cases are the same: vim answers the same thing every time,
        so a test run need not ask it 300 times again"""
        if cache and os.path.exists(cache):
            try:
                old = json.load(open(cache, encoding='utf-8'))
                if old.get('vim') == vim_version(self.editor) and old.get('cases') == cases:
                    return old['answers']
            except (ValueError, KeyError, OSError):
                pass
        answers = [self.ask(k, line, col, path=path) for (k, line, col) in cases]
        if cache:
            try:
                with open(cache, 'w', encoding='utf-8') as f:
                    json.dump({'vim': vim_version(self.editor), 'cases': cases, 'answers': answers}, f)
            except OSError:
                pass
        return answers


def _skip(what):
    """the UI suite's Skip (harness.Skip) when the harness is loaded, else a RuntimeError: the helper on its own"""
    s = sys.modules.get('harness')
    if s is not None and hasattr(s, 'Skip'):
        return s.Skip('needs ' + what)
    return RuntimeError('needs ' + what)


def main(argv):
    """the module on its own: every case of vimcases.py answered by vim (into the file `--json` names, or printed)"""
    sys.path.insert(0, HERE)
    import vimcases
    o = Oracle()
    if not o.editor:
        print('SKIP  no nvim or vim on PATH')
        return 2
    cases = [(vimcases.vim_keys(k), l, c) for (k, l, c, _) in vimcases.CASES]
    out = []
    for (keys, line, col), (case, _, _, edit) in zip(cases, vimcases.CASES):
        a = o.ask(keys, line, col, path=vimcases.FIXTURE)
        a['case'] = case
        a['edit'] = edit
        if not edit: a['text'] = None          # (a movement leaves the text alone: it is not what is compared)
        out.append(a)
    body = {'vim': vim_version(o.editor), 'answers': out}
    if '--json' in argv:
        json.dump(body, open(argv[argv.index('--json') + 1], 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
        print('%d cases answered by %s' % (len(out), body['vim']))
    else:
        print(json.dumps(body, indent=1, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

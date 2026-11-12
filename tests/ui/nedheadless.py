#!/usr/bin/env python3
"""ned's vim mode with no terminal: one `ned -es` process, a case per line of JSON (src/ned/app/headless.nim).

The editor starts once on the fixture and stays; each case is a request on its stdin and an answer on its stdout —
where vim mode left the cursor, the mode and the text. No tmux server, no screen read back, no file written between
cases: a case costs about a tenth of a millisecond rather than two seconds.

    n = Headless('/path/to/ned', vimcases.FIXTURE)
    a = n.case('d w', 1, 1, edit=True)     # {'line', 'col', 'shown', 'visual', 'text'}
    n.stop()

`col` is a character column as vim's `col('.')` counts it, `shown` the display column ned's status bar shows (a tab
takes the columns it is drawn over), `visual` "", "v", "V", "i" or "R", and `text` the buffer's lines (for an edit).
"""
import json
import subprocess


def available(binary):
    """whether this ned has -es (a build from before it, or one made without it, has not)"""
    try:
        r = subprocess.run([binary, '--help'], capture_output=True, text=True, timeout=30)
        return '--headless' in (r.stdout or '')
    except (OSError, subprocess.SubprocessError):
        return False


class Headless:
    """ned in vim mode with no terminal, in one process, answering a case at a time"""

    headless = True                     # (what vimdiff.py and suite.py look at: this asks ned itself, no tmux)

    def __init__(self, binary, fixture):
        """the ned to ask and the file the cases start from"""
        self.binary = binary
        self.fixture = fixture
        self.p = None
        self.headless = True

    def start(self):
        """the editor, once, on the fixture: `ned -es FILE` reads a request per line and answers a line each"""
        self.p = subprocess.Popen([self.binary, '-es', self.fixture], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        return self

    def case(self, keys, line=1, col=1, edit=False):
        """one case: the keys as vim writes them ('d w', 'x', 'yi(', '<Esc>' for Escape), where they start from 1,
        and ned's answer after them — the text too when it is an edit"""
        if self.p is None: self.start()
        self.p.stdin.write(json.dumps({'keys': keys, 'line': line, 'col': col}) + '\n')
        self.p.stdin.flush()
        out = self.p.stdout.readline()
        if not out:
            raise RuntimeError('ned -es gave no answer to %r (it left: %r)' % (keys, self.p.poll()))
        a = json.loads(out)
        if 'error' in a:
            raise RuntimeError('ned -es: %s' % a['error'])
        return {'line': a['line'], 'col': a['col'], 'shown': a['viscol'],
                'visual': a['visual'], 'text': a['text'] if edit else None}

    def stop(self):
        """the process goes (its own settings and state folder with it)"""
        if self.p is None: return
        try:
            self.p.stdin.write('{"quit":true}\n')
            self.p.stdin.flush()
            self.p.wait(timeout=10)
        except (OSError, subprocess.SubprocessError, ValueError):
            self.p.kill()
        self.p = None

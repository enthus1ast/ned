#!/usr/bin/env python3
"""ned's UI tests — the whole editor driven through tmux, its screen read back.

  python3 tests/ui/run.py [NEDBIN] [TEST …]      all tests, or the ones named (t_engine_refs_rename …)
  python3 tests/ui/run.py --list                  the tests' names
  python3 tests/ui/run.py --shard 2/4             every 4th test, starting with the 2nd (CI runs 4 side by side)

Needs tmux, git, python3 and nim on PATH (NEDBIN defaults to ./ned). Language servers, clangd, gdb and the
other optional tools are used when they are on PATH or in NED_TEST_PATH; a test that needs a missing one is
skipped and says what it needs. Each run works in a scratch folder of its own; a mock AI server answers the
assistant's requests. Exit status: 0 when nothing failed.
"""
import os, sys, time, socket, subprocess, tempfile, shutil, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def main():
    args = sys.argv[1:]
    if '-h' in args or '--help' in args:
        print(__doc__); return 0
    keep = '--keep' in args
    args = [a for a in args if a != '--keep']
    shard = None
    if '--shard' in args:
        k = args.index('--shard')
        i, n = args[k + 1].split('/')
        shard = (int(i) - 1, int(n))
        del args[k:k + 2]
    nedbin = REPO + '/ned'
    if args and not args[0].startswith('t_') and args[0] != '--list':
        nedbin = args.pop(0)
    for tool in ['tmux', 'git', 'nim']:
        if not shutil.which(tool):
            print('%s is needed on PATH' % tool); return 2
    if args != ['--list'] and not os.access(nedbin, os.X_OK):
        print('no ned binary at %s — build it first: nimble release' % nedbin); return 2
    tmp = tempfile.mkdtemp(prefix='ned-ui-')
    # (on GitHub's runners ned --lint would write annotations, not path:line:col: the tests ask for them by name)
    os.environ.pop('GITHUB_ACTIONS', None)
    os.environ['NED_TEST_TMP'] = tmp
    os.environ.setdefault('NED_UPDATE_URL', tmp + '/no-release.json')   # (no look on GitHub for a newer ned)
    os.environ['NEDBIN'] = os.path.abspath(nedbin)
    os.environ['NED_TEST_AI_PORT'] = str(free_port())
    os.environ['NED_TEST_MOCK_LOG'] = tmp + '/mock-requests.log'
    os.environ.setdefault('NED_TEST_SOCKET', 'ned-ui-%d' % os.getpid())
    sys.path.insert(0, HERE)
    import suite
    if args == ['--list']:
        for t in suite.tests: print(t.__name__)
        return 0
    byname = {n: getattr(suite, n) for n in dir(suite) if n.startswith('t_') and callable(getattr(suite, n))}
    unknown = [a for a in args if a not in byname]
    if unknown:
        print('no such test:', ' '.join(unknown)); return 2
    chosen = [byname[a] for a in args] if args else suite.tests
    if shard: chosen = chosen[shard[0]::shard[1]]
    mock = subprocess.Popen([sys.executable, '-I', HERE + '/mocks/mockai.py', os.environ['NED_TEST_AI_PORT']],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=tmp)
    skipped = []
    t0 = time.time()
    try:
        for t in chosen:
            try:
                t()
            except suite.Skip as e:
                skipped.append(t.__name__)
                print('SKIP %s  (%s)' % (t.__name__, e), flush=True)
            except Exception as e:
                suite.check(t.__name__, False, repr(e) + ' ' + traceback.format_exc()[-600:])
            finally:
                suite.tm('kill-server')
    finally:
        mock.terminate()
    passed = sum(1 for _, ok in suite.results if ok)
    failed = [n for n, ok in suite.results if not ok]
    print('\n%d/%d passed%s in %d min' % (passed, len(suite.results),
          (', %d tests skipped' % len(skipped)) if skipped else '', (time.time() - t0) / 60))
    if failed:
        print('failed:\n  ' + '\n  '.join(failed))
        print('(the scratch folder is kept: %s)' % tmp)
    elif not keep:
        shutil.rmtree(tmp, ignore_errors=True)
    return 1 if failed else 0

if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""ned's Nim formatter against nph, on the same files: how much of its output is nph's, line for line; the files
each one formats and the ones it leaves alone (nph refuses some, ned leaves alone what it is not sure of); and the
time each takes over all of them, in one run each.

  python3 tests/format/vsnph.py NEDFMT NPH [NIMROOT] [--list FILE] [--json OUT]

  NEDFMT   ned's formatter (nim c -d:release -o:nedfmt src/nedfmt.nim)
  NPH      nph
  NIMROOT  a Nim source tree (default: the one of the nim on PATH); the files: tests/format/corpus.txt
           (463 files of Nim's compiler and standard library), or --list
Both run with their default layout (no settings of yours: an empty XDG_CONFIG_HOME, no .nph.toml)."""
import difflib, json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))


def nim_root():
    nim = shutil.which('nim')
    return os.path.dirname(os.path.dirname(os.path.realpath(nim))) if nim else ''


def same_lines(a, b):
    """the lines of a that are b's too, in order (their longest common run, as diff counts it)"""
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    return sum(m.size for m in sm.get_matching_blocks())


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    opts = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 2
    nedfmt, nph = os.path.abspath(args[0]), os.path.abspath(args[1])
    root = args[2] if len(args) > 2 else nim_root()
    lst = opts[opts.index('--list') + 1] if '--list' in opts else os.path.join(HERE, 'corpus.txt')
    out_json = opts[opts.index('--json') + 1] if '--json' in opts else ''
    files = [l.strip() for l in open(lst) if l.strip() and not l.startswith('#')]
    files = [f for f in files if os.path.isfile(os.path.join(root, f))]
    tmp = tempfile.mkdtemp(prefix='ned-vsnph-')
    try:
        src, o_ned, o_nph, cfg = (os.path.join(tmp, d) for d in ('src', 'ned', 'nph', 'cfg'))
        for d in (src, o_ned, o_nph, cfg):
            os.makedirs(d)
        names = []
        for i, f in enumerate(files):
            n = '%03d_%s' % (i, os.path.basename(f))
            shutil.copy(os.path.join(root, f), os.path.join(src, n))
            names.append(n)
        env = dict(os.environ, XDG_CONFIG_HOME=cfg)
        inputs = names            # (relative, from src: both write each to the output folder by that name)
        t0 = time.time()
        subprocess.run([nedfmt, '--quiet', '--outDir:' + o_ned] + inputs, env=env, capture_output=True, cwd=src)
        t_ned = time.time() - t0
        t0 = time.time()
        r = subprocess.run([nph, '--outDir:' + o_nph] + inputs, env=env, capture_output=True, text=True, cwd=src)
        t_nph = time.time() - t0
        both = ident = same = total = 0
        ned_alone, nph_refused = [], []
        for n, f in zip(names, files):
            a_p, b_p = os.path.join(o_ned, n), os.path.join(o_nph, n)
            orig = open(os.path.join(src, n), encoding='utf-8', errors='replace').read()
            a = open(a_p, encoding='utf-8', errors='replace').read() if os.path.exists(a_p) else None
            b = open(b_p, encoding='utf-8', errors='replace').read() if os.path.exists(b_p) else None
            if b is None:
                nph_refused.append(f)
                continue
            if a is None or (a == orig and b != orig):
                ned_alone.append(f)
                continue
            both += 1
            if a == b:
                ident += 1
            la, lb = a.splitlines(), b.splitlines()
            same += same_lines(lb, la)
            total += len(lb)
        res = {'files': len(files), 'both': both, 'identical_files': ident, 'lines_same': same, 'lines_total': total,
               'ned_s': round(t_ned, 2), 'nph_s': round(t_nph, 2), 'ned_left_alone': ned_alone,
               'nph_refused': nph_refused}
        print('%d files · formatted by both: %d · identical: %d · lines the same as nph\'s: %.2f%% of %d' % (
            len(files), both, ident, 100.0 * same / max(1, total), total))
        print('time over all of them: ned %.2f s, nph %.2f s' % (t_ned, t_nph))
        print('nph refused %d: %s' % (len(nph_refused), ', '.join(nph_refused[:8])))
        print('ned left alone %d: %s' % (len(ned_alone), ', '.join(ned_alone[:8])))
        if out_json:
            json.dump(res, open(out_json, 'w'), indent=1)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())

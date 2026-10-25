#!/usr/bin/env python3
"""The engines' scoreboard: ned's Nim engine against nimsuggest and its C engine against clangd, on a fixed set of
files, each score against the minimum tests/engine/scoreboard.json sets — CI fails when one falls below it.

  python3 tests/engine/scoreboard.py [--engine ned-engine] [--cdriver ned-cengine] [--nedls nedls]
                                     [--c-files F.c …] [--cpp-files F.cpp …] [--nimlangserver NLS]
                                     [--nedfmt NEDFMT --nph NPH] [--n 40] [--readme] [--json OUT]

  --engine   the Nim engine driver (tests/engine/build.sh makes it)       — compare.py: type hints, definitions,
                                                                           variables' types, member completion,
                                                                           references; diagcompare.py: the engine's
                                                                           errors as you type against nim check
  --nedls    nedls (ned's engine as a language server)                    — parity.py: hover, completion,
                                                                           signature help where nimsuggest knows
  --cdriver  the C engine driver (nim c -d:release tests/engine/cdriver.nim) and --c-files: C files with clangd on
             PATH                                                          — ccompare.py: definitions, members, hover
  --cpp-files  C++ files for the same, with clangd                        — the same questions, as C++
  --nimlangserver  nimlangserver, with --nedls                         — lspversus.py: the same hovers, definitions
                                                                           and member completions asked of both
  --nedfmt, --nph  ned's formatter and nph (the nim on PATH a source tree) — vsnph.py: the lines the same, the
                                                                           files each formats, the time each takes
  --readme   the numbers written into the README (between <!-- scoreboard --> and <!-- /scoreboard -->)

A part whose tool is missing (nimsuggest, clangd, a driver not given) is left out and said so; its minimums are not
checked. The Nim files are standard-library modules found next to the `nim` on PATH (the same for everyone)."""
import argparse, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MIN = json.load(open(os.path.join(HERE, 'scoreboard.json')))

NIM_FILES = ['pure/strutils.nim', 'pure/parseutils.nim', 'pure/json.nim', 'pure/collections/tables.nim',
             'pure/collections/sequtils.nim', 'pure/strformat.nim', 'std/paths.nim', 'pure/times.nim']


def nim_lib():
    nim = shutil.which('nim')
    if not nim: return ''
    try:
        out = subprocess.run(['nim', 'dump', '--dump.format:json', '/dev/null'], capture_output=True, text=True,
                             timeout=60).stdout
        return json.loads(out)['libpath']
    except Exception:
        return ''


def pc(a, b): return round(100.0 * a / b, 1) if b else None


def run(cmd, **kw):
    print('$ ' + ' '.join(cmd[:4]) + (' …' if len(cmd) > 4 else ''), flush=True)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def nim_part(engine, files, n, tmp):
    """compare.py on each file: the totals as aggregate.py adds them"""
    t = dict(h_agree=0, h_diff=0, h_ns=0, d_agree=0, d_ns=0, d_dis=0, t_agree=0, t_diff=0, t_none=0, s_n=0, s_ned=0,
             s_ns=0, r_same=0, r_n=0)
    env = dict(os.environ, NED_DRIVER=engine)
    for f in files:
        out = os.path.join(tmp, os.path.basename(f) + '.json')
        r = run([sys.executable, os.path.join(HERE, 'compare.py'), f, '--n', str(n), '--json', out], env=env,
                timeout=3600)
        if not os.path.exists(out):
            print('  (no report for %s: %s)' % (f, (r.stdout + r.stderr)[-300:]))
            continue
        x = json.load(open(out))
        h = x.get('hints', {})
        t['h_agree'] += h.get('agree', 0); t['h_diff'] += h.get('differ', 0); t['h_ns'] += h.get('nimsuggest_only', 0)
        d = x['def']; t['d_agree'] += d['agree']; t['d_ns'] += d['ns_only']; t['d_dis'] += d['disagree']
        ty = x['types']; t['t_agree'] += ty['agree']; t['t_diff'] += ty['differ']; t['t_none'] += ty['ned_none']
        s = x['sug']; t['s_n'] += s['n']; t['s_ned'] += s['ned']; t['s_ns'] += s['nimsuggest']
        r = x.get('refs', {}); t['r_same'] += r.get('same', 0); t['r_n'] += r.get('n', 0)
    return {
        'nim: type hints, the same as nimsuggest\'s': pc(t['h_agree'], t['h_agree'] + t['h_diff'] + t['h_ns']),
        'nim: go to definition, the same place': pc(t['d_agree'], t['d_agree'] + t['d_ns'] + t['d_dis']),
        'nim: a variable\'s type, the same': pc(t['t_agree'], t['t_agree'] + t['t_diff'] + t['t_none']),
        'nim: member completion, ned': pc(t['s_ned'], t['s_n']),
        'nim: member completion, nimsuggest (not checked)': pc(t['s_ns'], t['s_n']),
        'nim: references in the file, the same as nimsuggest\'s': pc(t['r_same'], t['r_n']),
    }


def diag_part(engine, files, tmp):
    """diagcompare.py: the engine's errors as you type against nim check"""
    out = os.path.join(tmp, 'diag.json')
    run([sys.executable, os.path.join(HERE, 'diagcompare.py'), engine, out] + files + ['--n', '6'], timeout=3600)
    if not os.path.exists(out): return {}
    x = json.load(open(out))
    return {
        'nim: as you type, the compiler\'s errors found': pc(x['engine_found'], x['compiler_found']),
        'nim: as you type, clean files with no wrong error': pc(x['clean_ok'], x['clean_files']),
    }


def nedls_part(nedls, files, n, tmp):
    out = os.path.join(tmp, 'parity.json')
    run([sys.executable, os.path.join(HERE, 'parity.py'), '--nedls', nedls, '--n', str(n), '--json', out] + files,
        timeout=3600)
    if not os.path.exists(out): return {}
    tot = json.load(open(out))['totals']
    res = {}
    for k, (cnt, ok) in sorted(tot.items()):
        res['nedls: ' + k] = pc(ok, cnt)
    return res


def c_part(cdriver, files, n, tmp, lang='c'):
    out = os.path.join(tmp, lang)
    run([sys.executable, os.path.join(HERE, 'ccompare.py'), cdriver, out] + files + ['--n', str(n)], timeout=3600)
    p = os.path.join(out, 'totals.json')
    if not os.path.exists(p): return {}
    t = json.load(open(p))
    return {
        lang + ': go to definition, the same as clangd\'s': pc(t['def_agree'], t['def_agree'] + t['def_differ']),
        lang + ': member completion, ned': pc(t['mem_ned'], t['mem_n']),
        lang + ': member completion, clangd (not checked)': pc(t['mem_clangd'], t['mem_n']),
        lang + ': hover, the same parameters': pc(t.get('hov_same', 0), t.get('hov_ned', 0)),
    }


def versus_part(nedls, other, files, n, tmp, notes):
    """lspversus.py: nedls and nimlangserver asked the same, each file with servers of its own"""
    out = os.path.join(tmp, 'versus.json')
    run([sys.executable, os.path.join(HERE, 'lspversus.py'), '--nedls', nedls, '--other', other, '--n', str(n),
         '--json', out] + files, timeout=3600)
    if not os.path.exists(out): return {}
    x = json.load(open(out))
    p, m = x['places'], x['members']
    a, b = x['nedls'], x['other']
    notes.append('against nimlangserver: nedls answers in %s ms (the median), ready after %s ms; nimlangserver in %s '
                 'ms, ready after %s ms' % (a['median_ms'], a['first_ms'], b['median_ms'], b['first_ms']))
    return {
        'versus nimlangserver: hover, nedls': pc(a['hover'], p),
        'versus nimlangserver: hover, nimlangserver (not checked)': pc(b['hover'], p),
        'versus nimlangserver: definition, nedls': pc(a['def'], p),
        'versus nimlangserver: definition, nimlangserver (not checked)': pc(b['def'], p),
        'versus nimlangserver: member offered, nedls': pc(a['member'], m),
        'versus nimlangserver: member offered, nimlangserver (not checked)': pc(b['member'], m),
        'versus nimlangserver: the same definition where both answer': pc(x['def_same'], x['def_both']),
    }


def nph_part(nedfmt, nph, tmp, notes):
    """tests/format/vsnph.py over Nim's compiler and standard library (the nim on PATH must be a source tree)"""
    nim = shutil.which('nim')
    root = os.path.dirname(os.path.dirname(os.path.realpath(nim))) if nim else ''
    if not os.path.isdir(os.path.join(root, 'compiler')): return {}
    out = os.path.join(tmp, 'vsnph.json')
    run([sys.executable, os.path.join(REPO, 'tests', 'format', 'vsnph.py'), nedfmt, nph, root, '--json', out],
        timeout=3600)
    if not os.path.exists(out): return {}
    x = json.load(open(out))
    notes.append('against nph: %d files formatted in %.2f s by ned, %.2f s by nph; nph refused %d, ned left %d alone'
                 % (x['files'], x['ned_s'], x['nph_s'], len(x['nph_refused']), len(x['ned_left_alone'])))
    return {
        'format: lines the same as nph\'s': pc(x['lines_same'], x['lines_total']),
        'format: files formatted, of those nph formats': pc(x['both'], x['files'] - len(x['nph_refused'])),
    }


def table(scores):
    rows = ['| | score | at least |', '|---|---|---|']
    for k, v in scores.items():
        m = MIN.get(k)
        mark = '' if m is None or v is None else (' ✓' if v >= m else ' ✗')
        rows.append('| %s | %s%s | %s |' % (k, '—' if v is None else '%.1f%%' % v, mark, '' if m is None else '%g%%' % m))
    return '\n'.join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--engine', default='')
    ap.add_argument('--nedls', default='')
    ap.add_argument('--cdriver', default='')
    ap.add_argument('--c-files', nargs='*', default=[])
    ap.add_argument('--cpp-files', nargs='*', default=[])
    ap.add_argument('--n', type=int, default=40)
    ap.add_argument('--readme', action='store_true')
    ap.add_argument('--json', default='')
    ap.add_argument('--nimlangserver', default='')
    ap.add_argument('--nedfmt', default='')
    ap.add_argument('--nph', default='')
    a = ap.parse_args()
    lib = nim_lib()
    files = [os.path.join(lib, f) for f in NIM_FILES if lib and os.path.exists(os.path.join(lib, f))]
    tmp = tempfile.mkdtemp(prefix='ned-scoreboard-')
    scores = {}
    left = []
    notes = []
    try:
        if a.engine and files and shutil.which('nimsuggest'): scores.update(nim_part(os.path.abspath(a.engine), files, a.n, tmp))
        else: left.append('the Nim engine (needs --engine, nimsuggest and the standard library)')
        if a.engine and files and shutil.which('nim'): scores.update(diag_part(os.path.abspath(a.engine), files, tmp))
        if a.nedls and files and shutil.which('nimsuggest'):
            scores.update(nedls_part(os.path.abspath(a.nedls), files[:4], a.n, tmp))
        else: left.append('nedls (needs --nedls and nimsuggest)')
        cf = [f for f in a.c_files if os.path.exists(f)]
        if a.cdriver and cf and shutil.which('clangd'): scores.update(c_part(os.path.abspath(a.cdriver), cf, a.n, tmp))
        else: left.append('the C engine (needs --cdriver, --c-files and clangd)')
        xf = [f for f in a.cpp_files if os.path.exists(f)]
        if a.cdriver and xf and shutil.which('clangd'):
            scores.update(c_part(os.path.abspath(a.cdriver), xf, a.n, tmp, 'c++'))
        elif a.cpp_files: left.append('the C engine on C++ (needs --cdriver, --cpp-files and clangd)')
        if a.nedls and a.nimlangserver and files and shutil.which('nimsuggest'):
            scores.update(versus_part(os.path.abspath(a.nedls), os.path.abspath(a.nimlangserver), files[:3], a.n // 2,
                                      tmp, notes))
        elif a.nimlangserver: left.append('nedls against nimlangserver (needs --nedls, --nimlangserver and nimsuggest)')
        if a.nedfmt and a.nph: scores.update(nph_part(os.path.abspath(a.nedfmt), os.path.abspath(a.nph), tmp, notes))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    t = table(scores) + ''.join('\n\n' + x for x in notes)
    print('\n' + t)
    for l in left: print('left out: ' + l)
    if a.json: json.dump(scores, open(a.json, 'w'), indent=1)
    if a.readme:
        p = os.path.join(REPO, 'README.md')
        s = open(p).read()
        m = re.search(r'(<!-- scoreboard -->\n)(.*?)(<!-- /scoreboard -->)', s, re.S)
        if m:
            open(p, 'w').write(s[:m.start(2)] + t + '\n' + s[m.end(2):])
            print('README.md: the numbers written')
    below = [k for k, v in scores.items() if k in MIN and v is not None and v < MIN[k]]
    for k in below: print('::error::%s: %.1f%%, below the minimum of %g%%' % (k, scores[k], MIN[k]))
    return 1 if below else 0


if __name__ == '__main__':
    sys.exit(main())

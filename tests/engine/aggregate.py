#!/usr/bin/env python3
"""aggregate.py DIR — the harness reports of a corpus run, summed"""
import json, sys, glob, os
tot = dict(h_agree=0, h_diff=0, h_ns=0, h_ned=0, d_agree=0, d_ns=0, d_dis=0, d_ned=0, t_agree=0, t_diff=0, t_none=0,
           s_n=0, s_ned=0, s_ns=0, crashes=0, files=0)
rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.json'))):
    r = json.load(open(f))
    tot['files'] += 1
    h = r.get('hints', {})
    tot['h_agree'] += h.get('agree', 0); tot['h_diff'] += h.get('differ', 0); tot['h_ns'] += h.get('nimsuggest_only', 0); tot['h_ned'] += h.get('ned_only', 0)
    d = r['def']; tot['d_agree'] += d['agree']; tot['d_ns'] += d['ns_only']; tot['d_dis'] += d['disagree']; tot['d_ned'] += d['ned_only']
    t = r['types']; tot['t_agree'] += t['agree']; tot['t_diff'] += t['differ']; tot['t_none'] += t['ned_none']
    s = r['sug']; tot['s_n'] += s['n']; tot['s_ned'] += s['ned']; tot['s_ns'] += s['nimsuggest']
    tot['crashes'] += r.get('ns_crashes', 0)
    rows.append((r['file'], h, d, t, s))
pc = lambda a, b: 100.0 * a / max(1, b)
print('files %d · nimsuggest crashed %d times' % (tot['files'], tot['crashes']))
print('type hints   : same as nimsuggest %.1f%%  (same %d, different %d, only nimsuggest %d, only ned %d)' %
      (pc(tot['h_agree'], tot['h_agree'] + tot['h_diff'] + tot['h_ns']), tot['h_agree'], tot['h_diff'], tot['h_ns'], tot['h_ned']))
print('definition   : agrees %.1f%% where nimsuggest answers  (agree %d, nimsuggest only %d, differ %d, ned only %d)' %
      (pc(tot['d_agree'], tot['d_agree'] + tot['d_ns'] + tot['d_dis']), tot['d_agree'], tot['d_ns'], tot['d_dis'], tot['d_ned']))
print('var types    : same %.1f%%  (same %d, different %d, ned none %d)' %
      (pc(tot['t_agree'], tot['t_agree'] + tot['t_diff'] + tot['t_none']), tot['t_agree'], tot['t_diff'], tot['t_none']))
print('member compl.: ned %.1f%% · nimsuggest %.1f%%  (of %d)' % (pc(tot['s_ned'], tot['s_n']), pc(tot['s_ns'], tot['s_n']), tot['s_n']))

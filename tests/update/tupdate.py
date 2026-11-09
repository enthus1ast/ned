#!/usr/bin/env python3
"""Checking a release before it is installed, against a fake release in a local folder (no network): install.sh's
Termux path and `ned --update` (its Termux path, and --verify DIR) with the release's JSON, its package, SHA256SUMS and
SHA256SUMS.sig given as file:// URLs, and apt replaced by a script that writes down what it was asked to install.

  unsigned, ned has no key yet       installed, "not signed yet" said
  a package that does not match      refused, apt never runs
  no SHA256SUMS in the release       refused
  signed, and ned has the key        installed, the signature checked
  signed by another key              refused
  ned has a key, no signature        refused
  a version only tagged              built with nimble on Termux (asked first)
  install.sh outside Termux          built with nimble (PREFIX not set, or set to another folder)

Usage: tupdate.py [path/to/ned]   (without a ned: install.sh only). The signed cases need ssh-keygen (OpenSSH).
Exit status 1 when a check fails."""
import hashlib, json, os, shutil, stat, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
NED = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else None
KEYGEN = shutil.which('ssh-keygen')
fails = []

def check(what, cond, out=''):
    print(('ok    ' if cond else 'FAIL  ') + what)
    if not cond:
        fails.append(what)
        if out: print('      ' + out.strip().replace('\n', '\n      '))

root = tempfile.mkdtemp(prefix='ned-tupdate-')
rel = os.path.join(root, 'release')
fake = os.path.join(root, 'bin')
os.makedirs(rel); os.makedirs(fake)
applog = os.path.join(root, 'apt.log')
nimblelog = os.path.join(root, 'nimble.log')
for name, body in [('apt', '#!/bin/sh\necho "$@" >> %s\n' % applog), ('ned', '#!/bin/sh\necho "ned 99.0.0"\n'),
                   ('nimble', '#!/bin/sh\necho "$@" >> %s\n' % nimblelog)]:
    p = os.path.join(fake, name)
    open(p, 'w').write(body)
    os.chmod(p, 0o755)
DEB = 'ned_99.0.0_aarch64.deb'
PLACEHOLDER = os.path.join(root, 'signers-placeholder')
open(PLACEHOLDER, 'w').write('# no key yet\nPLACEHOLDER-RELEASE-KEY\n')

def keygen(name):
    k = os.path.join(root, name)
    subprocess.run([KEYGEN, '-q', '-t', 'ed25519', '-N', '', '-C', 'test', '-f', k], check=True)
    signers = os.path.join(root, name + '.signers')
    open(signers, 'w').write('ned-release namespaces="ned-release" ' + open(k + '.pub').read().strip() + '\n')
    return k, signers

def release(deb=b'the package\n', sums=True, sign_with=None, list_sig=True, wrong_sum=False):
    """the fake release: its files and its JSON (assets as file:// URLs)"""
    shutil.rmtree(rel); os.makedirs(rel)
    open(os.path.join(rel, DEB), 'wb').write(deb)
    assets = [DEB]
    if sums:
        h = hashlib.sha256(b'the package\n' if not wrong_sum else b'other').hexdigest()
        open(os.path.join(rel, 'SHA256SUMS'), 'w').write(h + '  ' + DEB + '\n')
        assets.append('SHA256SUMS')
        if sign_with:
            subprocess.run([KEYGEN, '-q', '-Y', 'sign', '-f', sign_with, '-n', 'ned-release',
                            os.path.join(rel, 'SHA256SUMS')], check=True)
            if list_sig: assets.append('SHA256SUMS.sig')
    j = {'tag_name': 'v99.0.0', 'assets': [{'name': a, 'browser_download_url': 'file://' + os.path.join(rel, a)}
                                           for a in assets]}
    jp = os.path.join(root, 'release.json')
    json.dump(j, open(jp, 'w'))
    return jp

def env(signers, **kw):
    e = dict(os.environ, PATH=fake + os.pathsep + os.environ['PATH'], TERMUX_VERSION='1', NED_RELEASE_SIGNERS=signers,
             TMPDIR=root, HOME=root, XDG_CONFIG_HOME=root + '/cfg', XDG_STATE_HOME=root + '/state', NED_SOCKET='')
    e.update(kw)
    return e

def installed():
    try:
        t = open(applog).read()
        os.remove(applog)
        return DEB in t
    except OSError:
        return False

def install_sh(jp, signers):
    r = subprocess.run(['sh', os.path.join(REPO, 'install.sh')], env=env(signers, NED_INSTALL_API='file://' + jp),
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr

def ned_update(jp, signers):
    r = subprocess.run([NED, '--update', '--yes'], env=env(signers, NED_UPDATE_URL=jp, NED_UPDATE_HOW='termux'),
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr

def ned_verify(signers, *names):
    r = subprocess.run([NED, '--update', '--verify', rel] + list(names),
                       env=env(signers, NED_UPDATE_URL=os.path.join(root, 'release.json')),
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr

runners = [('install.sh', install_sh)] + ([('ned --update', ned_update)] if NED else [])
for who, run in runners:
    code, out = run(release(), PLACEHOLDER)
    check(who + ': unsigned, no key yet: installed, and said', code == 0 and installed() and 'not signed yet' in out, out)
    code, out = run(release(deb=b'evil\n'), PLACEHOLDER)
    check(who + ': a package that does not match: refused', code != 0 and not installed() and 'Refused' in out, out)
    code, out = run(release(sums=False), PLACEHOLDER)
    check(who + ': no SHA256SUMS: refused', code != 0 and not installed() and 'no SHA256SUMS' in out, out)
    if not KEYGEN:
        print('(no ssh-keygen: the signed cases skipped)')
        continue
    good, good_signers = keygen('good-' + who.replace(' ', '_'))
    other, _ = keygen('other-' + who.replace(' ', '_'))
    code, out = run(release(sign_with=good), good_signers)
    check(who + ': signed, ned has the key: installed', code == 0 and installed() and 'signature' in out, out)
    code, out = run(release(sign_with=other), good_signers)
    check(who + ': signed by another key: refused', code != 0 and not installed() and 'not signed by' in out, out)
    code, out = run(release(sign_with=good, list_sig=False), good_signers)
    check(who + ': ned has a key, the release no signature: refused', code != 0 and not installed(), out)
    code, out = run(release(sign_with=good, deb=b'evil\n'), good_signers)
    check(who + ': signed, but the package changed: refused', code != 0 and not installed(), out)

# outside Termux (PREFIX not set, as on most Linux machines and macOS, or set to another folder): built with nimble,
# by the shell `curl … | sh` runs (dash on Debian and Ubuntu)
for shell in [s for s in ['sh', 'dash', 'bash'] if shutil.which(s)]:
    for prefix in [None, '/usr/local']:
        e = {k: v for k, v in env(PLACEHOLDER).items() if k not in ('TERMUX_VERSION', 'PREFIX')}
        if prefix: e['PREFIX'] = prefix
        if os.path.exists(nimblelog): os.remove(nimblelog)
        r = subprocess.run([shell, os.path.join(REPO, 'install.sh')], env=e, capture_output=True, text=True, timeout=60)
        out = r.stdout + r.stderr
        built = os.path.exists(nimblelog) and 'github.com/foxoman/ned' in open(nimblelog).read()
        check('install.sh outside Termux (%s, PREFIX %s): built with nimble' % (shell, prefix or 'not set'),
              r.returncode == 0 and built and not installed() and 'Installed: ned' in out, out)

if NED:
    # a version that is only a tag (no release, no package): Termux builds it with nimble — said, asked, nothing run
    tags = os.path.join(root, 'tags.json')
    json.dump([{'name': 'v99.1.0'}, {'name': 'v6.0.0'}, {'name': 'not-a-version'}], open(tags, 'w'))
    r = subprocess.run([NED, '--update'], env=env(PLACEHOLDER, NED_UPDATE_URL=tags, NED_UPDATE_HOW='termux'),
                       capture_output=True, text=True, timeout=60, input='n\n')
    out = r.stdout + r.stderr
    check('ned --update: a version only tagged — the newest tag, built with nimble on Termux, asked first',
          'ned 99.1.0 is out' in out and 'nimble install' in out and 'Nothing changed' in out and not installed(), out)
    release()
    code, out = ned_verify(PLACEHOLDER)
    check('ned --update --verify DIR: the files SHA256SUMS lists, checked', code == 0 and 'Checked ' + DEB in out, out)
    open(os.path.join(rel, DEB), 'ab').write(b'!')
    code, out = ned_verify(PLACEHOLDER, DEB)
    check('ned --update --verify DIR FILE: a changed file refused', code == 1 and 'Refused' in out, out)
    os.remove(os.path.join(rel, 'SHA256SUMS'))
    code, out = ned_verify(PLACEHOLDER)
    check('ned --update --verify: no SHA256SUMS in the folder', code == 1 and 'no SHA256SUMS' in out, out)

shutil.rmtree(root, ignore_errors=True)
if fails:
    print('%d failed' % len(fails))
    sys.exit(1)
print('all passed')

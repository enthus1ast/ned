#!/usr/bin/env python3
"""The Nim tour's lessons (tour/lesson*.nim) run as ned's notebook runs them, and checked:

- the first line is '# Nim tour · n of N · <title>', with n its place and N how many there are; the line
  '# notebook: compiled' comes before the first cell; no line is longer than 118 characters;
- every cell runs without an error, and prints what its `#>` lines say it prints (when it has them);
- the last cell is the exercise ('# %% Exercise: …'): the code to change, then '# Check:' and the code that says
  "✓ …" or "not yet …", then '# Answer:' and the answer as comment lines indented by two (ned folds them away).
  As it is given, the exercise runs and its check says "not yet"; with the answer in place of the code above
  '# Check:', the check says ✓;
- the whole lesson is a module the compiler takes (`nim check`): ned's engine, the ARC view and macro expansion
  read it as one;
- every lesson is in ned (staticRead in src/ned/editor/tourlessons.nim), in order, and only those.

A lesson runs as the notebook runs a file with '# notebook: compiled' (nbRunCompiled in src/ned/editor/notebook.nim):
the cells from the first to the last built as one program with a mark printed before and after each cell's code,
and each cell's output is what came between its marks.

  python3 tests/tour/check.py [--nim PATH] [-j N] [-v] [lesson …]     (a lesson: its number or its file's name)
"""
import concurrent.futures, os, re, shutil, subprocess, sys, tempfile, time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOUR = os.path.join(REPO, "tour")
LESSONS_NIM = os.path.join(REPO, "src", "ned", "editor", "tourlessons.nim")
MARK = "\x1e"
CELL_MARKS = ["# %%", "#%%", "## %%", "// %%", "//%%", "-- %%", "--%%"]      # (replMarker in term/repl.nim)
VERBOSE = False


def is_marker(line):
    s = line.lstrip()
    return any(s.startswith(m) for m in CELL_MARKS)


def cells_of(lines):
    """the cells: (first line, last line) — nbCells: what comes before the first marker is a cell when it has text"""
    out, start = [], 0
    for i, l in enumerate(lines):
        if is_marker(l):
            if i > start and (any(lines[k].strip() for k in range(start, i)) or out):
                out.append((start, i - 1))
            start = i + 1
    if start <= len(lines) - 1:
        out.append((start, len(lines) - 1))
    return out


def cell_code(lines, c):
    """nbCellCode: the cell's lines, tabs as four spaces, trailing blank lines left out"""
    ls = [lines[i].replace("\t", "    ") for i in range(c[0], c[1] + 1)]
    while ls and not ls[-1].strip():
        ls.pop()
    return "\n".join(ls)


def has_code(code):
    return any(l.strip() and not l.strip().startswith("#") for l in code.split("\n"))


def compiled_mode(lines):
    """'# notebook: compiled' above the first cell"""
    for l in lines:
        if is_marker(l):
            return False
        if l.strip() == "# notebook: compiled":
            return True
    return False


def run_compiled(path, codes, nim_env):
    """nbRunCompiled: every cell as one program; → (output lines per cell, the build's other lines, exit code)"""
    tmp = tempfile.mkdtemp(prefix="tour_nb_")
    try:
        src = ""
        for ci, code in enumerate(codes):
            src += 'echo "\\x1eB%d"\n' % ci
            for l in code.split("\n"):
                src += l + "\n"
            src += '\necho "\\x1eE%d"\n' % ci
        name = os.path.splitext(os.path.basename(path))[0]
        main = os.path.join(tmp, name + "_nb.nim")
        with open(main, "w", encoding="utf-8") as f:
            f.write(src)
        cmd = ["nim", "c", "-r", "--hints:off", "--warnings:off", "--path:" + os.path.dirname(path),
               "--nimcache:" + os.path.join(tmp, "nc"), "-o:" + os.path.join(tmp, "prog"), main]
        r = subprocess.run(cmd, cwd=os.path.dirname(path), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, env=nim_env, timeout=600)
        per = [[] for _ in codes]
        build = []
        cur = -1
        for raw in r.stdout.decode("utf-8", "replace").split("\n"):
            l = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
            if l.startswith(MARK + "B"):
                cur = int(l[2:].strip())
                continue
            if l.startswith(MARK + "E"):
                cur = -1
                continue
            if 0 <= cur < len(codes):
                per[cur].append(l)
            elif l.strip() and not l.startswith("CC:") and not l.startswith("Hint:"):
                build.append(l)
        return per, build, r.returncode
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def stopped(lines):
    """an output that says the program stopped (the compiled notebook shows it, but does not mark it as an error)"""
    return any(l.startswith("Error: unhandled exception") or "Traceback (most recent call last)" in l or
               l.startswith("SIGSEGV") for l in lines)


def expected_of(code):
    """the `#> …` lines of a cell: what it prints"""
    exp = []
    for l in code.split("\n"):
        s = l.strip()
        if s == "#>" or s.startswith("#> "):
            exp.append(s[3:] if len(s) > 2 else "")
    return exp


def exercise_parts(code):
    """the exercise's cell → (the code to change, the check, the answer) — None for a part it does not have"""
    ls = code.split("\n")
    ck = next((i for i, l in enumerate(ls) if l.rstrip() == "# Check:"), None)
    an = next((i for i, l in enumerate(ls) if l.rstrip() == "# Answer:"), None)
    if ck is None or an is None or an < ck:
        return None, None, None
    ans = []
    for a in ls[an + 1:]:
        if a.startswith("  # "):
            ans.append(a[4:])
        elif a.rstrip() == "  #":
            ans.append("")
        elif a.strip():
            return "\n".join(ls[:ck]), "\n".join(ls[ck:an]), None     # (a line of the answer not commented out)
    return "\n".join(ls[:ck]), "\n".join(ls[ck:an]), "\n".join(ans).rstrip("\n") or None


def says(out, what):
    return any(what in l for l in out)


def check_lesson(path, nim_env, number, total):
    problems = []
    name = os.path.basename(path)
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    head = re.match(r"# Nim tour · (\d+) of (\d+) · \S", lines[0] if lines else "")
    if not head or int(head.group(1)) != number or int(head.group(2)) != total:
        problems.append("its first line is not '# Nim tour · %d of %d · <title>'" % (number, total))
    if not compiled_mode(lines):
        problems.append("no line '# notebook: compiled' before the first cell")
    for i, l in enumerate(lines):
        if len(l) > 118:
            problems.append("line %d is longer than 118 characters" % (i + 1))
        if "\t" in l:
            problems.append("line %d has a tab" % (i + 1))
    cells = cells_of(lines)
    codes = [cell_code(lines, c) for c in cells]
    exercises = [ci for ci, c in enumerate(cells) if c[0] > 0 and lines[c[0] - 1].startswith("# %% Exercise: ")]
    if len(exercises) != 1:
        problems.append("%d exercises (one, the last cell: '# %%%% Exercise: …')" % len(exercises))
    elif exercises[0] != len(cells) - 1:
        problems.append("the exercise is not the last cell")
    per, build, rc = run_compiled(path, codes, nim_env)
    n_code = 0
    for ci, c in enumerate(cells):
        if not has_code(codes[ci]):
            continue
        n_code += 1
        out = per[ci]
        where = "cell %d (line %d)" % (ci, c[0] + 1)
        if stopped(out):
            problems.append(where + " stops the program:\n      " + "\n      ".join(out[-25:]))
            continue
        exp = expected_of(codes[ci])
        if exp and [l.rstrip() for l in out] != exp:
            problems.append(where + " prints\n      " + "\n      ".join(out) + "\n    not\n      " +
                            "\n      ".join(exp))
        if VERBOSE:
            print("  %s: %d lines" % (where, len(out)))
    if rc != 0:
        problems.append("the lesson does not build and run:\n      " + "\n      ".join(build[-25:]))
    if exercises and rc == 0:
        ci = exercises[0]
        work, check, ans = exercise_parts(codes[ci])
        if check is None or ans is None:
            problems.append("the exercise needs '# Check:' then '# Answer:' and the answer as lines '  # …'")
        else:
            if not says(per[ci], "not yet") or says(per[ci], "✓"):
                problems.append("the exercise as it is given should say 'not yet', not ✓:\n      " +
                                "\n      ".join(per[ci][-10:]))
            codes2 = list(codes)
            codes2[ci] = ans + "\n" + check
            per2, build2, rc2 = run_compiled(path, codes2, nim_env)
            out = per2[ci]
            if rc2 != 0 or stopped(out) or says(out, "not yet") or not says(out, "✓"):
                problems.append("the exercise's answer does not pass:\n      " + "\n      ".join((out + build2)[-25:]))
            elif VERBOSE:
                print("  the answer: " + " / ".join(out))
    r = subprocess.run(["nim", "check", "--hints:off", "--warnings:off", name], cwd=os.path.dirname(path),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=nim_env)
    if r.returncode != 0:
        problems.append("nim check fails:\n      " + "\n      ".join(r.stdout.decode().strip().split("\n")[-10:]))
    return problems, n_code


def embedded():
    """the lessons in ned, in their order"""
    with open(LESSONS_NIM, encoding="utf-8") as f:
        return re.findall(r'staticRead\("\.\./\.\./\.\./tour/([^"]+)"\)', f.read())


def main():
    global VERBOSE
    args = sys.argv[1:]
    nim = shutil.which("nim") or "nim"
    jobs = 4
    if "--nim" in args:
        i = args.index("--nim")
        nim = args[i + 1]
        del args[i:i + 2]
    if "-j" in args:
        i = args.index("-j")
        jobs = max(1, int(args[i + 1]))
        del args[i:i + 2]
    if "-v" in args:
        VERBOSE = True
        args.remove("-v")
    env = dict(os.environ)
    env["PATH"] = os.path.dirname(os.path.abspath(shutil.which(nim) or nim)) + os.pathsep + env.get("PATH", "")
    lessons = sorted(f for f in os.listdir(TOUR) if f.endswith(".nim"))
    failures = 0
    for f in lessons:
        if not re.fullmatch(r"lesson\d\d_[a-z0-9]+\.nim", f):
            print("✗ %s: a lesson's name is lessonNN_word.nim (a Nim module's name, in order)" % f)
            failures += 1
    emb = embedded()
    if emb != lessons:
        print("✗ the lessons in src/ned/editor/tourlessons.nim are not those of tour/, in order:\n    %s\n    %s" %
              (emb, lessons))
        failures += 1
    todo = [(n, f) for n, f in enumerate(lessons, 1)
            if not args or any(a == f or a == f[:-4] or a.zfill(2) == f[6:8] for a in args)]

    def one(nf):
        n, f = nf
        t0 = time.time()
        problems, cells = check_lesson(os.path.join(TOUR, f), env, n, len(lessons))
        return f, problems, cells, time.time() - t0

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        for f, problems, cells, took in ex.map(one, todo):
            if problems:
                failures += 1
                print("✗ %s (%.1f s)" % (f, took))
                for p in problems:
                    print("    " + p)
            else:
                print("✓ %s — %d cells (%.1f s)" % (f, cells, took))
    print("all the lessons pass" if failures == 0 else "%d failed" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()

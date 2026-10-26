"""latex: the language (colours, comments, indentation, F5 with latexmk or pdflatex, on the main file a
`% !TEX root` names), its snippets, the outline without texlab, texlab and latexindent when they are installed, the
settings — and BibTeX (.bib: its colours, snippets, outline and texlab)"""
import os, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language, done, fake_tools, ned_cmd, start
from tplugins import check

SAMPLE = r'''% !TEX program = pdflatex
\documentclass{article}
\usepackage{amsmath}
\newcommand{\R}{\mathbb{R}}
\DeclareMathOperator{\sgn}{sgn}
\newenvironment{note}{\begin{quote}}{\end{quote}}

\begin{document}
% \section{Not this}
\section{Introduction}
Some text with 50\% and $x^2$. % \section{nor this}
\subsection*{Background}
\begin{verbatim}
\section{Not in verbatim}
\end{verbatim}
\subsection[Short]{A {nested} title}\label{sec:nested}
\section{Results}
\paragraph{Detail}
\end{document}'''.split("\n")

BIB = '''% a comment: @article{notThis,
@string{jcp = "Journal of Computational Physics"}

@article{knuth1984,
  author  = {Donald E. Knuth},
  title   = {Literate Programming},
  journal = jcp,
}

@book{ lamport1994,
  title = "LaTeX: A Document Preparation System",
}
@comment{ignored}'''.split("\n")

LATEXMK = "latexmk -pdf -interaction=nonstopmode -file-line-error "


def run(factory, tag):
    check_language(
        factory, tag, "latex",
        {"name": "LaTeX", "extensions": ["tex", "sty", "cls", "ltx"], "lineComment": "%", "quotes": "$",
         "tabs": True, "dedent": "}]", "pairs": "{}[]()$$",
         "keywords": {"documentclass", "usepackage", "newcommand", "renewcommand", "textbf", "emph", "frac"},
         "functionWords": {"newcommand", "renewcommand", "DeclareMathOperator"},
         "classWords": {"newenvironment"}},
        ["doc", "begin", "sec", "itemize", "figure", "table", "eq", "frame"],
        SAMPLE,
        [("\\R", "function", 0), ("\\sgn", "function", 0), ("note", "class", 0), ("Introduction", "heading", 0),
         ("Background", "heading", 1), ("A {nested} title", "heading", 1), ("Results", "heading", 0),
         ("Detail", "heading", 2)],
        ["latexmk", "pdflatex", "texlab", "latexindent"],
        runs=[("paper.tex", "\\documentclass{article}\n", {}, LATEXMK + "paper.tex"),
              ("chapters/intro.tex", "% !TeX root = ../main.tex\n\\section{Intro}\n",
               {"main.tex": "\\documentclass{book}\n"}, LATEXMK + "main.tex")],
        server=["texlab"], formatter="latexindent -g /dev/null")

    tmp = tempfile.mkdtemp(prefix="ned-latex-")
    try:
        h, ok, err = start(factory, [os.path.join(tmp, "none")], only_path=True)
        bs = (h.reg("language", id="bibtex") or {}).get("spec", {}) if ok else {}
        run_cmd = (h.reg("language", id="latex") or {}).get("spec", {}).get("run", "") if ok else ""
        trig = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == "bibtex"}
        check(tag + "BibTeX: .bib, % comments, @entries coloured; its snippets (article, book, misc)",
              bs.get("extensions") == ["bib"] and bs.get("name") == "BibTeX" and bs.get("lineComment") == "%" and
              bs.get("decorators") is True and trig == {"article", "book", "misc"}, (bs, trig))
        r = h.reg("symbols", lang="bibtex")
        got = []
        if r:
            h.lines = BIB
            got = [(s["name"], s["kind"], s["detail"]) for s in (h.call(r["cb"], {"buf": 1}) or {}).get("value") or []]
        check(tag + "the outline of a .bib: its @strings and its entries by their keys (no @comment)",
              got == [("jcp", "constant", "string"), ("knuth1984", "struct", "article"),
                      ("lamport1994", "struct", "book")], got)
        done(h)
        fake = os.path.join(tmp, "bin")
        fake_tools(fake, ["texlab", "latexindent.pl", "pdflatex"])
        h, ok, err = start(factory, [fake], only_path=True)
        lb = h.reg("lsp", lang="bibtex") if ok else None
        fm = h.reg("formatter", lang="latex") if ok else None
        check(tag + "texlab for .bib files too (no outline of the plugin's); latexindent.pl when there is no "
              "latexindent", ok and lb and lb["cmd"] == ["texlab"] and h.reg("symbols", lang="bibtex") is None and
              fm and fm.get("cmd") == "latexindent.pl -g /dev/null", (err, lb, fm))
        done(h)
        # F5 without latexmk: pdflatex in the file's folder (a PATH with the shell's tools only, no latexmk)
        sysbin = os.path.join(tmp, "sysbin")
        os.makedirs(sysbin)
        for tool in ("sh", "sed", "head", "dirname", "basename"):
            src = shutil.which(tool)
            if src:
                os.symlink(src, os.path.join(sysbin, tool))
        f = os.path.join(tmp, "doc", "paper.tex")
        os.makedirs(os.path.dirname(f))
        open(f, "w").write("\\documentclass{article}\n")
        p = subprocess.run([os.path.join(sysbin, "sh"), "-c", ned_cmd(run_cmd, f, "/T")], cwd=os.path.dirname(f),
                           capture_output=True, text=True, env=dict(os.environ, PATH=fake + os.pathsep + sysbin),
                           timeout=30)
        o = p.stdout + p.stderr
        check(tag + "F5 without latexmk: pdflatex on the file, in its folder",
              o.startswith("pdflatex -interaction=nonstopmode -file-line-error paper.tex\nin %s\n"
                           % os.path.dirname(f)), o)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

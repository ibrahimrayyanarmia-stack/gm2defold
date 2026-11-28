"""Command line front end for the GML parser.

    python3 -m gml FILE_OR_DIR...          parse, report errors (exit status 1 if any)
    python3 -m gml --dump FILE...          also print the AST of each file
    python3 -m gml --tokens FILE...        print the token stream

Directories are searched recursively for *.gml. Macros from every file given are collected
first, as GameMaker does for a whole project.
"""
import argparse, os, sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    __package__ = "gml"

from gml import tokenize, parse, collect_macros, dump


def gml_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, files in os.walk(p):
                dirs.sort()
                for f in sorted(files):
                    if f.endswith(".gml"):
                        yield os.path.join(root, f)
        else:
            yield p


def read(path):
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        return f.read()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python3 -m gml", description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--dump", action="store_true", help="print the AST")
    ap.add_argument("--tokens", action="store_true", help="print tokens")
    ap.add_argument("-q", "--quiet", action="store_true", help="only print the summary")
    a = ap.parse_args(argv)

    files = list(gml_files(a.paths))
    sources = {f: read(f) for f in files}
    macros = {}
    for f in files:
        macros.update(collect_macros(sources[f]))

    nerr = nstmt = nlines = 0
    for f in files:
        src = sources[f]
        nlines += src.count("\n") + 1
        if a.tokens:
            toks, _ = tokenize(src)
            for t in toks:
                print(f"{t.line}:{t.col}\t{t.type}\t{t.value!r}")
        prog = parse(src, filename=f, macros=macros)
        nstmt += sum(1 for n in prog.walk() if n is not prog)
        if a.dump:
            print(f"== {f}")
            for s in prog.body:
                print(dump(s))
        for e in prog.errors:
            nerr += 1
            if not a.quiet:
                print(e)
    print(f"{len(files)} files, {nlines} lines, {nstmt} nodes, {len(macros)} macros, "
          f"{nerr} errors", file=sys.stderr)
    return 1 if nerr else 0


if __name__ == "__main__":
    sys.exit(main())

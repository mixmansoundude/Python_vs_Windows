"""dep_merge (Item 89): merge requirements.txt, pyproject and PEP 723 dependency lists; see README REQ-005.1.
Runs in the app folder on fixed file names (FILE, BASE: snapshots from the last good run).
Exit 0 done, 1 nothing to do, 3 error. Rank on conflict: header, pyproject, requirements.txt.
"""
import os
import re
import sys

RANK = ("pep723", "pyproject", "req")
LABEL = {"pep723": "the PEP 723 header", "pyproject": "pyproject.toml", "req": "requirements.txt"}
FILE = {"req": "requirements.txt", "pyproject": "~requirements.pyproject.txt", "pep723": "~requirements.pep723.txt"}
BASE = {"req": "~dep_base.requirements.txt", "pyproject": "~dep_base.pyproject.txt", "pep723": "~dep_base.pep723.txt"}
NAME = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?")


def read(path):
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return None


def parse(lines):
    """Return ({key: (text, signature)}, [lines that name no package]), or (None, []) for a missing or empty file."""
    if lines is None:
        return None, []
    got, extra = {}, []
    for raw in lines:
        s = re.sub(r"\s+#.*$", "", raw.strip())
        if not s or s[0] == "#":
            continue
        m = NAME.match(s)
        if s[0] == "-" or not m or (s[m.end():m.end() + 1] and s[m.end()] not in " \t[(<>=!~;@,"):
            extra.append(s)
            continue
        key = re.sub(r"[-_.]+", "-", m.group()).lower()
        rest = re.sub(r"\s+", "", s[m.end():]).lower()
        if rest and ";" not in rest and "@" not in rest:
            rest = ",".join(sorted(rest.split(",")))
        got.setdefault(key, (s, key + rest))
    return (got, extra) if got or extra else (None, [])


def merge(cur, base):
    """cur, base: {source: parsed dict or None}. Return (merged {key: text}, dropped keys, report lines)."""
    out, report, dropped, gone = {}, [], [], {}
    for s in RANK:
        if cur[s] is not None and base[s] is not None:
            for k in base[s]:
                if k not in cur[s]:
                    gone.setdefault(k, []).append(s)

    def fresh(s, k):  # new or edited since the last run, so not a leftover of what we wrote
        return base[s] is None or k not in base[s] or base[s][k][1] != cur[s][k][1]

    def said(srcs):
        return " and ".join(LABEL[s] for s in srcs)

    names = []
    for s in ("req", "pyproject", "pep723"):
        names += [k for k in (cur[s] or {}) if k not in names]
    for k in names:
        have = [s for s in RANK if cur[s] and k in cur[s]]
        new = [s for s in have if fresh(s, k)]
        live = [s for s in have if s == "pyproject" or s in new]  # pyproject.toml is never rewritten by us
        if k in gone and not live:
            dropped.append(k)
            report.append("[INFO] Removed %s: you removed it from %s since the last run, so it is removed everywhere."
                          % (k, said(gone[k])))
            continue
        if k in gone:
            report.append("[WARN] %s was removed from %s but %s still lists it, so it stays. Remove it there too."
                          % (k, said(gone[k]), said(live)))
        pool = new or have
        pool = [s for s in pool if cur[s][k][1] != k] or pool  # a bare name never beats a constrained entry
        win = pool[0]
        if len({cur[s][k][1] for s in pool}) > 1:
            report.append("[WARN] Conflict for %s: %s; using %s from %s, which ranks highest. Edit it there to change it."
                          % (k, ", ".join('%s says "%s"' % (LABEL[s], cur[s][k][0]) for s in pool),
                             cur[win][k][0], LABEL[win]))
        out[k] = cur[win][k][0]
    return out, dropped, report


def main():
    cur, base, extras = {}, {}, []
    for s in RANK:
        cur[s], more = parse(read(FILE[s]))
        base[s] = parse(read(BASE[s]))[0]
        if s == "req":
            extras = more
    here = [s for s in RANK if cur[s] is not None]
    later = any(base[s] is not None for s in RANK)
    if not here or (len(here) < 2 and not later):
        return 1
    out, dropped, report = merge(cur, base)
    # changed: a list differs from, or has no, snapshot, so the install must not be skipped as already satisfied
    changed = any(base[s] is None or {k: v[1] for k, v in cur[s].items()} != {k: v[1] for k, v in base[s].items()}
                  for s in here)
    kept = list(out.values()) + [e for e in extras if e not in out.values()]
    parts = ["%s %d" % (LABEL[s], len(cur[s])) for s in here]
    if len(here) > 1:
        report.insert(0, "[INFO] Dependency lists merged: %s; %d packages." % (", ".join(parts), len(out)))
    header = cur["pep723"] or {}
    tmp = "~requirements.merge.tmp"
    if here != ["req"]:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write("\n".join(kept) + "\n")
        os.replace(tmp, FILE["req"])
    with open("~dep_merge.removed.txt", "w", encoding="ascii") as fh:
        fh.write("".join(k + "\n" for k in dropped if k in header))
    with open("~dep_merge.report.txt", "w", encoding="ascii") as fh:
        for ln in report[:30]:
            fh.write(ln.encode("ascii", "replace").decode()[:300] + "\n")
    if changed:
        open("~dep_merge.changed.txt", "w").close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # derived requirement: a failing merge must never stop the run
        sys.stderr.write("dep_merge: %s\n" % str(exc).encode("ascii", "replace").decode())
        sys.exit(3)

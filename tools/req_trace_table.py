#!/usr/bin/env python3
"""Requirement-to-row trace table: which numbered shall of the README has an NDJSON row that names it.

Reads README.md (the numbered shalls, `- **REQ-nnn.m** [major] ... **shall** ...`) and the `req = '...'` tags
of tests/*.ps1 and .github/workflows/batch-check.yml, then prints a markdown table (one line per requirement
number that has numbered shalls) and the list of shalls no row names. Run it from the repository root:

    python tools/req_trace_table.py

docs/plan-test-suite-gaps.md keeps a dated copy of the output as its status table; regenerate it with this
tool instead of editing the numbers by hand. The association of a tag with a row id is the first
`id = '...'` inside the same ordered hashtable (from the `@{` above the tag to the `})` below it), which is
right for every row written in the repository's usual shape and a hint, not a proof, for any other.
tests/test_req_trace.py is the gate (a tag must name a shall that exists); this tool only reports.

The last column counts the rows (or workflow steps, when no id sits near the tag) tagged `REQ-nnn` with no
sub-id: they show the requirement is exercised but do not say which shall, and moving such a tag to the
sub-id it verifies is a tag-only change.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent

SHALL_LINE = re.compile(r"^\s*- \*\*REQ-(\d{3}[a-z]?)\.(\d+(?:\.\d+)*)\*\*(.*)$", re.MULTILINE)
TAG = re.compile(r"""\breq\s*=\s*['"]([^'"\r\n]+)['"]""")
ROW_ID = re.compile(r"""\bid\s*=\s*['"]([A-Za-z0-9][A-Za-z0-9_.-]*)['"]""")
WINDOW = 6  # lines searched around a tag for its row id


def readme_shalls(readme_text: str) -> Tuple[Dict[str, List[str]], List[str]]:
    """Return (shalls, without): shalls maps a requirement number to its numbered shall ids in README order
    (every `- **REQ-nnn.m**` line that says shall, wherever it sits, so the REQ-009 shalls inside the REQ-003
    section count under REQ-009); without lists the numbers the README mentions that have none."""
    shalls: Dict[str, List[str]] = {}
    for m in SHALL_LINE.finditer(readme_text):
        if "shall" in m.group(3):
            shalls.setdefault(m.group(1), []).append("REQ-%s.%s" % (m.group(1), m.group(2)))
    mentioned = set(re.findall(r"REQ-(\d{3}[a-z]?)", readme_text))
    return shalls, sorted(mentioned - set(shalls))


def row_tags(texts: Iterable[str]) -> Dict[str, Set[str]]:
    """Map each `req` tag to the row ids that carry it (`?` when no id sits in the tag's row)."""
    tags: Dict[str, Set[str]] = {}
    for text in texts:
        lines = text.splitlines()
        for i, line in enumerate(lines):
            m = TAG.search(line)
            if not m:
                continue
            # The row is the ordered hashtable around the tag: from the nearest `@{` above it to the nearest `})`
            # below it, so an id belonging to the previous or the next row is never picked up.
            # The tag's own line comes first: a row written on one line holds its id beside its tag.
            lo = i
            while lo > max(i - WINDOW, 0) and "@{" not in lines[lo]:
                lo -= 1
            hi = i
            while hi < min(i + WINDOW, len(lines) - 1) and not lines[hi].lstrip().startswith("})"):
                hi += 1
            row = "?"
            for j in [i] + list(range(i - 1, lo - 1, -1)) + list(range(i + 1, hi + 1)):
                found = ROW_ID.search(lines[j])
                if found:
                    row = found.group(1)
                    break
            tags.setdefault(m.group(1), set()).add(row)
    return tags


def build_report(readme_text: str, tag_texts: Iterable[str]) -> str:
    shalls_by_num, without = readme_shalls(readme_text)
    tags = row_tags(tag_texts)
    out: List[str] = []
    out.append("| Requirement | Shalls | Named by a row | Not named | Rows tagged with the number only |")
    out.append("|---|---|---|---|---|")
    missing: List[str] = []
    total = covered = 0
    for num in sorted(shalls_by_num):
        shalls = shalls_by_num[num]
        named = [s for s in shalls if s in tags]
        gap = [s for s in shalls if s not in tags]
        total += len(shalls)
        covered += len(named)
        missing.extend(gap)
        out.append("| REQ-%s | %d | %d | %d | %d |" % (num, len(shalls), len(named), len(gap), len(tags.get("REQ-" + num, ()))))
    out.append("")
    out.append("%d of %d numbered shalls are named by at least one row tag." % (covered, total))
    out.append("")
    out.append("Shalls no row names: " + (", ".join(missing) if missing else "none") + ".")
    out.append("")
    out.append("Requirement numbers the README mentions that have no numbered shall yet: " + (", ".join("REQ-" + n for n in without) or "none") + ".")
    return "\n".join(out) + "\n"


def repo_tag_texts(root: Path = REPO_ROOT) -> List[str]:
    paths = [p for p in sorted((root / "tests").glob("*.ps1")) if not p.name.startswith("~")]
    paths.append(root / ".github" / "workflows" / "batch-check.yml")
    return [p.read_text(encoding="utf-8", errors="replace") for p in paths if p.exists()]


def main(argv: List[str]) -> int:
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8", errors="replace")
    sys.stdout.write(build_report(readme, repo_tag_texts()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

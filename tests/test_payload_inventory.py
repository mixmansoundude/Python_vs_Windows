"""README's embedded-payload inventory paragraph must match run_setup.bat.

README.md ("Payload inventory and PayloadSync coverage") says how many `HP_*` helper payloads the batch file embeds,
how many of them have a canonical source file under tools/, and how many of those are Python and PowerShell. The
paragraph was kept by hand and had drifted twice (21 stated, 29 canonical-source payloads in the file), so this test
recounts from the file: a payload is a `set "HP_NAME=<base64>"` line whose value decodes to bytes; it has a canonical
source when a file under tools/ holds exactly those bytes (line endings ignored, like the PayloadSync tests).

The counting and the comparison are pure functions, and the synthetic cases at the end prove each rule can fail.
"""
from __future__ import annotations

import base64
import binascii
import re
import unittest
from pathlib import Path
from typing import Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent

# A payload line: the name, then base64 of at least 60 characters (the shorter HP_* values are not payloads).
PAYLOAD_LINE = re.compile(r'^\s*set "(HP_[A-Z0-9_]+)=([A-Za-z0-9+/]{60,}={0,2})"\s*$', re.MULTILINE)
# Constants that happen to look like base64 (a SHA256 in hex) and are not payloads.
NOT_PAYLOADS_PREFIX = ("HP_EMBED_LATEST_",)

CLAIM = re.compile(
    r"Of\s+the\s+(\d+)\s+embedded\s+`HP_\*`\s+payloads,\s+(\d+)\s+have\s+a\s+canonical\s+`tools/`\s+source\s+file\s+"
    r"\((\d+)\s+Python,\s+(\d+)\s+PowerShell\)"
)


def _norm(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n")


def embedded_payloads(bat_text: str) -> Dict[str, bytes]:
    """Name -> decoded bytes for every payload line of the batch text."""
    found: Dict[str, bytes] = {}
    for name, b64 in PAYLOAD_LINE.findall(bat_text):
        if name.startswith(NOT_PAYLOADS_PREFIX):
            continue
        try:
            found[name] = base64.b64decode(b64, validate=True)
        except (binascii.Error, ValueError):
            continue
    return found


def count_inventory(payloads: Dict[str, bytes], tools: Dict[str, bytes]) -> Tuple[int, int, int, int]:
    """(payloads, with a canonical source, of those Python, of those PowerShell). `tools` maps a file name to bytes."""
    by_content: Dict[bytes, List[str]] = {}
    for fname, data in tools.items():
        by_content.setdefault(_norm(data), []).append(fname)
    with_source = python = powershell = 0
    for data in payloads.values():
        names = by_content.get(_norm(data))
        if not names:
            continue
        with_source += 1
        if any(n.endswith(".py") for n in names):
            python += 1
        elif any(n.endswith(".ps1") for n in names):
            powershell += 1
    return len(payloads), with_source, python, powershell


def inventory_problems(readme_text: str, counted: Tuple[int, int, int, int]) -> List[str]:
    m = CLAIM.search(readme_text)
    if not m:
        return ["README has no sentence of the form 'Of the N embedded `HP_*` payloads, M have a canonical `tools/` source file (P Python, S PowerShell)'"]
    stated = tuple(int(x) for x in m.groups())
    if stated != counted:
        return [
            "README states %d payloads, %d with a canonical source (%d Python, %d PowerShell); run_setup.bat has %d, %d (%d, %d)"
            % (stated + counted)
        ]
    return []


def _repo_tools() -> Dict[str, bytes]:
    return {p.name: p.read_bytes() for p in (REPO_ROOT / "tools").iterdir() if p.is_file()}


class RepositoryInventory(unittest.TestCase):
    def test_readme_inventory_matches_the_batch_file(self) -> None:
        bat = (REPO_ROOT / "run_setup.bat").read_bytes().decode("latin-1")
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8", errors="replace")
        counted = count_inventory(embedded_payloads(bat), _repo_tools())
        self.assertEqual(inventory_problems(readme, counted), [])

    def test_the_two_embedded_only_payloads_are_the_ones_the_readme_names(self) -> None:
        bat = (REPO_ROOT / "run_setup.bat").read_bytes().decode("latin-1")
        payloads = embedded_payloads(bat)
        tools = {_norm(v) for v in _repo_tools().values()}
        embedded_only = sorted(n for n, d in payloads.items() if _norm(d) not in tools)
        self.assertEqual(embedded_only, ["HP_CONDARC", "HP_PRINT_PYVER"])


class SyntheticCases(unittest.TestCase):
    """Each rule above can fail."""

    @staticmethod
    def _line(name: str, data: bytes) -> str:
        return 'set "%s=%s"\r\n' % (name, base64.b64encode(data).decode("ascii"))

    def test_a_payload_line_is_found_and_decoded(self) -> None:
        text = self._line("HP_ONE", b"print('one')\n" * 10) + 'set "HP_SHORT=abcd"\r\n'
        self.assertEqual(list(embedded_payloads(text)), ["HP_ONE"])

    def test_a_hex_constant_is_not_a_payload(self) -> None:
        text = 'set "HP_EMBED_LATEST_SHA256=%s"\r\n' % ("ab" * 32 + "cd" * 8)
        self.assertEqual(embedded_payloads(text), {})

    def test_counting_splits_python_powershell_and_embedded_only(self) -> None:
        py = b"import sys\n" * 10
        ps = b"Write-Output 'x'\r\n" * 10
        only = b"channels:\n  - conda-forge\n" * 5
        payloads = {"HP_PY": py, "HP_PS": ps, "HP_ONLY": only}
        tools = {"a.py": py.replace(b"\n", b"\r\n"), "b.ps1": ps}
        self.assertEqual(count_inventory(payloads, tools), (3, 2, 1, 1))

    def test_a_miscount_in_the_readme_is_reported(self) -> None:
        text = "Of the 21 embedded `HP_*` payloads, 18 have a canonical `tools/`\nsource file (13 Python, 5 PowerShell) and"
        problems = inventory_problems(text, (31, 29, 21, 8))
        self.assertEqual(len(problems), 1)
        self.assertIn("README states 21 payloads", problems[0])

    def test_a_matching_readme_passes_across_line_breaks(self) -> None:
        text = "Of the 31 embedded `HP_*` payloads, 29 have a canonical `tools/`\nsource file (21 Python,\n8 PowerShell) and"
        self.assertEqual(inventory_problems(text, (31, 29, 21, 8)), [])

    def test_a_readme_without_the_sentence_is_reported(self) -> None:
        self.assertEqual(len(inventory_problems("nothing here", (1, 1, 1, 0))), 1)


if __name__ == "__main__":
    unittest.main()

"""Item 93: the transient-failure phrases of the two conda retry sites, and the harness that exercises them.

Field evidence (run 41074512594): conda's sharded repodata path crashed with
    requests.exceptions.HTTPError: 502 Server Error: Bad Gateway for url: https://conda.anaconda.org/...msgpack.zst
and that text holds none of the four phrases run_setup.bat searched for (CondaHTTPError, Failed to fetch, timed out,
ConnectionError), so neither the conda bulk install (REQ-005.2, `:conda_bulk_install`) nor the conda create flow
(REQ-022.1, `:conda_create_check_transient`) waited and retried.

The two sites each carry their own `findstr /i /c:"..." ...` line on purpose (each reads its own temp file), so this file
keeps them equal and checks them against real conda text with findstr's rules: `/i` is case blind, each `/c:` is a literal
substring, several `/c:` strings are OR. It also pins what `tests/selfapps_conda_transient.ps1` relies on: the labels it cuts
the two blocks at, the only names those blocks reach outside themselves (its driver defines them), and the workflow
step. The Windows behavior itself (a stub conda that prints the 502, counted calls) is that script's `self.conda.retry5xx.*`
rows. Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

from tools import check_ndjson_registry

REPO = Path(__file__).resolve().parent.parent
BAT = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_conda_transient.ps1"
WORKFLOW = REPO / ".github" / "workflows" / "batch-check.yml"

ORIGINAL_PHRASES = ("CondaHTTPError", "Failed to fetch", "timed out", "ConnectionError")
NEW_PHRASE = "Server Error"
ROW_IDS = (
    "self.conda.retry5xx.control",
    "self.conda.retry5xx.bulk",
    "self.conda.retry5xx.create",
    "self.conda.retry5xx.bounded",
    "self.conda.retry5xx.nonretry",
)
STEP_NAME = "Self-test: conda 5xx retry (real and justme-test)"

BULK_START, BULK_END = ":conda_bulk_install", ":try_nuitka_tier_a"
CREATE_START, CREATE_END = ":conda_create_check_transient", ":conda_create_failed"
# Names the cut-out blocks may reach outside themselves; the script's driver defines every one of them.
EXTERNAL_LABELS = {":log", ":conda_create_done", ":conda_create_failed"}
KNOWN_VARIABLES = {
    "LOG", "CONDA_BAT", "ENVNAME", "ERRORLEVEL",
    "HP_CBULK_RC", "HP_TEST_FORCE_CONDA_BULK_FAIL", "HP_TEST_FORCE_CONDA_NETWORK_FAIL",
    "HP_CCREATE_RC", "HP_CCREATE_TRANSIENT_RC", "HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL",
    "HP_CONDA_PYSPEC_SKIP", "HP_CONDA_PYSPEC_USE",
}

# Real text. The first is the last line of the crash in run 41074512594.
RETRIED = (
    "requests.exceptions.HTTPError: 502 Server Error: Bad Gateway for url: "
    "https://conda.anaconda.org/conda-forge/win-64/ce81bff8e89d422c0e4ef1ac471cc77422695c84a7d589c446d1e1a1d5ad2b7b.msgpack.zst",
    "requests.exceptions.HTTPError: 503 Server Error: Service Unavailable for url: https://conda.anaconda.org/conda-forge/noarch/repodata.json",
    "CondaHTTPError: HTTP 000 CONNECTION FAILED for url <https://conda.anaconda.org/conda-forge/win-64/current_repodata.json>",
    "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='conda.anaconda.org', port=443): Max retries exceeded",
    "requests.exceptions.ReadTimeout: HTTPSConnectionPool(host='conda.anaconda.org', port=443): Read timed out.",
    "Failed to fetch https://conda.anaconda.org/conda-forge/win-64/repodata.json",
)
NOT_RETRIED = (
    "PackagesNotFoundError: The following packages are not available from current channels:",
    "UnsatisfiableError: The following specifications were found to be incompatible with each other:",
    "requests.exceptions.HTTPError: 404 Client Error: Not Found for url: https://conda.anaconda.org/conda-forge/win-64/x.msgpack.zst",
)

FINDSTR = re.compile(r'^\s*findstr\s+/i\s+((?:/c:"[^"]*"\s*)+)"(~conda_(?:create|bulk)\.tmp)"', re.M)


def _bat():
    return BAT.read_text(encoding="utf-8", errors="replace")


def phrase_lines(text):
    """{temp file name: [phrases]} for each findstr line that searches a conda temp file."""
    found = {}
    for m in FINDSTR.finditer(text):
        found[m.group(2)] = re.findall(r'/c:"([^"]*)"', m.group(1))
    return found


def findstr_matches(phrases, line):
    """findstr /i with several /c: strings: a line matches when it holds any of them, case blind."""
    low = line.lower()
    return any(p.lower() in low for p in phrases)


def cut_block(text, start, end):
    lines = text.splitlines()
    s = next((i for i, l in enumerate(lines) if l.strip() == start), None)
    if s is None:
        return None
    e = next((j for j in range(s + 1, len(lines)) if lines[j].strip() == end), None)
    if e is None:
        return None
    return lines[s:e]


def block_problems(block, internal_ok=True):
    """What a cut-out block reaches outside itself; empty means the driver defines everything it needs."""
    found = []
    labels = {l.strip() for l in block if l.strip().startswith(":") and not l.strip().startswith("::")}
    for l in block:
        s = l.strip()
        if s.lower().startswith("rem "):
            continue
        for m in re.finditer(r"(?:goto|call)\s+(:[A-Za-z0-9_]+)", s, re.I):
            target = m.group(1)
            if target not in labels and target not in EXTERNAL_LABELS:
                found.append("reaches %s, which the driver does not define" % target)
        for v in re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)%", s):
            if v not in KNOWN_VARIABLES:
                found.append("uses %%%s%%, which the driver does not set" % v)
    return found


def site_problems(text):
    found = []
    lines = phrase_lines(text)
    for name in ("~conda_create.tmp", "~conda_bulk.tmp"):
        if name not in lines:
            found.append("no findstr line searches %s" % name)
    if len(lines) == 2:
        a, b = lines["~conda_create.tmp"], lines["~conda_bulk.tmp"]
        if a != b:
            found.append("the two sites search different phrases: %r vs %r" % (a, b))
    for name, phrases in lines.items():
        for p in ORIGINAL_PHRASES + (NEW_PHRASE,):
            if p not in phrases:
                found.append("%s does not search for %r" % (name, p))
    return found


class Phrases(unittest.TestCase):
    def test_both_sites_search_the_same_phrases_including_server_error(self):
        self.assertEqual(site_problems(_bat()), [])

    def test_real_conda_text_is_classified_right(self):
        phrases = phrase_lines(_bat()).get("~conda_bulk.tmp", [])
        for line in RETRIED:
            self.assertTrue(findstr_matches(phrases, line), "should be retried: " + line)
        for line in NOT_RETRIED:
            self.assertFalse(findstr_matches(phrases, line), "must not be retried: " + line)


class HarnessContract(unittest.TestCase):
    def test_bulk_block_is_cut_and_self_contained(self):
        block = cut_block(_bat(), BULK_START, BULK_END)
        self.assertIsNotNone(block, "labels %s ... %s moved; update selfapps_conda_transient.ps1" % (BULK_START, BULK_END))
        self.assertEqual(block_problems(block), [])
        text = "\n".join(block)
        self.assertIn("timeout /t 15", text)
        self.assertEqual(text.count('call "%CONDA_BAT%" install'), 2)

    def test_create_block_is_cut_and_self_contained(self):
        block = cut_block(_bat(), CREATE_START, CREATE_END)
        self.assertIsNotNone(block, "labels %s ... %s moved; update selfapps_conda_transient.ps1" % (CREATE_START, CREATE_END))
        self.assertEqual(block_problems(block), [])
        text = "\n".join(block)
        self.assertIn("timeout /t 15", text)
        self.assertIn("findstr /i", text)
        self.assertGreaterEqual(text.count('call "%CONDA_BAT%" create'), 2)

    def test_labels_exist_exactly_once(self):
        lines = [l.strip() for l in _bat().splitlines()]
        for label in (BULK_START, BULK_END, CREATE_START, CREATE_END):
            self.assertEqual(lines.count(label), 1, label)

    def test_rows_are_written_with_literal_ids_and_tags(self):
        text = SCRIPT.read_text(encoding="utf-8")
        tags = {
            "self.conda.retry5xx.control": "REQ-022.1",
            "self.conda.retry5xx.bulk": "REQ-005.2",
            "self.conda.retry5xx.create": "REQ-022.1",
            "self.conda.retry5xx.bounded": "REQ-022.2",
            "self.conda.retry5xx.nonretry": "REQ-022.3",
        }
        for row in ROW_IDS:
            pair = re.compile(r"id\s*=\s*'%s'\s*[;\n]\s*req\s*=\s*'%s'" % (re.escape(row), re.escape(tags[row])))
            self.assertEqual(len(pair.findall(text)), 2, row)

    def test_script_ends_with_its_own_exit_codes(self):
        text = SCRIPT.read_text(encoding="utf-8").rstrip()
        self.assertTrue(text.endswith("if ($script:AnyRowFailed) { exit 1 }\nexit 0"), text[-80:])

    def test_registry_lists_the_rows(self):
        ids, _many = check_ndjson_registry.parse_doc_registry(REPO / "docs" / "agent-ndjson.md")
        for row in ROW_IDS:
            self.assertIn(row, ids)

    def test_step_is_a_gating_step_on_real_and_justme_test(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        i = text.index('- name: "%s"' % STEP_NAME)
        nxt = text.find("\n      - name:", i + 1)
        block = text[i:nxt]
        self.assertNotIn("continue-on-error", block)
        self.assertIn("selfapps_conda_transient.ps1", block)
        self.assertIn("matrix.mode == 'real'", block)
        self.assertIn("matrix.mode == 'justme-test'", block)
        self.assertIn("~selftest_conda5xx", text[nxt:])


class SyntheticRulesCanFail(unittest.TestCase):
    def test_phrase_dropped_from_one_site(self):
        text = _bat().replace('/c:"Server Error" ', "", 1)
        self.assertTrue(site_problems(text))

    def test_sites_drift_apart(self):
        text = _bat()
        lines = [m.group(0) for m in FINDSTR.finditer(text)]
        self.assertEqual(len(lines), 2)
        drifted = text.replace(lines[0], lines[0].replace('/c:"timed out"', '/c:"timed-out"'), 1)
        self.assertTrue(site_problems(drifted))

    def test_findstr_emulation_is_case_blind_and_literal(self):
        self.assertTrue(findstr_matches(["Server Error"], "502 SERVER ERROR: Bad Gateway"))
        self.assertFalse(findstr_matches(["Server.Error"], "502 Server Error"))
        self.assertFalse(findstr_matches(["Server Error"], "404 Client Error"))

    def test_missing_label_is_reported(self):
        self.assertIsNone(cut_block("a\n:one\nb\n", ":one", ":two"))
        self.assertIsNone(cut_block("a\n:two\nb\n", ":one", ":two"))

    def test_unknown_goto_target_is_reported(self):
        self.assertTrue(block_problems([":start", "goto :elsewhere"]))
        self.assertEqual(block_problems([":start", "goto :start", "call :log x"]), [])

    def test_unknown_variable_is_reported(self):
        self.assertTrue(block_problems([":start", "echo %HP_NEW_THING%"]))
        self.assertEqual(block_problems([":start", "echo %LOG%", "rem %HP_IGNORED%"]), [])


if __name__ == "__main__":
    unittest.main()

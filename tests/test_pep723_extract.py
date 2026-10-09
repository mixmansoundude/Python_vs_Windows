"""Tests for tools/pep723_extract.py -- extracts the dependencies of a PEP 723
inline script-metadata block (CLAUDE.md Item 62).

The script is a flat, top-level sys.exit()-based script (matching its embedded
payload form, no importable functions), so it is exercised via subprocess --
same pattern as tests/test_pyproj_deps.py.

Item 62's field failure: the previous inline-PowerShell extractor accepted only
`# "item"` (one space, no comma), so the header `uv add --script` writes
(four-space indent, trailing comma, requires-python line, CRLF on Windows) was
reported as "no valid dependencies extracted" and the dependencies were dropped.
The UV_SHAPE tests pin that exact layout.

Also covers the exit codes (0 written / 1 nothing usable / 3 internal error),
the stdout reason line the setup log relies on, the embedded-helper rule that
the source must parse as Python 3.9 grammar, and the base64 HP_PEP723_EXTRACT
payload sync.
"""
import ast
import base64
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "tools" / "pep723_extract.py"

UV_BLOCK = (
    "# /// script\n"
    '# requires-python = ">=3.9"\n'
    "# dependencies = [\n"
    '#     "packaging>=24.0",\n'
    '#     "colorama>=0.4.6",\n'
    "# ]\n"
    "# ///\n"
)


def _run(entry_text, newline="\n", entry_bytes=None):
    """Write entry_text to a temp file, run the helper, return (rc, stdout, deps list or None)."""
    with tempfile.TemporaryDirectory() as td:
        entry = Path(td) / "entry.py"
        if entry_bytes is not None:
            entry.write_bytes(entry_bytes)
        else:
            entry.write_bytes(entry_text.replace("\n", newline).encode("utf-8"))
        out = Path(td) / "out.txt"
        proc = subprocess.run(
            [sys.executable, str(SOURCE), str(entry), str(out)],
            capture_output=True, text=True,
        )
        deps = out.read_text(encoding="ascii").splitlines() if out.exists() else None
        return proc.returncode, proc.stdout, deps


class UvShape(unittest.TestCase):
    """The layout `uv add --script` writes -- the Item 62 field failure."""

    def test_lf(self):
        rc, _out, deps = _run(UV_BLOCK + 'print("x")\n')
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["packaging>=24.0", "colorama>=0.4.6"])

    def test_crlf(self):
        rc, _out, deps = _run(UV_BLOCK + 'print("x")\n', newline="\r\n")
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["packaging>=24.0", "colorama>=0.4.6"])

    def test_requires_python_line_is_not_a_dependency(self):
        _rc, _out, deps = _run(UV_BLOCK)
        self.assertNotIn(">=3.9", " ".join(deps))

    def test_reports_count_on_stdout(self):
        _rc, out, _deps = _run(UV_BLOCK)
        self.assertIn("pep723_extract: 2 dependencies", out)


class HandWrittenShapes(unittest.TestCase):
    def test_one_space_no_comma_still_works(self):
        # The pre-existing self.pep723.valid fixture shape must keep working.
        rc, _out, deps = _run('# /// script\n# dependencies = [\n# "packaging"\n# ]\n# ///\nprint(1)\n')
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["packaging"])

    def test_single_line_array(self):
        rc, _out, deps = _run('# /// script\n# dependencies = ["requests", "rich>=13"]\n# ///\n')
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["requests", "rich>=13"])

    def test_single_quotes(self):
        rc, _out, deps = _run("# /// script\n# dependencies = [\n#   'requests',\n#   'rich',\n# ]\n# ///\n")
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["requests", "rich"])

    def test_no_space_after_hash(self):
        rc, _out, deps = _run('# /// script\n#dependencies = [\n#"requests",\n#]\n# ///\n')
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["requests"])

    def test_extras_and_multi_constraint_survive(self):
        rc, _out, deps = _run('# /// script\n# dependencies = [\n#   "requests[socks]>=2,<3",\n# ]\n# ///\n')
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["requests[socks]>=2,<3"])

    def test_comment_inside_array_cannot_end_it(self):
        text = (
            "# /// script\n"
            "# dependencies = [\n"
            '#   "requests",  # supports [1,2] syntax ]\n'
            '#   "rich",\n'
            "# ]\n"
            "# ///\n"
        )
        rc, _out, deps = _run(text)
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["requests", "rich"])

    def test_trailing_whitespace_on_fences(self):
        # astral-sh/uv#10918: uv itself rejects this, the bootstrapper should not.
        rc, _out, deps = _run('# /// script   \n# dependencies = ["requests"]\n# ///  \n')
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["requests"])

    def test_utf8_bom(self):
        data = b"\xef\xbb\xbf" + b'# /// script\n# dependencies = ["requests"]\n# ///\n'
        rc, _out, deps = _run(None, entry_bytes=data)
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["requests"])

    def test_toml_escaped_quote_in_a_marker_is_decoded(self):
        # Review finding on PR 475: the header holds python_version < "3.10" with escaped
        # inner quotes; the requirements file must carry the decoded text, or pip rejects the
        # whole line as an invalid requirement.
        text = '# /// script\n# dependencies = ["requests; python_version < \\"3.10\\""]\n# ///\n'
        rc, _out, deps = _run(text)
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ['requests; python_version < "3.10"'])

    def test_toml_backslash_and_unicode_escapes_are_decoded(self):
        text = '# /// script\n# dependencies = ["a\\\\b", "c\\u0041d"]\n# ///\n'
        rc, _out, deps = _run(text)
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["a\\b", "cAd"])

    def test_single_quoted_items_are_literal_no_escapes(self):
        text = "# /// script\n# dependencies = ['a\\nb']\n# ///\n"
        rc, _out, deps = _run(text)
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["a\\nb"])

    def test_first_block_wins(self):
        text = (
            '# /// script\n# dependencies = ["first"]\n# ///\n'
            'x = 1\n'
            '# /// script\n# dependencies = ["second"]\n# ///\n'
        )
        rc, _out, deps = _run(text)
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["first"])

    def test_block_after_shebang_and_code_comment(self):
        text = '#!/usr/bin/env python\n# note\n' + UV_BLOCK + 'print(1)\n'
        rc, _out, deps = _run(text)
        self.assertEqual(rc, 0)
        self.assertEqual(deps, ["packaging>=24.0", "colorama>=0.4.6"])


class NothingUsable(unittest.TestCase):
    """Exit 1, no output file, and a stdout reason the setup log can show."""

    def _assert_none(self, text, reason_part):
        rc, out, deps = _run(text)
        self.assertEqual(rc, 1)
        self.assertIsNone(deps)
        self.assertIn("pep723_extract: no dependencies", out)
        self.assertIn(reason_part, out)

    def test_no_block(self):
        self._assert_none('print("hi")\n', "no \"# /// script\" line")

    def test_findstr_style_mention_inside_a_docstring_is_not_a_block(self):
        self._assert_none('"""\nuse # /// script blocks\n"""\n    # /// script\nprint(1)\n', "no \"# /// script\" line")

    def test_unterminated_block(self):
        self._assert_none('# /// script\n# dependencies = ["requests"]\nprint(1)\n', "no closing")

    def test_malformed_no_dependencies_key(self):
        self._assert_none('# /// script\n# malformed: missing dependencies array and no closing marker\nprint(1)\n', "no closing")

    def test_block_without_dependencies_key(self):
        self._assert_none('# /// script\n# requires-python = ">=3.9"\n# ///\n', "no top-level dependencies")

    def test_empty_list(self):
        self._assert_none("# /// script\n# dependencies = []\n# ///\n", "empty")

    def test_array_without_a_closing_bracket_is_rejected(self):
        # Review finding on PR 475: a truncated array used to return the items read so far.
        self._assert_none('# /// script\n# dependencies = ["requests",\n# ///\n', 'no closing "]"')

    def test_multiline_array_without_a_closing_bracket_is_rejected(self):
        self._assert_none('# /// script\n# dependencies = [\n#     "requests",\n#     "numpy"\n# ///\n', 'no closing "]"')

    def test_dependencies_key_inside_a_tool_table_is_ignored(self):
        text = (
            "# /// script\n"
            '# requires-python = ">=3.9"\n'
            "# [tool.example]\n"
            '# dependencies = ["not-a-script-dependency"]\n'
            "# ///\n"
        )
        self._assert_none(text, "no top-level dependencies")


class InternalError(unittest.TestCase):
    def test_missing_entry_file_is_exit_3(self):
        with tempfile.TemporaryDirectory() as td:
            proc = subprocess.run(
                [sys.executable, str(SOURCE), str(Path(td) / "nope.py"), str(Path(td) / "out.txt")],
                capture_output=True, text=True,
            )
        self.assertEqual(proc.returncode, 3)


class BatchCallSite(unittest.TestCase):
    """The batch subroutine's own contract: any nonzero helper result leaves no output file.

    Both callers decide by file size, not exit code, so a partial file left by a failed write
    (review finding on PR 475) would be activated as if it were complete. No Windows scenario can
    force a write to fail midway, so this pins the guard in the source text.
    """

    def test_nonzero_result_deletes_the_output_file(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="ascii", errors="replace")
        start = bat.index("\n:extract_pep723_requirements\n")
        end = bat.index("\n:determine_entry", start)
        body = bat[start:end]
        self.assertRegex(
            body,
            r'if not "%HP_PEP723_RC%"=="0" if exist "%HP_PEP723_OUT%" del "%HP_PEP723_OUT%"',
        )
        # The delete must come after the helper ran, before the subroutine returns its result.
        self.assertLess(body.index('"%HP_PY%" "~pep723_extract.py"'), body.index('if not "%HP_PEP723_RC%"=="0"'))
        self.assertLess(body.index('if not "%HP_PEP723_RC%"=="0"'), body.index("exit /b %HP_PEP723_RC%"))


class EmbeddedHelperBaseline(unittest.TestCase):
    def test_parses_as_python_39_grammar(self):
        # Fallback tiers can hand the bootstrapper an older interpreter; a SyntaxError there is a
        # hard crash no try/except can catch (docs/agent-lessons-learned.md, embedded-helper baseline).
        ast.parse(SOURCE.read_text(encoding="utf-8"), feature_version=(3, 9))

    def test_payload_line_fits_cmd_limit(self):
        b64 = base64.b64encode(SOURCE.read_bytes())
        self.assertLessEqual(len('set "HP_PEP723_EXTRACT=') + len(b64) + 1, 8191)


class PayloadSync(unittest.TestCase):
    def test_embedded_base64_matches_source(self):
        bat = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")
        m = re.search(r'set "HP_PEP723_EXTRACT=([A-Za-z0-9+/=]+)"', bat)
        self.assertIsNotNone(m, "HP_PEP723_EXTRACT payload not found in run_setup.bat")
        decoded = base64.b64decode(m.group(1)).decode("utf-8")
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(
            decoded, source,
            "HP_PEP723_EXTRACT base64 is out of sync with tools/pep723_extract.py; "
            "run: python tools/sync_payload.py HP_PEP723_EXTRACT tools/pep723_extract.py",
        )


if __name__ == "__main__":
    unittest.main()

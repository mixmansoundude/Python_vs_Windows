"""Every embedded Python helper in run_setup.bat must parse as Python 3.9 (Item 126).

A fallback tier (venv, system, the embedded Python) can hand `HP_PY` an interpreter as old as 3.9, and the
helpers the batch file writes out and runs with it are parsed in full before the first line executes, so one
`match` statement or `except*` is a SyntaxError that no `try/except` inside the helper can catch. Six helpers
carried their own `ast.parse(..., feature_version=(3, 9))` test; the other sixteen did not, and a new payload
would have had none either. This test reads the payloads from the batch file itself (the same decoder the
inventory test uses), finds out from the emit site which of them are Python, and checks all of them, so a new
payload is covered the day it is added.

`feature_version` is not a complete guard, which is why there are extra rules. On a 3.12 or newer host it still
accepts: a quote reused inside an f-string replacement field (PEP 701), `a[*b]` (PEP 646), and `X | Y` in an
annotation that is evaluated when the def runs. Each of those is a SyntaxError or a TypeError on 3.9, so each
gets a rule below. Grammar only: a library call that is missing on an old interpreter (`zip(strict=True)`, a
`tomllib` import without a fallback) is a different question and is not judged here.

The checks are pure functions of source text, and the synthetic cases at the end prove each one can fail.
"""
from __future__ import annotations

import ast
import io
import re
import sys
import tokenize
import unittest
from pathlib import Path
from typing import Dict, List, Set

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_payload_inventory as inventory  # noqa: E402  (the one decoder of the batch file's payload lines)

OLDEST = (3, 9)

# An emit site: the file the payload is written to (a literal, or %VAR% naming a `set` line), then the payload name.
EMIT = re.compile(r'call :emit_from_base64 "([^"]+)" (HP_[A-Z0-9_]+)')
SET_FILE = re.compile(r'^\s*set "([A-Za-z0-9_]+)=(~[A-Za-z0-9_.]+)"\s*$', re.MULTILINE)
VARIABLE = re.compile(r"^%([A-Za-z0-9_]+)%$")

# Payloads that are neither Python nor PowerShell; each is named here on purpose, anything else unknown fails.
NEITHER = {"~condarc": "a conda configuration file"}


def emit_targets(bat_text: str) -> Dict[str, Set[str]]:
    """Payload name -> every file name some emit site writes it to (a %VAR% target is looked up in the `set` lines)."""
    variables: Dict[str, Set[str]] = {}
    for var, fname in SET_FILE.findall(bat_text):
        variables.setdefault(var, set()).add(fname)
    found: Dict[str, Set[str]] = {}
    for target, payload in EMIT.findall(bat_text):
        m = VARIABLE.match(target)
        names = variables.get(m.group(1), set()) if m else {target}
        found.setdefault(payload, set()).update(names or {"?" + target})
    return found


def classify(payloads: Dict[str, bytes], targets: Dict[str, Set[str]]) -> "tuple[Dict[str, bytes], List[str]]":
    """(the Python payloads, the problems). A payload is never taken for Python because it happens to parse."""
    python: Dict[str, bytes] = {}
    problems: List[str] = []
    for name in sorted(payloads):
        files = targets.get(name)
        if not files:
            problems.append("%s: no emit site writes it, so its kind is unknown" % name)
            continue
        kinds = set()
        for fname in files:
            if fname.endswith(".py"):
                kinds.add("python")
            elif fname.endswith(".ps1"):
                kinds.add("powershell")
            elif fname in NEITHER:
                kinds.add("neither")
            else:
                problems.append("%s: emitted as %r, which is not a .py, a .ps1 or a name listed in NEITHER" % (name, fname))
        if len(kinds) > 1:
            problems.append("%s: emitted as more than one kind of file (%s)" % (name, ", ".join(sorted(files))))
        if kinds == {"python"}:
            python[name] = payloads[name]
    for name in sorted(targets):
        if name not in payloads:
            problems.append("%s: an emit site names it, but the batch file defines no such payload line" % name)
    return python, problems


def _annotation_nodes(tree: ast.AST) -> List[ast.expr]:
    nodes: List[ast.expr] = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            args = node.args
            every = args.posonlyargs + args.args + args.kwonlyargs
            every += [a for a in (args.vararg, args.kwarg) if a is not None]
            nodes += [a.annotation for a in every if getattr(a, "annotation", None) is not None]
            if not isinstance(node, ast.Lambda) and node.returns is not None:
                nodes.append(node.returns)
        elif isinstance(node, ast.AnnAssign):
            nodes.append(node.annotation)
    return nodes


def _lazy_annotations(tree: ast.Module) -> bool:
    for node in tree.body:
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            if any(a.name == "annotations" for a in node.names):
                return True
    return False


def _fstring_problems(source: bytes) -> List[str]:
    """PEP 701 (3.12): a quote reused inside a replacement field, a backslash in one, or a comment in one.

    Before 3.12 the tokenizer returns an f-string as one STRING token and ast.parse already refuses the source,
    so this only has something to look at on a newer host; the rule is the same either way.
    """
    start = getattr(tokenize, "FSTRING_START", None)
    if start is None:
        return []
    end = tokenize.FSTRING_END
    middle = tokenize.FSTRING_MIDDLE
    out: List[str] = []
    try:
        tokens = list(tokenize.tokenize(io.BytesIO(source).readline))
    except (tokenize.TokenError, SyntaxError, IndentationError):
        return []
    stack: List[tuple] = []  # (opening quote text, line, depth of braces seen inside)
    for tok in tokens:
        if tok.type == start:
            if stack:
                out.append("line %d: an f-string inside an f-string replacement field" % tok.start[0])
            stack.append((tok.string[-1], tok.start[0], 0))
        elif tok.type == end:
            if stack:
                stack.pop()
        elif stack and tok.type == tokenize.OP and tok.string == "{":
            quote, line, depth = stack[-1]
            stack[-1] = (quote, line, depth + 1)
        elif stack and tok.type == tokenize.OP and tok.string == "}":
            quote, line, depth = stack[-1]
            stack[-1] = (quote, line, max(depth - 1, 0))
        elif stack and stack[-1][2] > 0 and tok.type != middle:
            quote, line, _ = stack[-1]
            if tok.type == tokenize.STRING and quote in tok.string[-1:]:
                out.append("line %d: the f-string's own quote reused inside a replacement field" % tok.start[0])
            if tok.type == tokenize.COMMENT:
                out.append("line %d: a comment inside a replacement field" % tok.start[0])
    return out


def grammar_problems(source: bytes) -> List[str]:
    """Everything that stops this source from running on Python 3.9, as a list of one-line findings."""
    try:
        tree = ast.parse(source, feature_version=OLDEST)
    except (SyntaxError, ValueError) as exc:
        return ["does not parse as Python %d.%d: %s" % (OLDEST + (exc,))]
    out: List[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Subscript):
            parts = node.slice.elts if isinstance(node.slice, ast.Tuple) else [node.slice]
            if any(isinstance(p, ast.Starred) for p in parts):
                out.append("line %d: a starred subscript (PEP 646, 3.11)" % node.lineno)
    if not _lazy_annotations(tree):
        for ann in _annotation_nodes(tree):
            for sub in ast.walk(ann):
                if isinstance(sub, ast.BinOp) and isinstance(sub.op, ast.BitOr):
                    out.append("line %d: X | Y in an annotation that is evaluated when the def runs (3.10)" % sub.lineno)
    out += _fstring_problems(source)
    return out


def _repo_inputs():
    bat = (inventory.REPO_ROOT / "run_setup.bat").read_bytes().decode("latin-1")
    return inventory.embedded_payloads(bat), emit_targets(bat)


class RepositoryHelpers(unittest.TestCase):
    def test_every_payload_has_a_known_kind(self) -> None:
        payloads, targets = _repo_inputs()
        _python, problems = classify(payloads, targets)
        self.assertEqual(problems, [])

    def test_every_embedded_python_helper_parses_as_python_3_9(self) -> None:
        payloads, targets = _repo_inputs()
        python, problems = classify(payloads, targets)
        self.assertEqual(problems, [])
        # The count is the inventory's, not a number of its own: Python payloads are those whose emit site names a .py file.
        self.assertGreaterEqual(len(python), 20)
        self.assertIn("HP_FIND_ENTRY", python)
        failures = {name: grammar_problems(data) for name, data in python.items()}
        self.assertEqual({n: p for n, p in failures.items() if p}, {})

    def test_the_two_kinds_that_are_not_python_are_the_ones_expected(self) -> None:
        payloads, targets = _repo_inputs()
        python, _problems = classify(payloads, targets)
        other = sorted(set(payloads) - set(python))
        ps1 = [n for n in other if all(f.endswith(".ps1") for f in targets[n])]
        self.assertEqual([n for n in other if n not in ps1], ["HP_CONDARC"])
        self.assertTrue(ps1)


class SyntheticCases(unittest.TestCase):
    """Each rule above can fail."""

    @staticmethod
    def _problems(code: str) -> List[str]:
        return grammar_problems(code.encode("utf-8"))

    def test_plain_old_python_passes(self) -> None:
        self.assertEqual(self._problems("import sys\n\n\ndef f(x: int = 1) -> int:\n    return x\n"), [])

    def test_a_match_statement_fails(self) -> None:
        self.assertTrue(self._problems("match 1:\n    case 1:\n        pass\n"))

    def test_except_star_fails(self) -> None:
        self.assertTrue(self._problems("try:\n    pass\nexcept* ValueError:\n    pass\n"))

    def test_a_type_statement_fails(self) -> None:
        self.assertTrue(self._problems("type X = int\n"))

    def test_a_generic_def_fails(self) -> None:
        self.assertTrue(self._problems("def f[T](x: T) -> T:\n    return x\n"))

    def test_a_starred_subscript_is_named(self) -> None:
        problems = self._problems("a = [1]\nb = [2]\nprint(a[*b])\n")
        self.assertEqual(len(problems), 1)
        if sys.version_info >= (3, 11):
            self.assertIn("starred subscript", problems[0])  # older hosts refuse the syntax themselves

    def test_a_union_in_an_annotation_is_named(self) -> None:
        problems = self._problems("def f(x: int | None = None) -> str | None:\n    return None\n")
        self.assertEqual(len(problems), 2)
        self.assertIn("X | Y in an annotation", problems[0])

    def test_a_union_in_a_module_annotation_is_named(self) -> None:
        self.assertEqual(len(self._problems("x: int | None = None\n")), 1)

    def test_a_union_is_fine_when_annotations_are_lazy(self) -> None:
        code = "from __future__ import annotations\n\n\ndef f(x: int | None = None) -> str | None:\n    return None\n"
        self.assertEqual(self._problems(code), [])

    def test_a_bit_or_outside_an_annotation_is_fine(self) -> None:
        self.assertEqual(self._problems("flags = 1 | 2\n"), [])

    @unittest.skipUnless(hasattr(tokenize, "FSTRING_START"), "before 3.12 ast.parse refuses these f-strings itself")
    def test_the_same_quote_inside_an_fstring_is_named(self) -> None:
        problems = self._problems("d = {'a': 1}\nprint(f\"{d[\"a\"]}\")\n")
        self.assertTrue(any("own quote reused" in p for p in problems), problems)

    @unittest.skipUnless(hasattr(tokenize, "FSTRING_START"), "before 3.12 ast.parse refuses these f-strings itself")
    def test_a_nested_fstring_is_named(self) -> None:
        problems = self._problems("x = 1\nprint(f\"{f'{x}'}\")\n")
        self.assertTrue(any("f-string inside an f-string" in p for p in problems), problems)

    @unittest.skipUnless(hasattr(tokenize, "FSTRING_START"), "before 3.12 ast.parse refuses these f-strings itself")
    def test_a_comment_inside_a_replacement_field_is_named(self) -> None:
        problems = self._problems("x = 1\nprint(f\"{x # note\n}\")\n")
        self.assertTrue(any("comment inside a replacement field" in p for p in problems), problems)

    def test_an_ordinary_fstring_passes(self) -> None:
        self.assertEqual(self._problems("x = 1\nprint(f\"{x} and {x!r:>4}\" + f'{x}')\n"), [])

    def test_a_dict_literal_inside_an_fstring_with_other_quotes_passes(self) -> None:
        self.assertEqual(self._problems("d = {'a': 1}\nprint(f\"{d['a']}\")\n"), [])

    def test_source_that_is_not_python_is_reported(self) -> None:
        self.assertEqual(len(self._problems("def f(:\n")), 1)

    # -- the classification of the payloads ------------------------------------------------------------------

    def test_targets_are_read_from_literal_and_variable_emit_sites(self) -> None:
        bat = (
            'set "HP_PROBE_PS=~failfast_probe.ps1"\r\n'
            'call :emit_from_base64 "%HP_PROBE_PS%" HP_FAILFAST_PROBE\r\n'
            'call :emit_from_base64 "~find_entry.py" HP_FIND_ENTRY\r\n'
            'call :emit_from_base64 "~find_entry.py" HP_FIND_ENTRY\r\n'
        )
        self.assertEqual(emit_targets(bat), {"HP_FAILFAST_PROBE": {"~failfast_probe.ps1"}, "HP_FIND_ENTRY": {"~find_entry.py"}})

    def test_an_unresolved_variable_target_is_kept_visible(self) -> None:
        found = emit_targets('call :emit_from_base64 "%NOPE%" HP_X\r\n')
        self.assertEqual(found, {"HP_X": {"?%NOPE%"}})
        _py, problems = classify({"HP_X": b"x = 1\n"}, found)
        self.assertEqual(len(problems), 1)
        self.assertIn("not a .py", problems[0])

    def test_classification_splits_python_powershell_and_the_named_exception(self) -> None:
        payloads = {"HP_A": b"a = 1\n", "HP_B": b"Write-Output 1\n", "HP_C": b"channels:\n"}
        targets = {"HP_A": {"~a.py"}, "HP_B": {"~b.ps1"}, "HP_C": {"~condarc"}}
        python, problems = classify(payloads, targets)
        self.assertEqual(problems, [])
        self.assertEqual(list(python), ["HP_A"])

    def test_a_payload_nothing_emits_is_reported_and_not_skipped(self) -> None:
        python, problems = classify({"HP_LOST": b"match x:\n    case 1: pass\n"}, {})
        self.assertEqual(python, {})
        self.assertEqual(len(problems), 1)
        self.assertIn("HP_LOST", problems[0])

    def test_an_emit_site_with_no_payload_line_is_reported(self) -> None:
        _python, problems = classify({}, {"HP_GONE": {"~gone.py"}})
        self.assertEqual(len(problems), 1)
        self.assertIn("defines no such payload", problems[0])

    def test_an_unknown_file_kind_is_reported(self) -> None:
        _python, problems = classify({"HP_Q": b"x\n"}, {"HP_Q": {"~q.txt"}})
        self.assertEqual(len(problems), 1)

    def test_one_payload_written_as_two_kinds_is_reported(self) -> None:
        _python, problems = classify({"HP_Q": b"x = 1\n"}, {"HP_Q": {"~q.py", "~q.ps1"}})
        self.assertEqual(len(problems), 1)
        self.assertIn("more than one kind", problems[0])

    def test_a_python_payload_with_old_grammar_trouble_is_found_through_the_whole_path(self) -> None:
        bat = (
            'set "HP_BAD=%s"\r\n' % __import__("base64").b64encode(b"match 1:\n    case 1:\n        pass\n" * 4).decode("ascii")
            + 'call :emit_from_base64 "~bad.py" HP_BAD\r\n'
        )
        payloads = inventory.embedded_payloads(bat)
        python, problems = classify(payloads, emit_targets(bat))
        self.assertEqual(problems, [])
        self.assertTrue(grammar_problems(python["HP_BAD"]))


if __name__ == "__main__":
    unittest.main()

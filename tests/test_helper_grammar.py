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
import shutil
import subprocess
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
    """The annotations 3.9 evaluates: a def's signature wherever the def sits, and module and class variables.

    An annotation on a variable in a function scope is never evaluated (PEP 526), so `x: int | None = None` inside a def
    runs on 3.9. A class body is a scope of its own and is evaluated when the class statement runs, even inside a def.
    """
    nodes: List[ast.expr] = []

    def visit(node: ast.AST, in_function: bool) -> None:
        inner = in_function
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            args = node.args
            every = args.posonlyargs + args.args + args.kwonlyargs
            every += [a for a in (args.vararg, args.kwarg) if a is not None]
            nodes.extend(a.annotation for a in every if a.annotation is not None)
            if node.returns is not None:
                nodes.append(node.returns)
            inner = True
        elif isinstance(node, ast.ClassDef):
            inner = False
        elif isinstance(node, ast.AnnAssign) and not in_function:
            nodes.append(node.annotation)
        for child in ast.iter_child_nodes(node):
            visit(child, inner)

    visit(tree, False)
    return nodes


def _lazy_annotations(tree: ast.Module) -> bool:
    for node in tree.body:
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            if any(a.name == "annotations" for a in node.names):
                return True
    return False


def _quote_of(start_text: str) -> str:
    """The delimiter of an f-string from its FSTRING_START text: the run of quotes after the prefix letters."""
    return start_text[len(start_text.rstrip("\"'")):]


def _fstring_problems(source: bytes) -> List[str]:
    """What 3.9 refuses inside an f-string replacement field and PEP 701 (3.12) allows.

    The delimiter of an enclosing f-string appearing anywhere in a field: 3.9 reads the whole f-string as one string first,
    so a quote of the same kind ends it early: one `"` in a `"` string, three in a triple-quoted one. A nested f-string is
    fine when its delimiter is another one. A backslash in the expression part, which includes every string and nested f-string
    text inside a field; the literal text and the format spec of an f-string that is not itself inside a field may hold one.
    A comment.

    Before 3.12 the tokenizer returns an f-string as one STRING token and ast.parse already refuses the source, so this
    only has something to look at on a newer host; the rule is the same either way.
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
    stack: List[list] = []  # one [delimiter, brace depth] per f-string being read, the innermost last
    for tok in tokens:
        fields = [f for f in stack if f[1] > 0]  # the replacement fields this token sits in
        line = tok.start[0]
        if tok.type == start:
            if any(f[0] in tok.string for f in fields):
                out.append("line %d: the f-string's own quote reused inside a replacement field" % line)
            stack.append([_quote_of(tok.string), 0])
            continue
        if tok.type == end:
            if stack:
                stack.pop()
            continue
        if stack and tok.type == tokenize.OP and tok.string in ("{", "}"):
            stack[-1][1] = stack[-1][1] + 1 if tok.string == "{" else max(stack[-1][1] - 1, 0)
            continue
        if not fields:
            continue
        if any(f[0] in tok.string for f in fields):
            out.append("line %d: the f-string's own quote reused inside a replacement field" % line)
        in_expression = (stack[-1][1] > 0 and tok.type != middle) or any(f[1] > 0 for f in stack[:-1])
        if in_expression and "\\" in tok.string:
            out.append("line %d: a backslash inside a replacement field" % line)
        if tok.type == tokenize.COMMENT:
            out.append("line %d: a comment inside a replacement field" % line)
    return out


_NOT_CODE = {tokenize.NEWLINE, tokenize.NL, tokenize.COMMENT, tokenize.INDENT, tokenize.DEDENT, tokenize.ENDMARKER}


def _is_parenthesised(segment: str) -> bool:
    """Whether the source text is one parenthesised expression, `(*a,)`, and not a list of items, `(1), *a`."""
    try:
        tokens = [t for t in tokenize.generate_tokens(io.StringIO(segment).readline) if t.type not in _NOT_CODE]
    except (tokenize.TokenError, SyntaxError, IndentationError):
        return False
    if not tokens or tokens[0].string != "(":
        return False
    depth = 0
    for index, tok in enumerate(tokens):
        if tok.type == tokenize.OP and tok.string in ("(", "[", "{"):
            depth += 1
        elif tok.type == tokenize.OP and tok.string in (")", "]", "}"):
            depth -= 1
            if depth == 0:
                return index == len(tokens) - 1
    return False


def grammar_problems(source: bytes) -> List[str]:
    """Everything that stops this source from running on Python 3.9, as a list of one-line findings."""
    try:
        tree = ast.parse(source, feature_version=OLDEST)
    except (SyntaxError, ValueError) as exc:
        return ["does not parse as Python %d.%d: %s" % (OLDEST + (exc,))]
    out: List[str] = []
    text = source.decode("utf-8-sig", errors="replace")
    for node in ast.walk(tree):
        if isinstance(node, ast.Subscript):
            parts = node.slice.elts if isinstance(node.slice, ast.Tuple) else [node.slice]
            if any(isinstance(p, ast.Starred) for p in parts):
                # d[(*a,)] is a tuple display, valid since 3.5; only an unparenthesised star in the brackets is PEP 646
                display = isinstance(node.slice, ast.Tuple) and _is_parenthesised(ast.get_source_segment(text, node.slice) or "")
                if not display:
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

    @unittest.skipUnless(sys.version_info >= (3, 11), "older hosts refuse the syntax themselves")
    def test_a_starred_subscript_that_starts_or_ends_with_parentheses_is_named(self) -> None:
        for code in ("d = {}\nitems = [1]\nprint(d[(1), *items])\n", "d = {}\nitems = [1]\nprint(d[*items, (1)])\n"):
            with self.subTest(code=code):
                problems = self._problems(code)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn("starred subscript", problems[0])

    def test_a_parenthesised_tuple_display_in_a_subscript_passes(self) -> None:
        # d[(*items,)] is an ordinary tuple display, valid since 3.5; only an unparenthesised d[*items] is PEP 646
        self.assertEqual(self._problems("d = {(1, 2): 3}\nitems = [1, 2]\nprint(d[(*items,)])\n"), [])

    def test_a_union_in_an_annotation_is_named(self) -> None:
        problems = self._problems("def f(x: int | None = None) -> str | None:\n    return None\n")
        self.assertEqual(len(problems), 2)
        self.assertIn("X | Y in an annotation", problems[0])

    def test_a_union_in_a_module_annotation_is_named(self) -> None:
        self.assertEqual(len(self._problems("x: int | None = None\n")), 1)

    def test_a_union_in_a_class_annotation_is_named(self) -> None:
        self.assertEqual(len(self._problems("class C:\n    x: int | None = None\n")), 1)

    def test_a_union_in_a_class_inside_a_def_is_named(self) -> None:
        # the class body runs when the def runs, and a class body evaluates its annotations
        self.assertEqual(len(self._problems("def f():\n    class C:\n        x: int | None = None\n    return C\n")), 1)

    def test_a_union_in_a_signature_inside_a_def_is_named(self) -> None:
        self.assertEqual(len(self._problems("def f():\n    def g(x: int | None = None):\n        return x\n    return g\n")), 1)

    def test_a_union_in_a_function_local_annotation_passes(self) -> None:
        # PEP 526: an annotation in a function scope is never evaluated, so 3.9 runs this
        code = "def f():\n    x: int | None = None\n    if x:\n        y: str | None = None\n    return x\n"
        self.assertEqual(self._problems(code), [])

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
    def test_a_nested_fstring_with_the_same_quote_is_named(self) -> None:
        problems = self._problems("x = 1\nprint(f\"{f\"{x}\"}\")\n")
        self.assertTrue(any("own quote reused" in p for p in problems), problems)

    @unittest.skipUnless(hasattr(tokenize, "FSTRING_START"), "before 3.12 ast.parse refuses these f-strings itself")
    def test_a_triple_quote_reused_inside_a_triple_quoted_fstring_is_named(self) -> None:
        problems = self._problems('print(f"""{ """ok""" }""")\n')
        self.assertTrue(any("own quote reused" in p for p in problems), problems)

    @unittest.skipUnless(hasattr(tokenize, "FSTRING_START"), "before 3.12 ast.parse refuses these f-strings itself")
    def test_a_backslash_in_a_replacement_field_is_named(self) -> None:
        problems = self._problems("print(f\"{'a\\nb'}\")\n")
        self.assertTrue(any("backslash" in p for p in problems), problems)

    @unittest.skipUnless(hasattr(tokenize, "FSTRING_START"), "before 3.12 ast.parse refuses these f-strings itself")
    def test_a_backslash_in_a_nested_fstring_inside_a_field_is_named(self) -> None:
        problems = self._problems("print(f\"{f'a\\n'}\")\n")
        self.assertTrue(any("backslash" in p for p in problems), problems)

    @unittest.skipUnless(hasattr(tokenize, "FSTRING_START"), "before 3.12 ast.parse refuses these f-strings itself")
    def test_a_comment_inside_a_replacement_field_is_named(self) -> None:
        problems = self._problems("x = 1\nprint(f\"{x # note\n}\")\n")
        self.assertTrue(any("comment inside a replacement field" in p for p in problems), problems)

    def test_an_ordinary_fstring_passes(self) -> None:
        self.assertEqual(self._problems("x = 1\nprint(f\"{x} and {x!r:>4}\" + f'{x}')\n"), [])

    def test_a_nested_fstring_with_the_other_quote_passes(self) -> None:
        self.assertEqual(self._problems("x = 1\nprint(f\"{f'{x}'}\")\n"), [])

    def test_a_single_quote_inside_a_triple_quoted_fstring_passes(self) -> None:
        self.assertEqual(self._problems('print(f"""{ "ok" }""")\n'), [])

    def test_a_nested_double_quoted_fstring_inside_a_triple_quoted_one_passes(self) -> None:
        self.assertEqual(self._problems('x = 1\nprint(f"""{ f"{x}" }""")\n'), [])

    def test_a_backslash_in_the_literal_part_or_the_format_spec_passes(self) -> None:
        self.assertEqual(self._problems('x = 1\nprint(f"a\\n{x}" + f"{x:\\n}")\n'), [])

    def test_a_quote_of_the_other_kind_in_a_format_spec_passes(self) -> None:
        self.assertEqual(self._problems("x = 1\nprint(f\"{x:'>4}\")\n"), [])

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


# What a real CPython 3.9 says about each source (compile(), recorded with 3.9 itself): True = it compiles. The guard has to
# agree on every host, so a rule that rejects what 3.9 accepts (a false alarm that blocks a good helper) and a rule that
# accepts what 3.9 refuses (the Item 126 gap) are both red here. Item 126 review: CodeRabbit found four false alarms and one
# gap in the first version of the rules.
CPYTHON_39 = [
    ("local annotation", "def f():\n    x: int | None = None\n    return x\nf()\n", True),
    ("nested f-string, other quote", "x = 1\nprint(f\"{f'{x}'}\")\n", True),
    ("nested f-string, same quote", "x = 1\nprint(f\"{f\"{x}\"}\")\n", False),
    ("triple outer, single quote inside", "print(f\"\"\"{ \"ok\" }\"\"\")\n", True),
    ("triple outer, triple inside", "print(f\"\"\"{ \"\"\"ok\"\"\" }\"\"\")\n", False),
    ("triple outer, nested f-string", "x = 1\nprint(f\"\"\"{ f\"{x}\" }\"\"\")\n", True),
    ("backslash in a string in the field", "print(f\"{'a\\nb'}\")\n", False),
    ("backslash in a nested f-string", "print(f\"{f'a\\n'}\")\n", False),
    ("backslash in the literal part", "x = 1\nprint(f\"a\\n{x}\")\n", True),
    ("backslash in the format spec", "x = 1\nprint(f\"{x:\\n}\")\n", True),
    ("quote in the format spec, other kind", "x = 1\nprint(f\"{x:'>4}\")\n", True),
    ("same quote in a subscript", "d = {'a': 1}\nprint(f\"{d[\"a\"]}\")\n", False),
    ("other quote in a subscript", "d = {'a': 1}\nprint(f\"{d['a']}\")\n", True),
    ("tuple display in a subscript", "d = {(1, 2): 3}\nitems = [1, 2]\nprint(d[(*items,)])\n", True),
    ("starred subscript", "d = {}\nitems = [1]\nprint(d[*items])\n", False),
    ("starred after a parenthesised item", "d = {}\nitems = [1]\nprint(d[(1), *items])\n", False),
    ("starred before a parenthesised item", "d = {}\nitems = [1]\nprint(d[*items, (1)])\n", False),
]


def _cpython_39() -> "str | None":
    for name in ("python3.9", "python3.9.exe"):
        found = shutil.which(name)
        if found:
            return found
    return None


class AgreesWithCPython39(unittest.TestCase):
    def test_the_guard_agrees_with_the_recorded_answers(self) -> None:
        for name, source, compiles in CPYTHON_39:
            with self.subTest(case=name):
                problems = grammar_problems(source.encode("utf-8"))
                if compiles:
                    self.assertEqual(problems, [], "3.9 compiles this, the guard must not refuse it")
                else:
                    self.assertTrue(problems, "3.9 refuses this, the guard must name it")

    @unittest.skipUnless(_cpython_39(), "no python3.9 on PATH; the recorded answers were taken with one")
    def test_the_recorded_answers_are_what_cpython_3_9_says(self) -> None:
        interpreter = _cpython_39()
        for name, source, compiles in CPYTHON_39:
            with self.subTest(case=name):
                done = subprocess.run(
                    [interpreter, "-I", "-c", "import sys; compile(sys.stdin.read(), 's', 'exec')"],
                    input=source, text=True, capture_output=True, timeout=60,
                )
                self.assertEqual(done.returncode == 0, compiles, done.stderr)


if __name__ == "__main__":
    unittest.main()

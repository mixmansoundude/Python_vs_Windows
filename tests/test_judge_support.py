"""Tests of tests/judge_support.py (Item 122), the helpers that the unit tests of the scripts which cut a block out of run_setup.bat
and judge what it did share (tests/test_conda_evict.py and tests/test_visa_present.py).

A helper that is wrong fails every test that uses it in the same way, or worse, lets a rule pass for the wrong reason, so each helper
has a case that shows what it returns and one that shows what it refuses. The driver's own promise (a judging function may use only its
parameters and its own locals) is shown twice: by running probe judges through real pwsh, and by reading the driver's text, where each
rule is shown to fail on a mutated copy of it. The older test files carry their own copies of these helpers and of the strict-driver
class (written before the module existed); moving them over is a separate change.
ASCII only.
"""
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import judge_support as js  # noqa: E402
from judge_support import (PWSH, after, case, cut_block, drop, drop_last, enclosing, is_bat_comment, label_section, lines_of,  # noqa: E402
                           live_bat, live_hash, mutate, norm, registry_ids, run_cases, step_block, swap, text_of, variables_in)

SUPPORT = Path(__file__).resolve().parent / "judge_support.py"
THIS_FILE = Path(__file__).resolve()

WORKFLOW = "\n".join([
    "jobs:",
    "  lane:",
    "    steps:",
    "      - name: First step",
    "        run: python tools/one.py",
    "      # a comment before the next step that names tools/three.py",
    "      - name: Second step",
    "        shell: pwsh",
    "        run: |",
    "          & tests\\two.ps1",
    "      - name: Last step",
    "        run: echo done",
    "",
])


class TextHelpers(unittest.TestCase):
    def test_norm_turns_crlf_into_lf_and_leaves_a_lone_cr(self):
        self.assertEqual(norm("a\r\nb\r\n"), "a\nb\n")
        self.assertEqual(norm("a\rb\n"), "a\rb\n")
        self.assertEqual(norm("a\nb"), "a\nb")

    def test_lines_of_splits_after_normalising_and_keeps_the_empty_last_element(self):
        self.assertEqual(lines_of("a\r\nb"), ["a", "b"])
        self.assertEqual(lines_of("a\r\nb\r\n"), ["a", "b", ""])
        self.assertEqual(lines_of(""), [""])

    def test_a_batch_comment_is_rem_or_double_colon_after_any_indent(self):
        for line in ("rem x", "REM x", "  rem\tx", "rem", "Rem", "::label", "  :: x"):
            with self.subTest(line=line):
                self.assertTrue(is_bat_comment(line))
        for line in ("remark", "echo rem", "set rem=1", ":label", "  :label", "echo ::", "", "x rem y"):
            with self.subTest(line=line):
                self.assertFalse(is_bat_comment(line))

    def test_live_bat_drops_blank_and_comment_lines_and_keeps_the_rest_unchanged(self):
        lines = ["", "  ", "rem x", ":: y", "echo a", "  set b=1", "  rem z"]
        self.assertEqual(live_bat(lines), ["echo a", "  set b=1"])
        self.assertEqual(live_bat([]), [])
        self.assertEqual(lines[4], "echo a")

    def test_live_hash_drops_blank_and_hash_comment_lines_and_strips_the_rest(self):
        self.assertEqual(live_hash("a\r\n  # c\n\n  b  \n#d\n"), ["a", "b"])
        self.assertEqual(live_hash("x # trailing\n"), ["x # trailing"])
        self.assertEqual(live_hash(""), [])

    def test_cut_block_runs_from_the_start_line_up_to_and_not_including_the_end_line(self):
        text = "x\r\n:start\r\na\r\n b \r\n:end\r\ny\r\n"
        self.assertEqual(cut_block(text, ":start", ":end"), [":start", "a", " b "])
        self.assertEqual(cut_block("  :start  \n a\n  :end \n", ":start", ":end"), ["  :start  ", " a"])

    def test_cut_block_looks_for_the_end_only_after_the_start_and_takes_the_first_start(self):
        self.assertEqual(cut_block(":end\n:start\na\n:end\n:start\nb\n:end\n", ":start", ":end"), [":start", "a"])

    def test_cut_block_answers_none_when_a_label_is_missing_or_the_order_is_wrong(self):
        self.assertIsNone(cut_block("a\n:end\n", ":start", ":end"))
        self.assertIsNone(cut_block(":start\na\n", ":start", ":end"))
        self.assertIsNone(cut_block(":end\n:start\na\n", ":start", ":end"))
        self.assertIsNone(cut_block(":start x\na\n:end x\n", ":start", ":end"))

    def test_variables_read_or_set_by_live_lines_are_named_and_comments_are_not(self):
        lines = ['set "A=1"', "echo %B% and %C:~0,1%", "if defined D (", "  set E=2", "rem %F% is a comment", ":: set G=3",
                 "if errorlevel 1 echo %ERRORLEVEL%"]
        self.assertEqual(variables_in(lines), {"A", "B", "C", "D", "E", "ERRORLEVEL"})
        self.assertEqual(variables_in([]), set())

    def test_a_label_section_runs_to_the_next_label_and_excludes_both_labels(self):
        body = ["a", ":one", "x", "y", ":two", "z"]
        self.assertEqual(label_section(body, ":one"), ["x", "y"])
        self.assertEqual(label_section(body, ":two"), ["z"])
        self.assertEqual(label_section([":only", "x"], ":only"), ["x"])
        self.assertEqual(label_section([":a", ":b"], ":a"), [])
        with self.assertRaises(ValueError):
            label_section(body, ":missing")

    def test_enclosing_names_the_openings_of_the_parentheses_still_open(self):
        body = ["if a (", "echo x", ") else (", "echo y", ")", "echo z"]
        self.assertEqual(enclosing(body, 0), [])
        self.assertEqual(enclosing(body, 1), ["if a ("])
        self.assertEqual(enclosing(body, 3), [") else ("])
        self.assertEqual(enclosing(body, 5), [])

    def test_enclosing_keeps_nested_openings_in_order_and_survives_a_stray_closing_line(self):
        nested = ["if a (", "if b (", "echo", ")", "echo", ")"]
        self.assertEqual(enclosing(nested, 2), ["if a (", "if b ("])
        self.assertEqual(enclosing(nested, 4), ["if a ("])
        self.assertEqual(enclosing(nested, 5), ["if a ("])
        self.assertEqual(enclosing([")", "x"], 1), [])

    def test_the_registry_ids_are_the_words_of_the_lines_inside_a_fence_and_prose_is_not(self):
        text = "prose a.b, c.d\n```\nx.y, z.w\n  q.r\n\n```\nmore.prose\n```text\nlast.id\n```\nend.prose\n"
        self.assertEqual(registry_ids(text), {"x.y", "z.w", "q.r", "last.id"})
        self.assertEqual(registry_ids("a.b\n"), set())
        self.assertEqual(registry_ids("```\nx.y\r\n```\r\n"), {"x.y"})

    def test_one_unclosed_fence_turns_the_prose_after_it_into_registered_ids(self):
        # the hazard docs/agent-lessons-learned.md names: the reader pairs the fences of the whole file
        self.assertEqual(registry_ids("```\na.b\n```\n```\nprose.word\n"), {"a.b", "prose.word"})


class SyntheticBuilders(unittest.TestCase):
    def test_mutate_replaces_a_text_that_occurs_exactly_once(self):
        self.assertEqual(mutate("a b a", " b ", "-"), "a-a")
        self.assertEqual(mutate("one two", "two", ""), "one ")

    def test_mutate_refuses_a_text_that_occurs_twice_or_not_at_all(self):
        with self.assertRaises(AssertionError) as twice:
            mutate("a b a", "a", "x")
        self.assertIn("exactly once, found 2", str(twice.exception))
        with self.assertRaises(AssertionError) as none:
            mutate("a b a", "c", "x")
        self.assertIn("exactly once, found 0", str(none.exception))

    def test_a_ledger_text_has_crlf_line_ends_and_a_final_one(self):
        self.assertEqual(text_of(["a", "b"]), "a\r\nb\r\n")
        self.assertEqual(text_of(["only"]), "only\r\n")

    def test_swap_replaces_the_one_line_and_leaves_the_input_alone(self):
        lines = ["a", "b", "c"]
        self.assertEqual(swap(lines, "b", "x"), ["a", "x", "c"])
        self.assertEqual(lines, ["a", "b", "c"])

    def test_swap_refuses_a_line_that_is_missing_or_there_twice(self):
        with self.assertRaises(AssertionError):
            swap(["a", "b"], "c", "x")
        with self.assertRaises(AssertionError):
            swap(["a", "b", "a"], "a", "x")

    def test_drop_removes_the_one_line_and_leaves_the_input_alone(self):
        lines = ["a", "b", "c"]
        self.assertEqual(drop(lines, "b"), ["a", "c"])
        self.assertEqual(lines, ["a", "b", "c"])

    def test_drop_refuses_a_line_that_is_missing_or_there_twice(self):
        with self.assertRaises(AssertionError):
            drop(["a", "b"], "c")
        with self.assertRaises(AssertionError):
            drop(["a", "b", "a"], "a")

    def test_drop_last_removes_only_the_last_of_the_lines_equal_to_the_one_named(self):
        lines = ["a", "b", "a", "a"]
        self.assertEqual(drop_last(lines, "a"), ["a", "b", "a"])
        self.assertEqual(drop_last(["a", "b", "a"], "a"), ["a", "b"])
        self.assertEqual(drop_last(["b", "a"], "a"), ["b"])
        self.assertEqual(lines, ["a", "b", "a", "a"])

    def test_drop_last_refuses_a_line_that_is_missing(self):
        with self.assertRaises(AssertionError):
            drop_last(["a", "b"], "c")

    def test_after_inserts_the_new_lines_behind_the_first_line_equal_to_the_anchor(self):
        lines = ["a", "b", "a"]
        self.assertEqual(after(lines, "a", "x", "y"), ["a", "x", "y", "b", "a"])
        self.assertEqual(after(["a", "b"], "b", "z"), ["a", "b", "z"])
        self.assertEqual(lines, ["a", "b", "a"])

    def test_after_refuses_an_anchor_that_is_missing(self):
        with self.assertRaises(ValueError):
            after(["a"], "c", "x")


class StepFinder(unittest.TestCase):
    def test_a_step_is_found_by_the_name_of_the_script_it_runs(self):
        first = step_block(WORKFLOW, "tools/one.py")
        self.assertTrue(first.startswith("      - name: First step\n"), first)
        self.assertIn("run: python tools/one.py", first)
        self.assertNotIn("Second step", first)
        second = step_block(WORKFLOW, "tests\\two.ps1")
        self.assertTrue(second.startswith("      - name: Second step\n"), second)
        self.assertIn("shell: pwsh", second)
        self.assertNotIn("Last step", second)

    def test_the_last_step_runs_to_the_end_of_the_text(self):
        last = step_block(WORKFLOW, "echo done")
        self.assertTrue(last.startswith("      - name: Last step\n"), last)
        self.assertIn("echo done", last)

    def test_a_script_no_step_runs_is_none(self):
        self.assertIsNone(step_block(WORKFLOW, "tools/nowhere.py"))
        self.assertIsNone(step_block("no steps here\n", "x"))

    def test_the_text_may_have_crlf_line_ends(self):
        found = step_block(WORKFLOW.replace("\n", "\r\n"), "tests\\two.ps1")
        self.assertTrue(found.startswith("      - name: Second step\n"), found)
        self.assertNotIn("\r", found)

    def test_a_comment_before_a_step_belongs_to_the_step_above_it(self):
        # the hazard docs/agent-lessons-learned.md names: text of a comment is attributed to the previous step
        found = step_block(WORKFLOW, "tools/three.py")
        self.assertTrue(found.startswith("      - name: First step\n"), found)

    def test_only_a_name_line_with_exactly_six_spaces_starts_a_step(self):
        text = "      - name: A\n        with:\n        - name: inner\n          run: x.py\n      - name: B\n        run: y.py\n"
        self.assertTrue(step_block(text, "x.py").startswith("      - name: A\n"))
        self.assertIn("- name: inner", step_block(text, "x.py"))
        self.assertTrue(step_block(text, "y.py").startswith("      - name: B\n"))


# --- the driver: its text -----------------------------------------------------------------------------------------------------------

def driver_text_problems(text):
    """What the text of the driver must keep for the promise of the module: errors stop the run, strict mode is on before any judge is
    defined, every variable the driver sets starts with two underscores, and only the text of the wanted functions is evaluated (the
    script is parsed, never run, so its own top-level code does not execute)."""
    found = []
    if "$ErrorActionPreference = 'Stop'" not in text:
        found.append("the driver does not set $ErrorActionPreference to Stop, so an error inside a judge would not fail the run")
    strict = text.find("Set-StrictMode -Version 1.0")
    first_use = text.find("Invoke-Expression")
    if strict < 0:
        found.append("the driver does not turn strict mode on")
    elif first_use >= 0 and strict > first_use:
        found.append("strict mode is turned on after the judges are defined")
    names = set(re.findall(r"\$([A-Za-z_]\w*)\s*=(?!=)", text)) | set(re.findall(r"foreach \(\$([A-Za-z_]\w*) in", text))
    loose = sorted(n for n in names if not n.startswith("__") and n != "ErrorActionPreference")
    if loose:
        found.append("the driver sets variable(s) a judge could read by accident: " + ", ".join("$" + n for n in loose))
    if "ParseFile($env:CC_SCRIPT" not in text:
        found.append("the driver does not parse the script with ParseFile, so it may run the script's own top-level code")
    if len(re.findall(r"Invoke-Expression", text)) != 1 or "Invoke-Expression $__f.Extent.Text" not in text:
        found.append("the driver evaluates something other than the text of the wanted functions")
    if re.search(r"(?m)^\s*\.\s+\S", text) or "& $env:CC_SCRIPT" in text:
        found.append("the driver runs or dot-sources the script itself")
    return found


class DriverText(unittest.TestCase):
    def test_the_real_driver_keeps_every_rule(self):
        self.assertEqual(driver_text_problems(js.DRIVER), [])

    def test_the_checks_are_not_vacuous_on_the_real_driver(self):
        self.assertGreaterEqual(len(re.findall(r"\$__\w+", js.DRIVER)), 20)
        self.assertEqual(len(re.findall(r"Invoke-Expression", js.DRIVER)), 1)
        self.assertEqual(len(re.findall(r"Set-StrictMode", js.DRIVER)), 1)

    def test_a_driver_without_the_stop_preference_is_reported(self):
        bad = mutate(js.DRIVER, "$ErrorActionPreference = 'Stop'\n", "")
        self.assertTrue(any("ErrorActionPreference" in f for f in driver_text_problems(bad)))

    def test_a_driver_without_strict_mode_is_reported(self):
        bad = mutate(js.DRIVER, "Set-StrictMode -Version 1.0\n", "")
        self.assertTrue(any("does not turn strict mode on" in f for f in driver_text_problems(bad)))

    def test_a_driver_that_turns_strict_mode_on_after_defining_the_judges_is_reported(self):
        bad = mutate(js.DRIVER, "Set-StrictMode -Version 1.0\n", "") + "\nSet-StrictMode -Version 1.0\n"
        self.assertTrue(any("after the judges are defined" in f for f in driver_text_problems(bad)))

    def test_a_driver_variable_without_the_two_underscores_is_reported_with_its_name(self):
        bad = js.DRIVER.replace("$__cases", "$cases")
        self.assertNotEqual(bad, js.DRIVER)
        found = driver_text_problems(bad)
        self.assertTrue(any("$cases" in f for f in found), found)
        bad = js.DRIVER.replace("foreach ($__c in", "foreach ($c in")
        self.assertNotEqual(bad, js.DRIVER)
        self.assertTrue(any("$c" in f for f in driver_text_problems(bad)))

    def test_a_driver_that_does_not_parse_the_script_is_reported(self):
        bad = mutate(js.DRIVER, "ParseFile($env:CC_SCRIPT", "ParseInput($env:CC_SCRIPT")
        self.assertTrue(any("ParseFile" in f for f in driver_text_problems(bad)))

    def test_a_driver_that_evaluates_more_than_the_wanted_functions_is_reported(self):
        bad = js.DRIVER + "\nInvoke-Expression (Get-Content -LiteralPath $env:CC_SCRIPT -Raw)\n"
        self.assertTrue(any("something other than the text of the wanted functions" in f for f in driver_text_problems(bad)))

    def test_a_driver_that_runs_the_script_itself_is_reported(self):
        for extra in ("\n. $env:CC_SCRIPT\n", "\n& $env:CC_SCRIPT\n"):
            with self.subTest(extra=extra):
                self.assertTrue(any("runs or dot-sources the script" in f for f in driver_text_problems(js.DRIVER + extra)))


# --- the driver: probe judges through real pwsh -----------------------------------------------------------------------------------

def run_script(text, want, cases):
    """Write `text` as the script and run the named functions of it on the cases; returns what run_cases returns."""
    with tempfile.TemporaryDirectory() as d:
        script = Path(d) / "probe.ps1"
        script.write_text(text, encoding="ascii")
        return run_cases(script, want, cases, d)


SCRIPT = """
throw 'the top-level code of the script ran'
function Get-Add {
    param($A, $B)
    return $A + $B
}
function Get-Many {
    param($N)
    1..$N
}
function Get-Nothing {
    param()
}
function Get-Blank {
    param()
    return ''
}
function Get-Flag {
    param($On)
    return [bool]$On
}
function Get-Table {
    param($Items, $Flag)
    return @{ Lines = @($Items | ForEach-Object { $_ + '!' }); Count = @($Items).Count; Flag = $Flag; Nested = @{ x = 1 } }
}
function Get-Unused {
    param()
    throw 'a function nobody asked for ran'
}
"""


@unittest.skipUnless(PWSH, "pwsh not available")
class DriverRuns(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.r = run_script(SCRIPT, ["Get-Add", "Get-Many", "Get-Nothing", "Get-Blank", "Get-Flag", "Get-Table"], [
            case("add", "Get-Add", A=2, B=3),
            case("add_strings", "Get-Add", A="x", B="y"),
            case("many", "Get-Many", N=3),
            case("one_of_many", "Get-Many", N=1),
            case("nothing", "Get-Nothing"),
            case("blank", "Get-Blank"),
            case("flag_true", "Get-Flag", On=True),
            case("flag_false", "Get-Flag", On=False),
            case("table", "Get-Table", Items=["a", "b"], Flag=True),
            case("table_one_item", "Get-Table", Items=["a"], Flag=False),
            case("table_no_item", "Get-Table", Items=[], Flag=False),
            case("add_again", "Get-Add", A=10, B=20),
        ])

    def test_a_case_is_a_name_a_function_and_its_arguments(self):
        self.assertEqual(case("n", "Get-X", A=1, B=[2]), {"name": "n", "fn": "Get-X", "args": {"A": 1, "B": [2]}})
        self.assertEqual(case("n", "Get-X"), {"name": "n", "fn": "Get-X", "args": {}})

    def test_the_answer_is_a_dictionary_from_case_name_to_the_list_of_what_the_function_returned(self):
        self.assertEqual(self.r["add"], [5])
        self.assertEqual(self.r["add_strings"], ["xy"])
        self.assertEqual(self.r["many"], [1, 2, 3])
        self.assertEqual(self.r["one_of_many"], [1])
        self.assertEqual(self.r["add_again"], [30])
        self.assertEqual(sorted(self.r), sorted(["add", "add_strings", "many", "one_of_many", "nothing", "blank", "flag_true",
                                                 "flag_false", "table", "table_one_item", "table_no_item", "add_again"]))

    def test_a_function_that_returns_nothing_is_an_empty_list_and_an_empty_string_is_a_list_of_one(self):
        self.assertEqual(self.r["nothing"], [])
        self.assertEqual(self.r["blank"], [""])

    def test_a_boolean_comes_back_as_a_boolean(self):
        self.assertEqual(self.r["flag_true"], [True])
        self.assertEqual(self.r["flag_false"], [False])

    def test_a_table_comes_back_as_one_dictionary_with_its_lists_and_nested_tables(self):
        self.assertEqual(self.r["table"], [{"Lines": ["a!", "b!"], "Count": 2, "Flag": True, "Nested": {"x": 1}}])
        self.assertEqual(self.r["table_one_item"][0]["Count"], 1)
        self.assertEqual(self.r["table_one_item"][0]["Flag"], False)
        self.assertEqual(self.r["table_no_item"][0]["Count"], 0)
        self.assertEqual(self.r["table_no_item"][0]["Lines"], [])

    def test_the_script_is_parsed_and_never_run_and_only_the_wanted_functions_are_defined(self):
        # the script above throws on its first line and holds a function that throws: neither ran
        self.assertEqual(self.r["add"], [5])

    def test_a_function_that_throws_fails_the_run_with_the_word_pwsh(self):
        script = "function Get-Boom {\n    param()\n    throw 'the judge broke'\n}\n"
        with self.assertRaises(AssertionError) as ctx:
            run_script(script, ["Get-Boom"], [case("boom", "Get-Boom")])
        self.assertIn("pwsh failed", str(ctx.exception))

    def test_a_script_that_does_not_parse_fails_the_run(self):
        with self.assertRaises(AssertionError) as ctx:
            run_script("function Get-X {\n    param($A)\n    if (\n}\n", ["Get-X"], [case("x", "Get-X", A=1)])
        self.assertIn("pwsh failed", str(ctx.exception))

    def test_a_function_that_is_not_in_the_script_fails_the_run(self):
        with self.assertRaises(AssertionError) as ctx:
            run_script("function Get-A {\n    param()\n    return 1\n}\n", ["Get-A", "Get-Missing"], [case("a", "Get-A")])
        self.assertIn("a judging function is missing", str(ctx.exception))

    def test_a_case_that_names_a_function_that_was_not_asked_for_fails_the_run(self):
        script = "function Get-A {\n    param()\n    return 1\n}\nfunction Get-B {\n    param()\n    return 2\n}\n"
        with self.assertRaises(AssertionError):
            run_script(script, ["Get-A"], [case("b", "Get-B")])


@unittest.skipUnless(PWSH, "pwsh not available")
class JudgeDriverIsStrict(unittest.TestCase):
    """The shared driver (tests/judge_support.py) runs each judging function alone and in strict mode, so a judge that reads a
    variable it does not own fails loudly instead of reading $null (or a variable of the driver) and quietly passing."""

    def run_probe(self, body, args):
        with tempfile.TemporaryDirectory() as d:
            script = Path(d) / "judge.ps1"
            script.write_text("function Get-Probe {\n    param($Value)\n%s\n}\n" % body, encoding="ascii")
            return run_cases(script, ["Get-Probe"], [{"name": "probe", "fn": "Get-Probe", "args": args}], d)["probe"]

    def test_a_judge_that_uses_only_its_own_values_runs(self):
        self.assertEqual(self.run_probe("    $own = $Value + 1\n    return $own", {"Value": 41}), [42])

    def test_a_judge_that_reads_a_variable_nobody_set_fails(self):
        with self.assertRaises(AssertionError) as ctx:
            self.run_probe("    return $neverSetByAnyone", {"Value": 1})
        self.assertIn("pwsh failed", str(ctx.exception))

    def test_a_judge_cannot_read_a_variable_of_the_driver(self):
        for name in ("cases", "c", "h", "want", "all", "ast", "defs", "tokens", "errs", "r", "p", "f"):
            with self.subTest(name=name):
                with self.assertRaises(AssertionError):
                    self.run_probe("    return $%s" % name, {"Value": 1})

    def test_variable_names_ignore_case_so_a_local_overwrites_a_parameter_of_the_same_name(self):
        # the lesson of the older tests: variable names ignore case, so the judge's own local overwrote its parameter
        self.assertEqual(self.run_probe("    $value = 7\n    return $Value", {"Value": 1}), [7])


# --- the module itself ---------------------------------------------------------------------------------------------------------------

class Surface(unittest.TestCase):
    def test_the_module_is_ascii_and_cannot_be_collected_as_a_test(self):
        text = SUPPORT.read_text(encoding="utf-8")
        self.assertTrue(all(ord(c) < 128 for c in text))
        self.assertFalse(SUPPORT.name.startswith("test_"))
        self.assertEqual([n for n in dir(js) if n.startswith(("test", "Test"))], [])

    def test_the_pwsh_timeout_leaves_room_for_a_busy_runner(self):
        self.assertGreaterEqual(js.HARD_TIMEOUT, 60)
        self.assertLessEqual(js.HARD_TIMEOUT, 600)

    def test_every_public_helper_is_named_in_this_file_so_a_new_helper_gets_a_test(self):
        mine = THIS_FILE.read_text(encoding="utf-8")
        helpers = sorted(n for n, v in vars(js).items() if callable(v) and getattr(v, "__module__", None) == js.__name__
                         and not n.startswith("_"))
        self.assertGreaterEqual(len(helpers), 19, helpers)
        for name in helpers:
            with self.subTest(helper=name):
                self.assertIn(name + "(", mine)


if __name__ == "__main__":
    unittest.main()

"""REQ-002.15 and REQ-002.18: the entry picker waits 30 seconds and defaults, and a non-interactive run is never asked.

No row can wait the full 30 seconds (self.entry.picker shortens the wait to 2 seconds with HP_TEST_FORCE_PICKER) and the
rows that run the picker set the CI marker, so the other two non-interactive signals, NOINPUT and HP_NONINTERACTIVE, are
read here from the batch file. Both checks are static reads of :pick_entry_interactive; the rows
self.entry.picker, self.entry.picker.number and self.entry.fallback show the behavior around them.
"""
import re
import unittest
from pathlib import Path
from typing import List

REPO_ROOT = Path(__file__).resolve().parents[1]
BATCH = REPO_ROOT / "run_setup.bat"

LABEL = ":pick_entry_interactive"
NEXT_LABEL = ":pick_menu_line"

GATE_LINES = (
    "if defined NOINPUT exit /b 0",
    "if defined HP_NONINTERACTIVE exit /b 0",
    "if defined HP_CI_LANE if not defined HP_TEST_FORCE_PICKER exit /b 0",
)
CHOICE = "choice /C 123456789 /N /T %HP_PICK_T% /D %HP_PICK_DEFAULT%"


def picker_block(text: str) -> str:
    """The text of :pick_entry_interactive, from its label line to the label of the next subroutine."""
    start = re.search(r"^%s[ \t]*\r?$" % re.escape(LABEL), text, re.MULTILINE)
    if not start:
        raise AssertionError("run_setup.bat has no %s label" % LABEL)
    end = re.search(r"^%s[ \t]*\r?$" % re.escape(NEXT_LABEL), text[start.end():], re.MULTILINE)
    if not end:
        raise AssertionError("run_setup.bat has no %s label after %s" % (NEXT_LABEL, LABEL))
    return text[start.start(): start.end() + end.start()]


def _lines(block: str) -> List[str]:
    return [ln.strip() for ln in block.splitlines()]


def gate_problems(block: str) -> List[str]:
    """Each of the three non-interactive signals ends the subroutine before the list is built or the prompt is read."""
    lines = _lines(block)
    problems: List[str] = []
    try:
        menu_at = next(i for i, ln in enumerate(lines) if ln.startswith("(for /f") and "~entry.menu" in ln)
    except StopIteration:
        return ["the line that builds ~entry.menu is missing"]
    choice_at = next((i for i, ln in enumerate(lines) if ln.startswith("choice ")), -1)
    if choice_at < 0:
        return ["the choice line of the picker is missing"]
    for gate in GATE_LINES:
        if gate not in lines:
            problems.append("the gate line %r is missing" % gate)
        elif lines.index(gate) > menu_at:
            problems.append("the gate line %r sits after the list is built, so a non-interactive run is asked" % gate)
    return problems


def wait_problems(block: str) -> List[str]:
    """The prompt waits 30 seconds and then takes the alphabetical default; only the test setting shortens it."""
    lines = _lines(block)
    problems: List[str] = []
    if 'set "HP_PICK_T=30"' not in lines:
        problems.append('the wait is no longer set to 30 seconds (set "HP_PICK_T=30")')
    else:
        wait_at = lines.index('set "HP_PICK_T=30"')
        test_hook = 'if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"'
        if test_hook not in lines or lines.index(test_hook) < wait_at:
            problems.append("only HP_TEST_FORCE_PICKER may shorten the wait, and only after it is set to 30")
    choice = next((ln for ln in lines if ln.startswith("choice ")), "")
    if not choice.startswith(CHOICE):
        problems.append("the prompt no longer waits HP_PICK_T seconds and then takes HP_PICK_DEFAULT: %r" % choice[:80])
    if 'if /i "%~1"=="%HP_ENTRY%" set "HP_PICK_DEFAULT=%HP_PICK_I%"' not in [ln for ln in _lines(_menu_line_block())]:
        problems.append("HP_PICK_DEFAULT is no longer the list position of the alphabetical default HP_ENTRY")
    return problems


def _menu_line_block() -> str:
    text = BATCH.read_text(encoding="utf-8", errors="replace")
    start = re.search(r"^:pick_menu_line[ \t]*\r?$", text, re.MULTILINE)
    end = re.search(r"^:pick_apply_line[ \t]*\r?$", text[start.end():], re.MULTILINE) if start else None
    if not start or not end:
        raise AssertionError("run_setup.bat has no :pick_menu_line or :pick_apply_line label")
    return text[start.start(): start.end() + end.start()]


GOOD = """\
:pick_entry_interactive
rem comment
if defined NOINPUT exit /b 0
if defined HP_NONINTERACTIVE exit /b 0
if defined HP_CI_LANE if not defined HP_TEST_FORCE_PICKER exit /b 0
where choice >nul 2>&1 || exit /b 0
(for /f "delims=" %%F in ('dir /b') do echo %%F) > "~entry.menu"
set "HP_PICK_T=30"
if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"
choice /C 123456789 /N /T %HP_PICK_T% /D %HP_PICK_DEFAULT% /M "x"
exit /b 0

:pick_menu_line
"""


class PickerGate(unittest.TestCase):
    """REQ-002.18: NOINPUT, HP_NONINTERACTIVE and the CI marker each end :pick_entry_interactive before the question."""

    def test_the_real_batch_file_gates_all_three_signals(self) -> None:
        block = picker_block(BATCH.read_text(encoding="utf-8", errors="replace"))
        self.assertEqual([], gate_problems(block))

    def test_a_good_synthetic_block_passes(self) -> None:
        self.assertEqual([], gate_problems(picker_block(GOOD)))

    def test_a_missing_signal_fails(self) -> None:
        for gate in GATE_LINES:
            with self.subTest(gate=gate):
                mutated = GOOD.replace(gate + "\n", "")
                self.assertTrue(any("is missing" in p for p in gate_problems(picker_block(mutated))))

    def test_a_signal_read_after_the_list_is_built_fails(self) -> None:
        late = GOOD.replace("if defined NOINPUT exit /b 0\n", "").replace(
            "set \"HP_PICK_T=30\"", "if defined NOINPUT exit /b 0\nset \"HP_PICK_T=30\"")
        self.assertTrue(any("after the list is built" in p for p in gate_problems(picker_block(late))))


class PickerWait(unittest.TestCase):
    """REQ-002.15: a 30 second wait for a number, then the alphabetical default."""

    def test_the_real_batch_file_waits_30_seconds_and_defaults(self) -> None:
        block = picker_block(BATCH.read_text(encoding="utf-8", errors="replace"))
        self.assertEqual([], wait_problems(block))

    def test_a_changed_wait_fails(self) -> None:
        mutated = GOOD.replace("HP_PICK_T=30", "HP_PICK_T=10")
        self.assertTrue(any("30 seconds" in p for p in wait_problems(picker_block(mutated))))

    def test_a_test_setting_before_the_default_fails(self) -> None:
        mutated = GOOD.replace(
            'set "HP_PICK_T=30"\nif defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"',
            'if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"\nset "HP_PICK_T=30"')
        self.assertTrue(any("only HP_TEST_FORCE_PICKER" in p for p in wait_problems(picker_block(mutated))))

    def test_a_prompt_with_another_default_fails(self) -> None:
        mutated = GOOD.replace("/D %HP_PICK_DEFAULT%", "/D 1")
        self.assertTrue(any("HP_PICK_DEFAULT" in p for p in wait_problems(picker_block(mutated))))


if __name__ == "__main__":
    unittest.main()

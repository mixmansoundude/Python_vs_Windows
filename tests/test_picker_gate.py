"""REQ-002.15, REQ-002.18 and REQ-002.19: the entry picker waits 30 seconds and defaults, a non-interactive run is never
asked, and the question is asked once per run.

No row can wait the full 30 seconds (self.entry.picker shortens the wait to 2 seconds with HP_TEST_FORCE_PICKER) and the
rows that run the picker set the CI marker, so the other two non-interactive signals, NOINPUT and HP_NONINTERACTIVE, are
read here from the batch file. These checks are static reads of :pick_entry_interactive; the rows
self.entry.picker, self.entry.picker.number, self.entry.picker.metafile and self.entry.fallback show the behavior around
them (self.entry.picker.number is the row that found the second question, Item 109).
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


def wait_problems(block: str, menu_block: str) -> List[str]:
    """The prompt waits 30 seconds and then takes the alphabetical default; only the test setting shortens it.

    menu_block is the text of :pick_menu_line, the subroutine that numbers the list and so decides which number the
    default has; it sits outside :pick_entry_interactive, so the caller passes it in.
    """
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
    if 'if /i "%~1"=="%HP_ENTRY%" set "HP_PICK_DEFAULT=%HP_PICK_I%"' not in _lines(menu_block):
        problems.append("HP_PICK_DEFAULT is no longer the list position of the alphabetical default HP_ENTRY")
    return problems


KEEP_LINES = (
    'if defined HP_PICKED_ENTRY set "HP_ENTRY=%HP_PICKED_ENTRY%"',
    "if defined HP_PICKED_ENTRY exit /b 0",
)
SELECTED_LOG = 'call :log "[INFO] REQ-002: Picker entry selected: %HP_ENTRY%"'
KEEP_SET = 'set "HP_PICKED_ENTRY=%HP_ENTRY%"'


def once_problems(text: str, block: str) -> List[str]:
    """REQ-002.19 (Item 109): :determine_entry runs twice per bootstrap, so the answer is kept for the run.

    The file chosen is stored after the log line that reports it, the next call reads it back before any gate or
    question, and the variable is cleared once at the top level of the file (never inside the subroutine, which a second
    call and a provider cascade run again), so a value inherited from the calling terminal is not an answer.
    """
    lines = _lines(block)
    problems: List[str] = []
    for keep in KEEP_LINES:
        if keep not in lines:
            problems.append("the line %r is missing, so a second call asks again" % keep)
    if all(keep in lines for keep in KEEP_LINES):
        first_gate = min((lines.index(g) for g in GATE_LINES if g in lines), default=len(lines))
        choice_at = next((i for i, ln in enumerate(lines) if ln.startswith("choice ")), len(lines))
        for keep in KEEP_LINES:
            if lines.index(keep) > min(first_gate, choice_at):
                problems.append("the line %r comes after a gate or the question" % keep)
        if lines.index(KEEP_LINES[0]) > lines.index(KEEP_LINES[1]):
            problems.append("the answer must be copied to HP_ENTRY before the subroutine returns")
    if KEEP_SET not in lines:
        problems.append("the chosen file is never stored (%s)" % KEEP_SET)
    elif SELECTED_LOG not in lines or lines.index(KEEP_SET) < lines.index(SELECTED_LOG):
        problems.append("the chosen file is stored before it is final (after the choice line and the log line)")
    clears = [m.start() for m in re.finditer(r'^set "HP_PICKED_ENTRY="[ \t]*\r?$', text, re.MULTILINE)]
    label_at = re.search(r"^%s[ \t]*\r?$" % re.escape(LABEL), text, re.MULTILINE)
    if len(clears) != 1:
        problems.append('the file must clear HP_PICKED_ENTRY exactly once (set "HP_PICKED_ENTRY="), found %d' % len(clears))
    elif label_at and clears[0] > label_at.start():
        problems.append("the one clear of HP_PICKED_ENTRY sits after :pick_entry_interactive, so it can erase an answer")
    return problems


def _menu_line_block() -> str:
    text = BATCH.read_text(encoding="utf-8", errors="replace")
    start = re.search(r"^:pick_menu_line[ \t]*\r?$", text, re.MULTILINE)
    end = re.search(r"^:pick_apply_line[ \t]*\r?$", text[start.end():], re.MULTILINE) if start else None
    if not start or not end:
        raise AssertionError("run_setup.bat has no :pick_menu_line or :pick_apply_line label")
    return text[start.start(): start.end() + end.start()]


GOOD = """\
set "HP_PICKED_ENTRY="
:pick_entry_interactive
rem comment
if defined HP_PICKED_ENTRY set "HP_ENTRY=%HP_PICKED_ENTRY%"
if defined HP_PICKED_ENTRY exit /b 0
if defined NOINPUT exit /b 0
if defined HP_NONINTERACTIVE exit /b 0
if defined HP_CI_LANE if not defined HP_TEST_FORCE_PICKER exit /b 0
where choice >nul 2>&1 || exit /b 0
(for /f "delims=" %%F in ('dir /b') do echo %%F) > "~entry.menu"
set "HP_PICK_T=30"
if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"
choice /C 123456789 /N /T %HP_PICK_T% /D %HP_PICK_DEFAULT% /M "x"
call :log "[INFO] REQ-002: Picker entry selected: %HP_ENTRY%"
set "HP_PICKED_ENTRY=%HP_ENTRY%"
exit /b 0

:pick_menu_line
"""

GOOD_MENU = """\
:pick_menu_line
set /a HP_PICK_I+=1
echo   [%HP_PICK_I%] %~1
if /i "%~1"=="%HP_ENTRY%" set "HP_PICK_DEFAULT=%HP_PICK_I%"
exit /b 0

:pick_apply_line
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
        self.assertEqual([], wait_problems(block, _menu_line_block()))

    def test_a_good_synthetic_block_passes(self) -> None:
        self.assertEqual([], wait_problems(picker_block(GOOD), GOOD_MENU))

    def test_a_changed_wait_fails(self) -> None:
        mutated = GOOD.replace("HP_PICK_T=30", "HP_PICK_T=10")
        self.assertTrue(any("30 seconds" in p for p in wait_problems(picker_block(mutated), GOOD_MENU)))

    def test_a_test_setting_before_the_default_fails(self) -> None:
        mutated = GOOD.replace(
            'set "HP_PICK_T=30"\nif defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"',
            'if defined HP_TEST_FORCE_PICKER set "HP_PICK_T=2"\nset "HP_PICK_T=30"')
        self.assertTrue(any("only HP_TEST_FORCE_PICKER" in p for p in wait_problems(picker_block(mutated), GOOD_MENU)))

    def test_a_prompt_with_another_default_fails(self) -> None:
        mutated = GOOD.replace("/D %HP_PICK_DEFAULT%", "/D 1")
        self.assertTrue(any("HP_PICK_DEFAULT" in p for p in wait_problems(picker_block(mutated), GOOD_MENU)))

    def test_a_list_that_numbers_another_default_fails(self) -> None:
        # The default's number is set by :pick_menu_line, outside the block the other rules read.
        mutated_menu = GOOD_MENU.replace('set "HP_PICK_DEFAULT=%HP_PICK_I%"', 'set "HP_PICK_DEFAULT=1"')
        self.assertTrue(any("list position" in p for p in wait_problems(picker_block(GOOD), mutated_menu)))


class PickerAsksOnce(unittest.TestCase):
    """REQ-002.19: :determine_entry runs twice per bootstrap and the question is asked once (Item 109)."""

    def test_the_real_batch_file_keeps_the_answer(self) -> None:
        text = BATCH.read_text(encoding="utf-8", errors="replace")
        self.assertEqual([], once_problems(text, picker_block(text)))

    def test_a_good_synthetic_file_passes(self) -> None:
        self.assertEqual([], once_problems(GOOD, picker_block(GOOD)))

    def test_a_missing_read_back_fails(self) -> None:
        for keep in KEEP_LINES:
            with self.subTest(line=keep):
                mutated = GOOD.replace(keep + "\n", "")
                self.assertTrue(any("is missing" in p for p in once_problems(mutated, picker_block(mutated))))

    def test_a_read_back_after_a_gate_fails(self) -> None:
        late = GOOD
        for keep in KEEP_LINES:
            late = late.replace(keep + "\n", "")
        late = late.replace("where choice", "\n".join(KEEP_LINES) + "\nwhere choice")
        self.assertTrue(any("after a gate" in p for p in once_problems(late, picker_block(late))))

    def test_an_answer_that_is_never_stored_fails(self) -> None:
        mutated = GOOD.replace(KEEP_SET + "\n", "")
        self.assertTrue(any("never stored" in p for p in once_problems(mutated, picker_block(mutated))))

    def test_a_clear_inside_the_subroutine_fails(self) -> None:
        mutated = GOOD.replace('set "HP_PICKED_ENTRY="\n:pick_entry_interactive', ':pick_entry_interactive\nset "HP_PICKED_ENTRY="')
        self.assertTrue(any("after :pick_entry_interactive" in p for p in once_problems(mutated, picker_block(mutated))))

    def test_no_clear_fails(self) -> None:
        mutated = GOOD.replace('set "HP_PICKED_ENTRY="\n:pick_entry_interactive', ":pick_entry_interactive")
        self.assertTrue(any("exactly once" in p for p in once_problems(mutated, picker_block(mutated))))


if __name__ == "__main__":
    unittest.main()

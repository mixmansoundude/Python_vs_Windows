"""Item 97 follow-up (a): the --hidden-import repair loop reads the error of the failed check run before it starts the program again.

README REQ-018.1 allows one automatic start of the program per invocation and REQ-018.2 any other only with the user's consent. The
check run (the invocation's one start) has already printed its error to ~run.out.txt and ~run.err.txt, so the first call of
:hidden_import_recover reads it there instead of starting the program once more only to learn what it says:
  * an error that names no installed package ends the call at once: one log line, no question, no start, no rebuild;
  * an error that names one goes to the question (REQ-018.2), and a yes goes straight to the rebuild, so the starts are the check
    run plus one to check each rebuild;
  * the second call of a build (after a DLL repair, HP_HID_REREAD set by its caller) reads nothing, because the EXE was rebuilt since
    the check run, and starts once as before;
  * the DLL flag of an earlier pass no longer makes the second call run when this call rebuilt nothing.
tests/selfapps_repair_consent.ps1 shows the behavior (rows self.repair.noread.plain and .starts, plus the older rows of that script,
which keep passing). This file pins the batch shape those rows rely on. Each rule is shown to fail by a mutation of the real
run_setup.bat text (mutate() asserts the anchor occurs exactly once, so a case cannot pass by changing nothing).
ASCII only.
"""
import re
import unittest
from pathlib import Path

from judge_support import cut_block, live_bat, mutate, norm

REPO = Path(__file__).resolve().parent.parent
BAT = REPO / "run_setup.bat"
SCRIPT = REPO / "tests" / "selfapps_repair_consent.ps1"

RECOVER_START, RECOVER_END = ":hidden_import_recover", ":warn_user_code_launch"
CONSENT_START, CONSENT_END = ":hidden_import_consent", ":run_exe_smokerun"

NOREAD_TEXT = "names no installed package"

EVIDENCE = '"dist\\~exe_out.txt"'
DEL_EVIDENCE = 'if exist "dist\\~exe_out.txt" del "dist\\~exe_out.txt" >nul 2>&1'
SCAN_LINE = '"%HP_PY%" ~hidden_import_scan.py "dist\\~exe_out.txt" > "~next_hidden.txt" 2>> "%LOG%"'
FOR_LINE = 'for /f "usebackq delims=" %%M in ("~next_hidden.txt") do set "HP_NEXT_HIDDEN=%%M"'

# The pre-read in the order it runs; every step after the first must come after the one before it.
PREREAD = (
    'set "HP_NEXT_HIDDEN="',
    "if defined HP_HID_REREAD goto :hidden_import_ask",
    DEL_EVIDENCE,
    'if exist "~run.out.txt" type "~run.out.txt" >> ' + EVIDENCE,
    'if exist "~run.err.txt" type "~run.err.txt" >> ' + EVIDENCE,
    "if not exist " + EVIDENCE + " goto :hidden_import_noread",
    'call :emit_from_base64 "~hidden_import_scan.py" HP_HIDDEN_IMPORT_SCAN',
    SCAN_LINE,
    FOR_LINE,
    DEL_EVIDENCE,
    "if defined HP_NEXT_HIDDEN goto :hidden_import_ask",
    ":hidden_import_noread",
    None,  # the log line, found by its text
    "exit /b 0",
    ":hidden_import_ask",
    "call :hidden_import_consent",
    "if not defined HP_HIC_ALLOWED exit /b 0",
)

WARN_CALL = "call :warn_user_code_launch hidden_import"


def recover_body(text):
    block = cut_block(text, RECOVER_START, RECOVER_END)
    if block is None:
        return None
    return [ln.strip() for ln in live_bat(block)]


def whole_body(text):
    return [ln.strip() for ln in live_bat(norm(text).split("\n"))]


def preread_problems(text):
    """What is wrong with the pre-read, the loop entry that skips the first start, the announcement and the two callers."""
    body = recover_body(text)
    if body is None:
        return ["labels %s ... %s not found" % (RECOVER_START, RECOVER_END)]
    found = []
    first_start = next((i for i, ln in enumerate(body) if "Process]::Start" in ln), -1)
    loop = next((i for i, ln in enumerate(body) if ln == ":hidden_import_loop"), -1)
    if first_start < 0 or loop < 0:
        return ["the start line or :hidden_import_loop is missing from %s" % RECOVER_START]

    # 1. the pre-read: each step in its order, all before the loop and before the first start of the program
    at = -1
    for step in PREREAD:
        if step is None:
            nxt = next((i for i in range(at + 1, len(body)) if re.match(r'call :log "\[INFO\] Repair loop: .*%s' % NOREAD_TEXT, body[i])), -1)
            label = "the call :log line that says the error names no installed package"
        else:
            nxt = next((i for i in range(at + 1, len(body)) if body[i] == step), -1)
            label = step
        if nxt < 0:
            found.append("the pre-read lacks %r after step %d" % (label, at))
            break
        at = nxt
    else:
        if at > loop or at > first_start:
            found.append("the pre-read and the question are not before :hidden_import_loop and the first start of the program")
    noread = next((ln for ln in body if NOREAD_TEXT in ln and ":log" in ln), "")
    nr = next((i for i, ln in enumerate(body) if NOREAD_TEXT in ln and ":log" in ln), -1)
    if nr >= 0 and body[nr + 1:nr + 2] != ["exit /b 0"]:
        found.append("the no-package branch does not stop with 'exit /b 0' on the line after its log text")
    if re.search(r"[<>|&^%]", noread.split(":log", 1)[-1]):
        found.append(":log is called with a shell character in the no-package text: %s" % noread[:90])

    # 2. the first start is skipped when the pre-read found a package: the loop entry jumps to the rebuild
    found_label = [i for i, ln in enumerate(body) if ln == ":hidden_import_found"]
    jumps = [i for i, ln in enumerate(body) if ln == "if defined HP_NEXT_HIDDEN goto :hidden_import_found"]
    if len(found_label) != 1 or len(jumps) != 1:
        found.append(":hidden_import_found must be a label once and be jumped to once (found %d label(s), %d jump(s))" % (len(found_label), len(jumps)))
    else:
        if not jumps[0] < loop:
            found.append("the jump to :hidden_import_found is not before :hidden_import_loop, so a pre-read package would still start the program first")
        scan_guard = "if not defined HP_NEXT_HIDDEN goto :hidden_import_recover_done"
        if found_label[0] == 0 or body[found_label[0] - 1] != scan_guard or body[found_label[0] + 1] != "set /a HP_HIDDEN_ITER+=1":
            found.append(":hidden_import_found is not between the loop's own 'names nothing' stop and the iteration count")

    # 3. the announcement of the throwaway check stands in front of the first start of the call, once
    warns = [i for i, ln in enumerate(body) if WARN_CALL in ln]
    if len(warns) != 1:
        found.append("%d line(s) call :warn_user_code_launch hidden_import in %s; expected 1" % (len(warns), RECOVER_START))
    else:
        w = warns[0]
        if body[w] != "if not defined HP_HID_WARNED " + WARN_CALL or body[w + 1] != 'set "HP_HID_WARNED=1"':
            found.append("the announcement is not guarded by HP_HID_WARNED and recorded on the next line")
        if not loop < w < first_start:
            found.append("the announcement is not between :hidden_import_loop and the first start of the program")
    if not any(ln == 'set "HP_HID_WARNED="' for ln in body[:loop]):
        found.append('HP_HID_WARNED is not cleared before :hidden_import_loop, so a second call would not announce its start')
    if body.count('set "HP_HID_WARNED="') < 2:
        found.append("HP_HID_WARNED is not cleared again when the call ends")

    # 4. the consent wording says what the user agrees to now (one start after each rebuild, no start to read the error)
    block = cut_block(text, CONSENT_START, CONSENT_END) or []
    echoes = " ".join(ln.strip() for ln in live_bat(block) if re.search(r"(?i)(^|\s)echo\b", ln))
    for need in ("Its error says a package is missing", "up to three more starts", "up to seven"):
        if need not in echoes:
            found.append("the question no longer says %r" % need)
    for gone in ("up to four more starts", "up to eight", "starts your program again to read its error"):
        if gone in echoes:
            found.append("the question still says %r although the first read needs no start" % gone)
    return found


def caller_problems(text):
    """The two callers of the loop: the second one is the only one that sets HP_HID_REREAD, and the DLL flag is cleared first."""
    body = whole_body(text)
    found = []
    sets = [i for i, ln in enumerate(body) if ln == 'set "HP_HID_REREAD=1"']
    clears = [i for i, ln in enumerate(body) if ln == 'set "HP_HID_REREAD="']
    reads = [i for i, ln in enumerate(body) if re.search(r"\bdefined\s+HP_HID_REREAD\b", ln)]
    if len(sets) != 1 or len(clears) != 1 or len(reads) != 1:
        return ["HP_HID_REREAD is set on %d, cleared on %d and read on %d live line(s); expected 1, 1 and 1" % (len(sets), len(clears), len(reads))]
    guard = [i for i, ln in enumerate(body) if ln == "if defined HP_DLL_REPAIRED ("]
    if len(guard) != 1:
        return ["%d live 'if defined HP_DLL_REPAIRED (' line(s); expected 1" % len(guard)]
    g = guard[0]
    if body[g + 1:g + 5] != ['set "HP_HID_REREAD=1"', "call :hidden_import_recover", 'set "HP_HID_REREAD="', ")"]:
        found.append("the second call is not 'set HP_HID_REREAD=1', the call, 'set HP_HID_REREAD=' inside the HP_DLL_REPAIRED block")
    gate = [i for i, ln in enumerate(body) if ln == 'if not "%HP_EXE_EXIT%"=="-1" if defined HP_HIDDEN_REPAIRED call :dll_bundle_recover']
    if len(gate) != 1:
        found.append("%d live second-pass gate line(s); expected 1" % len(gate))
    elif body[gate[0] - 1] != 'set "HP_DLL_REPAIRED="':
        found.append("HP_DLL_REPAIRED is not cleared on the line before the second-pass gate, so a repair of the build-time pass would start the program again for nothing")
    first_call = [i for i, ln in enumerate(body) if ln == 'if not "%HP_EXE_EXIT%"=="-1" call :hidden_import_recover']
    if len(first_call) != 1:
        found.append("%d live first call line(s); expected 1" % len(first_call))
    elif sets and not (first_call[0] < gate[0] < sets[0]):
        found.append("the first call, the second-pass gate and the second call are not in this order")
    return found


def script_pattern_problems(text):
    """The row script's regex for the no-package log line must match the line the batch logs."""
    m = re.search(r"\$noReadPattern\s*=\s*'([^']+)'", text)
    if not m:
        return ["the script has no $noReadPattern"]
    body = recover_body(BAT.read_text(encoding="utf-8", errors="replace"))
    line = next((ln for ln in body or [] if NOREAD_TEXT in ln and ":log" in ln), "")
    if not re.search(m.group(1), line):
        return ["the script's pattern %r does not match the batch's no-package line %r" % (m.group(1), line[:90])]
    return []


class RealBatch(unittest.TestCase):
    def setUp(self):
        self.text = norm(BAT.read_text(encoding="utf-8", errors="replace"))

    def test_the_pre_read_the_loop_entry_and_the_announcement_are_in_place(self):
        self.assertEqual(preread_problems(self.text), [])

    def test_only_the_second_call_rereads_and_the_dll_flag_is_cleared_first(self):
        self.assertEqual(caller_problems(self.text), [])

    def test_the_row_script_matches_the_line_the_batch_logs(self):
        self.assertEqual(script_pattern_problems(SCRIPT.read_text(encoding="utf-8")), [])

    def test_the_checks_are_not_vacuous(self):
        body = recover_body(self.text)
        self.assertGreater(len(body), 60)
        self.assertEqual(sum(1 for ln in body if "Process]::Start" in ln), 1)
        self.assertEqual(len([s for s in PREREAD]), 17)


class RulesCanFail(unittest.TestCase):
    """Each rule is shown to fail on a mutation of the real text."""

    def setUp(self):
        self.text = norm(BAT.read_text(encoding="utf-8", errors="replace"))

    def assertCaught(self, found, needle):
        self.assertTrue(any(needle in f for f in found), (needle, found))

    def test_a_second_call_that_reads_stale_files_is_caught(self):
        text = mutate(self.text, "if defined HP_HID_REREAD goto :hidden_import_ask\n", "rem removed\n")
        self.assertCaught(preread_problems(text), "if defined HP_HID_REREAD goto :hidden_import_ask")
        text = mutate(self.text, 'set "HP_HID_REREAD=1"\n', "rem removed\n")
        self.assertCaught(caller_problems(text), "HP_HID_REREAD")
        text = mutate(self.text, '  set "HP_HID_REREAD="\n)', "  rem removed\n)")
        self.assertCaught(caller_problems(text), "HP_HID_REREAD")

    def test_a_pre_read_that_leaves_its_file_or_never_joins_the_output_is_caught(self):
        scan = SCAN_LINE + "\n"
        text = mutate(self.text, scan, "rem removed\n")
        self.assertCaught(preread_problems(text), "hidden_import_scan.py")
        text = mutate(self.text, 'if exist "~run.err.txt" type "~run.err.txt" >> "dist\\~exe_out.txt"\n', "rem removed\n")
        self.assertCaught(preread_problems(text), "~run.err.txt")
        text = mutate(self.text, "if defined HP_NEXT_HIDDEN goto :hidden_import_ask\n", "rem removed\n")
        self.assertCaught(preread_problems(text), "if defined HP_NEXT_HIDDEN goto :hidden_import_ask")

    def test_a_no_package_branch_that_says_nothing_or_does_not_stop_is_caught(self):
        text = mutate(self.text, NOREAD_TEXT, "names nothing")
        self.assertCaught(preread_problems(text), "names no installed package")
        text = mutate(self.text, "exit /b 0\nrem CLAUDE.md Item 97 (README REQ-018.1 and REQ-018.2): every start", "rem x\nrem CLAUDE.md Item 97 (README REQ-018.1 and REQ-018.2): every start")
        self.assertCaught(preread_problems(text), "exit /b 0")

    def test_a_loop_that_still_starts_the_program_first_is_caught(self):
        text = mutate(self.text, "if defined HP_NEXT_HIDDEN goto :hidden_import_found\n", "rem removed\n")
        self.assertCaught(preread_problems(text), ":hidden_import_found")
        text = mutate(self.text, "\n:hidden_import_found\n", "\nrem removed\n")
        self.assertCaught(preread_problems(text), ":hidden_import_found")

    def test_an_announcement_in_the_wrong_place_or_unguarded_is_caught(self):
        guarded = "if not defined HP_HID_WARNED " + WARN_CALL
        text = mutate(self.text, guarded + "\n", WARN_CALL + "\n")
        self.assertCaught(preread_problems(text), "not guarded")
        text = mutate(self.text, guarded + "\n", "rem removed\n")
        self.assertCaught(preread_problems(text), "expected 1")
        text = mutate(self.text, ":hidden_import_loop\n" + guarded + "\n", guarded + "\n:hidden_import_loop\n")
        self.assertCaught(preread_problems(text), "not between :hidden_import_loop")
        text = mutate(self.text, 'set "HP_HID_WARNED="\nif defined HP_NEXT_HIDDEN goto :hidden_import_found', 'if defined HP_NEXT_HIDDEN goto :hidden_import_found')
        self.assertCaught(preread_problems(text), "HP_HID_WARNED is not cleared")

    def test_the_old_question_wording_is_caught(self):
        text = mutate(self.text, "up to three more starts, and up to seven", "up to four more starts, and up to eight")
        found = preread_problems(text)
        self.assertCaught(found, "up to three more starts")
        self.assertCaught(found, "up to four more starts")

    def test_a_stale_dll_flag_that_can_start_the_program_again_is_caught(self):
        text = mutate(self.text, 'set "HP_DLL_REPAIRED="\nif not "%HP_EXE_EXIT%"=="-1" if defined HP_HIDDEN_REPAIRED call :dll_bundle_recover', 'rem x\nif not "%HP_EXE_EXIT%"=="-1" if defined HP_HIDDEN_REPAIRED call :dll_bundle_recover')
        self.assertCaught(caller_problems(text), "HP_DLL_REPAIRED is not cleared")

    def test_a_pattern_in_the_row_script_that_cannot_match_is_caught(self):
        script = SCRIPT.read_text(encoding="utf-8")
        text = mutate(script, "$noReadPattern = 'Repair loop: .*names no installed package'", "$noReadPattern = 'Repair loop: .*no package named'")
        self.assertTrue(script_pattern_problems(text))
        self.assertTrue(script_pattern_problems("# no pattern here"))


if __name__ == "__main__":
    unittest.main()

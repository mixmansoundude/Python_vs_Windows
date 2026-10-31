"""Item 94a: a prompt that offers another run of the user's program names the risk, and the syntax-error report says
whose mistake it is (README REQ-018.2, REQ-018.8, REQ-018.25 and REQ-021.3).

REQ-018.2 [critical] asks for the user's consent "in a prompt that names the risk that the program may not be safe to
run twice" before any run beyond the single automatic run. Four prompts offer such a run: the post-execution checkpoint
(REQ-018.8 asks for the side-effect and idempotency risk by name), the optimized build (its sentence "so say no if
running it twice could cause harm" is the wording the README notes quote), the install of a package the program asked
for (REQ-018.14; the yes also covers one check run) and the Miniconda choice of the last-chance offer (REQ-018.25 says
the program runs once more). The optimized build named the risk; the other three said only that the program runs
again, which a person who is about to type Y cannot weigh. REQ-021.3 asks the syntax-error report to state that the
mistake is in the user's program and not in dependency installation or the EXE build; the report named the file and
the error but not whose mistake it was.

These rules read run_setup.bat as text, so a prompt added later is held to the same wording. What the user really sees
is checked on the console text of real runs by self.checkpoint.risk, self.runtime.install.risk, self.lastchance.risk
and self.preflight.attribution. Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

MARKER = "running it twice could cause harm"

# (name, heading text of the prompt, text of the first line after the prompt: where the answer is read)
PROMPTS = (
    ("post-execution checkpoint", "Verification finished -- see the Run Status above.", 'set "HP_CHECKPOINT_RAW="'),
    ("optimized build", "Your app is ready.", 'set "HP_OPTBUILD_RAW="'),
    ("runtime install", "Your program asked for packages that are not installed:", 'set "HP_RTI_CHOICE="'),
    ("last chance", "Your program stopped with an error, exit code", 'set "HP_LC_CHOICE="'),
)

# A line that tells the user the program runs again. Only an echo line counts: a log line for a setting the user
# chose (PVW_BUILDER=both) is covered by that setting, and a comment is not shown.
RERUN = re.compile(r"\b(again|once more|one more time|second time)\b", re.I)
WINDOW = 6

PREFLIGHT_HEADING = "Your Python program has a syntax error and cannot run."
PREFLIGHT_END = "Fix the syntax error shown above"


def is_echo(line):
    stripped = line.strip()
    if re.match(r"(?i)(rem\b|::)", stripped):
        return False
    return re.search(r"(?i)(^|\s)echo\b", stripped) is not None


def lines_of(text):
    return text.replace("\r\n", "\n").split("\n")


def find_line(lines, needle, start=0):
    for i in range(start, len(lines)):
        if needle in lines[i] and is_echo(lines[i]):
            return i
    return -1


def prompt_problems(text):
    """Each of PROMPTS has its heading and its marker, and the last-chance marker sits in the [C] choice."""
    lines = lines_of(text)
    found = []
    for name, heading, gate in PROMPTS:
        head = find_line(lines, heading)
        if head < 0:
            found.append("%s: heading %r not found as an echo line" % (name, heading))
            continue
        end = next((i for i in range(head, len(lines)) if gate in lines[i]), -1)
        if end < 0:
            found.append("%s: the line that reads the answer (%s) was not found after the heading" % (name, gate))
            continue
        block = [ln for ln in lines[head:end] if is_echo(ln)]
        if not any(MARKER in ln for ln in block):
            found.append("%s: the prompt never says %r" % (name, MARKER))
            continue
        if name == "last chance":
            c = next((i for i, ln in enumerate(block) if "[C]" in ln), -1)
            n = next((i for i, ln in enumerate(block) if "[N]" in ln), -1)
            inside = [ln for ln in block[c:n] if MARKER in ln] if 0 <= c < n else []
            if not inside:
                found.append("last chance: the risk is not said inside the [C] choice (between [C] and [N])")
    return found


def rerun_problems(text):
    """Every echo line that says 'your program' runs again has the marker in an echo line within WINDOW lines."""
    lines = lines_of(text)
    found = []
    for i, ln in enumerate(lines):
        if not is_echo(ln) or "your program" not in ln.lower() or not RERUN.search(ln):
            continue
        lo, hi = max(0, i - WINDOW), min(len(lines), i + WINDOW + 1)
        if not any(MARKER in near and is_echo(near) for near in lines[lo:hi]):
            found.append("line %d says the program runs again without %r within %d lines: %s"
                         % (i + 1, MARKER, WINDOW, ln.strip()[:120]))
    return found


def preflight_problems(text):
    """REQ-021.3: between the syntax-error heading and its closing line an echo line names the user's own program
    and says the mistake is not in the dependencies or the EXE."""
    lines = lines_of(text)
    head = find_line(lines, PREFLIGHT_HEADING)
    if head < 0:
        return ["preflight: heading %r not found as an echo line" % PREFLIGHT_HEADING]
    end = find_line(lines, PREFLIGHT_END, head)
    if end < 0:
        return ["preflight: the closing line %r was not found after the heading" % PREFLIGHT_END]
    block = " ".join(ln for ln in lines[head:end] if is_echo(ln)).lower()
    found = []
    if "own program" not in block:
        found.append("preflight: the report does not say the mistake is in the user's own program")
    if "dependenc" not in block:
        found.append("preflight: the report does not rule out dependency installation")
    if " exe" not in block.replace("the exe", " exe"):
        found.append("preflight: the report does not rule out the EXE build")
    return found


def problems(text):
    return prompt_problems(text) + rerun_problems(text) + preflight_problems(text)


class RealBatch(unittest.TestCase):
    def setUp(self):
        self.text = (REPO / "run_setup.bat").read_text(encoding="utf-8", errors="replace")

    def test_every_prompt_that_offers_another_run_names_the_risk(self):
        self.assertEqual(prompt_problems(self.text), [])

    def test_no_echo_line_says_the_program_runs_again_without_the_risk_nearby(self):
        self.assertEqual(rerun_problems(self.text), [])

    def test_the_syntax_error_report_says_whose_mistake_it_is(self):
        self.assertEqual(preflight_problems(self.text), [])

    def test_the_heuristic_is_not_vacuous_on_the_real_file(self):
        # the four prompts that exist today all say "your program" and a rerun word; if none matched, the rule above
        # would pass on a file whose wording moved away from what it looks for
        hits = [ln for ln in lines_of(self.text)
                if is_echo(ln) and "your program" in ln.lower() and RERUN.search(ln)]
        self.assertGreaterEqual(len(hits), 4, hits)


GOOD = """\
echo.
echo *** Verification finished -- see the Run Status above. ***
echo *** You can run your program again now via the interpreter as an extra diagnostic check. (Optional) ***
echo *** That runs your program a second time, so say no if running it twice could cause harm. ***
set "HP_CHECKPOINT_RAW="
echo *** Your app is ready. ***
echo *** Building it starts your program once more for up to 30 seconds, so say no if running it twice could cause harm. ***
set "HP_OPTBUILD_RAW="
echo *** Your program asked for packages that are not installed: ***
echo *** It rebuilds the EXE if there is one, and runs your program one more time to check. ***
echo *** Saying yes also allows that extra run, so say no if running it twice could cause harm. ***
set "HP_RTI_CHOICE="
echo *** Your program stopped with an error, exit code %HP_LC_EXIT%. ***
echo ***   [W] It actually worked. Nothing needs to change. ***
echo ***   [C] Try again with Miniconda. This downloads it if needed and runs your program once more. ***
echo ***       Do not choose it if running it twice could cause harm. ***
echo ***   [N] Neither. Keep this build. This is the default. ***
set "HP_LC_CHOICE="
echo *** [ERROR] REQ-021: Your Python program has a syntax error and cannot run. ***
echo *** File: "%HP_ENTRY%" ***
echo *** The mistake is in your own program. It is not a problem with installing dependencies or with building the EXE. ***
echo *** Fix the syntax error shown above, then run this batch again. ***
"""


class EachRuleCanFail(unittest.TestCase):
    def test_the_good_fixture_passes(self):
        self.assertEqual(problems(GOOD), [])

    def test_a_prompt_without_the_marker_is_named(self):
        for name, hit in (("post-execution checkpoint", "That runs your program a second time"),
                          ("runtime install", "Saying yes also allows"),
                          ("last chance", "Do not choose it")):
            bad = "\n".join(ln for ln in GOOD.split("\n") if hit not in ln)
            found = problems(bad)
            self.assertTrue(any(f.startswith(name) for f in found), (name, found))

    def test_the_optimized_build_prompt_is_held_to_it_too(self):
        bad = GOOD.replace(", so say no if running it twice could cause harm", "")
        self.assertTrue(any(f.startswith("optimized build") for f in prompt_problems(bad)))

    def test_a_marker_outside_the_c_choice_does_not_count_for_it(self):
        bad = GOOD.replace("echo ***       Do not choose it if running it twice could cause harm. ***\n", "") \
                  .replace("echo ***   [N] Neither. Keep this build. This is the default. ***",
                           "echo ***   [N] Neither. Keep this build. This is the default. ***\n"
                           "echo *** Only say yes if running it twice could cause harm. Not that. ***")
        bad = bad.replace("Only say yes if running it twice could cause harm. Not that.",
                          "Say no if running it twice could cause harm.")
        self.assertIn("last chance: the risk is not said inside the [C] choice (between [C] and [N])",
                      prompt_problems(bad))

    def test_a_moved_heading_is_reported_not_skipped(self):
        bad = GOOD.replace("Your app is ready.", "Done.")
        self.assertTrue(any("heading" in f and f.startswith("optimized build") for f in prompt_problems(bad)))

    def test_a_new_echo_line_that_reruns_the_program_needs_the_marker_nearby(self):
        bad = GOOD + "echo *** Your program will start again in a moment. ***\n"
        found = rerun_problems(bad)
        self.assertEqual(len(found), 1, found)
        self.assertIn("Your program will start again", found[0])

    def test_the_marker_far_away_does_not_count(self):
        bad = GOOD + "\n".join(["echo filler"] * (WINDOW + 3)) + "\necho *** Your program runs once more. ***\n"
        self.assertEqual(len(rerun_problems(bad)), 1)

    def test_a_log_line_or_a_comment_is_not_a_prompt(self):
        extra = ('call :log "[INFO] PVW_BUILDER=both: the program starts once more for up to 30 seconds."\n'
                 'rem Your program runs once more here.\n'
                 'echo Move run_setup.bat next to your scripts, then run it again.\n')
        self.assertEqual(rerun_problems(GOOD + extra), [])

    def test_an_if_prefixed_echo_counts_as_an_echo_line(self):
        bad = GOOD + 'if defined X echo *** Your program is started again. ***\n'
        self.assertEqual(len(rerun_problems(bad)), 1)

    def test_the_preflight_report_must_name_whose_mistake_it_is(self):
        bad = GOOD.replace(
            "echo *** The mistake is in your own program. It is not a problem with installing dependencies "
            "or with building the EXE. ***\n", "")
        found = preflight_problems(bad)
        self.assertEqual(len(found), 3, found)

    def test_the_preflight_report_must_rule_out_both_the_dependencies_and_the_exe(self):
        only_exe = GOOD.replace("installing dependencies or with building the EXE",
                                "building the EXE")
        self.assertEqual(preflight_problems(only_exe),
                         ["preflight: the report does not rule out dependency installation"])
        only_deps = GOOD.replace("installing dependencies or with building the EXE",
                                 "installing dependencies")
        self.assertEqual(preflight_problems(only_deps),
                         ["preflight: the report does not rule out the EXE build"])

    def test_a_missing_preflight_block_is_reported(self):
        bad = GOOD.replace("Your Python program has a syntax error and cannot run.", "Something is wrong.")
        self.assertEqual(len(preflight_problems(bad)), 1)
        self.assertIn("heading", preflight_problems(bad)[0])


if __name__ == "__main__":
    unittest.main()

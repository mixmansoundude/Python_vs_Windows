"""Item 123 (README REQ-007.20): every console message of run_setup.bat about building or verifying names the EXE or the tool.

README REQ-007.20 says that a message about the build, the verification or the failure of the executable names the artifact and the
tool in plain words ("EXE", "PyInstaller", "standalone .exe"), so that a user can tell the message is about the optional one-file
executable and not about the environment or the dependencies, which are already installed and usable. Until this item the README
called that "not checked": 33 messages of run_setup.bat said build, rebuild, package, bundle or verify and named neither
(`Optimized build: declined.`, `the next run will rebuild.`, `Building with the fallback build system only.`), and nothing could
find the next one.

tools/exe_wording.py is the rule. `check` reads every console message of run_setup.bat (a `call :log` text, a tagged call, a block of
consecutive `echo` lines, an inline `if ... echo`, a `set /p` or `choice /M` prompt) and holds each one that talks about building,
bundling, packaging or verifying to it: it names the artifact or the tool, or its exact text is listed in tests/exe_wording_exempt.txt
under a category that says why it is about something else. An entry that no message reads any more, one the message no longer needs
and a category nobody uses are reported too, so the list can only shrink or be re-decided on purpose (and a count cap below makes
growing it a deliberate change of this file). `console` judges the timestamped lines of a real run the same way, which is how the
scenario tests/selfapps_sysbuild_accept.ps1 reads the console of a run that answers yes to the system-Python build question.

These rules read the tool, the exempt list and run_setup.bat, and run the tool on synthetic batch files (one that is clean and a
mutation of it for each rule), so a reworded message, a new message, an entry gone stale or a reader that stops reading fails here
with a sentence that names the line, before a Windows run is needed. Synthetic cases prove each rule can fail.
ASCII only.
"""
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from judge_support import lines_of, mutate  # noqa: E402

from tools import exe_wording as ew  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
BATCH = REPO / "run_setup.bat"
TOOL = REPO / "tools" / "exe_wording.py"
RULES = REPO / "tests" / "exe_wording_exempt.txt"

# The exempt list may shrink. It grows only by changing this number in the same change as the entry and the reason for it.
MAX_EXEMPT_ENTRIES = 34

GOOD = "\n".join([
    "@echo off",
    "rem Building, packaging and verifying are named in this comment, which is not a console message.",
    ":main",
    'call :log "[INFO] Downloading the tools."',
    'call :log "[INFO] Building standalone executable -- this may take a minute or two..."',
    'call :log "[DEBUG] Verification detail that a user does not see."',
    'call :log "[INFO] REQ-009: cascade declined; keeping current build."',
    'call :hint "[HINT] The PyInstaller build did not finish."',
    "echo Setting up your Python environment.",
    "echo This can take a few minutes.",
    "echo.",
    "echo Packaging your app as a standalone EXE now.",
    "echo The program is still being built; nothing else is needed.",
    "if defined HP_FLAG echo Verifying the executable.",
    "set /p ANSWER=Build the standalone EXE now? [Y/N] ",
    'choice /C YN /N /T 30 /D N /M "Build the program as an EXE? [Y/N] "',
    'echo built > "%TEMP%\\built.txt"',
    'call :log "[TEST] HP_TEST_FORCE_FAIL: building nothing."',
    'call :log "[INFO] Install Visual Studio Build Tools to compile it."',
    "exit /b 0",
    ":second",
    "echo Back in the second part; nothing about the EXE here.",
    "exit /b 0",
    "",
])
GOOD_RULES = "\n".join([
    "# A comment and an empty line are ignored.",
    "",
    "category: provider | the message is about moving to another Python provider or keeping the current one",
    "provider | [INFO] REQ-009: cascade declined; keeping current build.",
    "",
])


def check_text(batch_text, rules_text=GOOD_RULES):
    return ew.check(batch_text, ew.parse_rules(rules_text))


def with_lines(*new_lines, text=GOOD):
    """The batch text with the lines inserted right after its :main label, and the line number of the first of them."""
    mutated = mutate(text, ":main\n", ":main\n" + "\n".join(new_lines) + "\n")
    return mutated, lines_of(mutated).index(new_lines[0]) + 1


def read(path):
    return Path(path).read_bytes().decode("ascii")


def run_main(argv):
    """ew.main(argv) with its output captured: (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = ew.main(argv)
    return code, out.getvalue(), err.getvalue()


def msgs(text):
    return [(kind, t) for _, _, kind, t in ew.messages(text)]


def violation_texts(bat_text, rules):
    """The text of each message that breaks the rule; unlike the problem lines it does not change when a line is inserted above."""
    return [text for _, _, _, text, status in ew.classify(bat_text, rules) if status == "violation"]


class MessageReader(unittest.TestCase):
    """messages(): what the tool counts as a console message of a batch file."""

    def test_a_log_call_is_one_message_with_its_line_and_its_label(self):
        batch = ':one\ncall :log "[INFO] first"\n:two\ncall :log "[WARN] second   spaced"\n'
        self.assertEqual(ew.messages(batch), [(2, "one", "log", "[INFO] first"), (4, "two", "log", "[WARN] second spaced")])

    def test_a_tagged_call_of_another_subroutine_is_a_message_and_an_untagged_one_is_not(self):
        batch = ':a\ncall :hint "[HINT] Packaging failed."\ncall :emit "Packaging failed."\ncall :row "state" "x"\n'
        self.assertEqual(msgs(batch), [("log", "[HINT] Packaging failed.")])

    def test_consecutive_echo_lines_are_one_message(self):
        batch = ":a\necho first line\necho second line\necho.\necho third\n:b\necho fourth\n"
        self.assertEqual(msgs(batch), [("echo", "first line second line"), ("echo", "third"), ("echo", "fourth")])

    def test_a_command_or_a_comment_between_echo_lines_ends_the_block(self):
        self.assertEqual(msgs(":a\necho one\nset X=1\necho two\n"), [("echo", "one"), ("echo", "two")])
        self.assertEqual(msgs(":a\necho one\nrem note\necho two\n"), [("echo", "one"), ("echo", "two")])
        self.assertEqual(msgs(":a\necho one\n:: note\necho two\n"), [("echo", "one"), ("echo", "two")])

    def test_a_comment_is_not_a_message(self):
        self.assertEqual(msgs(":a\nrem echo Building it\n:: call :log \"[INFO] Building it\"\nREM echo again\n"), [])

    def test_an_echo_that_writes_a_file_or_feeds_a_pipe_is_not_a_message(self):
        for line in (
            'echo x > "f.txt"',
            "echo x>f.txt",
            '>> "%LOG%" echo x',
            "> f.txt echo x",
            "echo x | findstr y",
            'echo "%V%"| findstr /l /c:"y" >nul',
            "(echo a) > f.txt",
            "(echo a & echo b) > f.txt",
        ):
            with self.subTest(line=line):
                # The whole line goes to the file or the pipe, so nothing of it is a console message. The first version of this
                # check asked only that `x` and `Bundling` were absent, which no line here prints, and the group lines passed.
                self.assertEqual(msgs(":a\n" + line + "\n"), [])
        self.assertEqual(msgs(':a\necho Building > "f.txt"\n'), [])
        self.assertEqual(msgs(":a\n>> \"%LOG%\" echo Building it\n"), [])

    def test_every_command_of_a_group_that_a_redirect_or_a_pipe_follows_writes_to_it(self):
        for line in (
            "(echo Building the widget & echo done) > f.txt",
            '(echo first & echo Bundling now) >> "%LOG%" 2>&1',
            "if defined X (echo Building it & echo Rebuilding it) > nul",
            "(echo Building it & echo done) | findstr y",
            '(call :log "[INFO] Building it." & call :log "[INFO] Bundling it.") >> "%LOG%"',
            "( (echo a) & echo Building it ) > f.txt",
            # A parenthesis inside quotes is not a bracket of the group.
            '(echo "x)" & echo Building it) > f.txt',
            "(echo a & echo Building it)>f.txt",
        ):
            with self.subTest(line=line):
                self.assertEqual(msgs(":a\n" + line + "\n"), [])
        # What stands outside the group is still read, and the redirect of a command that is not the group's is that command's own.
        self.assertEqual(msgs(":a\necho before & (echo Building it & echo done) > f.txt\n"), [("echo", "before")])
        self.assertEqual(msgs(":a\n(echo a & echo b) > f.txt & echo after\n"), [("echo", "after")])
        self.assertEqual(msgs(":a\n(echo a) & echo b > f.txt\n"), [("echo", "a")])

    def test_a_group_whose_redirects_are_for_standard_error_or_input_still_prints(self):
        # Only a redirect of standard output (`>`, `>>`, `1>`, a pipe) sends what a group echoes away. `2>` and `2>&1` are about
        # standard error, `<` is about standard input, and `>&2` writes to standard error, which is the console. The first
        # version of the reader treated every `<` and `>` after a group alike, so `( ... ) 2>nul` lost its messages (CodeRabbit,
        # PR #537).
        both = [("echo", "a"), ("echo", "Building it")]
        for line in (
            "(echo a & echo Building it) 2> f.txt",
            "(echo a & echo Building it) 2>> f.txt",
            "(echo a & echo Building it) 2>nul",
            "(echo a & echo Building it) 2>&1",
            "(echo a & echo Building it) < in.txt",
            "(echo a & echo Building it) 2>nul < in.txt",
            "(echo a & echo Building it) >&2",
            "(echo a & echo Building it) 1>&2",
            "if defined X (echo a & echo Building it) 2>nul",
        ):
            with self.subTest(line=line):
                self.assertEqual(msgs(":a\n" + line + "\n"), both)

    def test_a_group_is_hidden_when_any_redirect_of_its_chain_takes_standard_output(self):
        for line in (
            "(echo a & echo Building it) 2>&1 > f.txt",
            "(echo a & echo Building it) < in.txt > f.txt",
            "(echo a & echo Building it) 2> err.txt > f.txt",
            "(echo a & echo Building it) 1> f.txt",
            "(echo a & echo Building it) 1>> f.txt",
            "(echo a & echo Building it) > f.txt 2>&1",
            "(echo a & echo Building it) 2> err.txt | findstr y",
            "(echo a & echo Building it) 2>nul >nul",
        ):
            with self.subTest(line=line):
                self.assertEqual(msgs(":a\n" + line + "\n"), [])
        # cmd reads the redirects from left to right: `>&2` copies standard error as it is at that moment. After `2>nul` that is the
        # null device, so the echoes are gone; in front of it, it is the console, and they stay.
        self.assertEqual(msgs(":a\n(echo a & echo Building it) 2>nul >&2\n"), [])
        self.assertEqual(msgs(":a\n(echo a & echo Building it) >&2 2>nul\n"), [("echo", "a"), ("echo", "Building it")])

    def test_an_echo_whose_redirects_are_for_standard_error_or_input_is_a_message_without_them(self):
        want = [("echo", "Building the widget")]
        for line in (
            "echo Building the widget 2> f.txt",
            "echo Building the widget 2>nul",
            "echo Building the widget 2>&1",
            "echo Building the widget < f.txt",
            "echo Building the widget >&2",
            "echo Building the widget 1>&2",
            "echo Building the widget 2> f.txt < g.txt",
            "2>nul echo Building the widget",
            "< f.txt echo Building the widget",
        ):
            with self.subTest(line=line):
                self.assertEqual(msgs(":a\n" + line + "\n"), want)
        # The text of the redirect is not part of the message.
        self.assertEqual(msgs(":a\necho Building the widget 2> f.txt\necho and more 2>nul\n"), [("echo", "Building the widget and more")])

    def test_a_digit_is_a_handle_only_at_the_start_of_a_word(self):
        # `echo Step 2> f.txt` redirects standard error (the message is `Step`); a digit that ends a word, as in the usual
        # `echo %TIME%>>log`, or that a space separates from the `>` is text, and the redirect takes standard output.
        self.assertEqual(msgs(":a\necho Step 2> f.txt\n"), [("echo", "Step")])
        self.assertEqual(msgs(":a\necho Step 2 > f.txt\n"), [])
        self.assertEqual(msgs(":a\necho Step2> f.txt\n"), [])
        self.assertEqual(msgs(":a\n(echo Step 2) > f.txt\n"), [])
        self.assertEqual(msgs(":a\n(echo a & echo Building it) 1>f.txt\n"), [])
        # The last redirect of standard output decides: copied to standard error first, then sent to a file, the text is in the file.
        self.assertEqual(msgs(":a\necho Building the widget >&2 >f.txt\n"), [])

    def test_a_log_call_whose_redirects_are_for_standard_error_or_input_is_still_a_message(self):
        want = [("log", "[INFO] Building it.")]
        for tail in ("2>nul", '2>> "%LOG%"', "2>&1", "< f.txt", ">&2"):
            with self.subTest(tail=tail):
                self.assertEqual(msgs(':a\ncall :log "[INFO] Building it." %s\n' % tail), want)
        for tail in ('>> "%LOG%" 2>&1', "2>&1 >nul", "1>nul", "| findstr y"):
            with self.subTest(tail=tail):
                self.assertEqual(msgs(':a\ncall :log "[INFO] Building it." %s\n' % tail), [])

    def test_a_redirect_of_the_next_branch_does_not_hide_a_log_call(self):
        # What follows the call is the command's own redirects up to the parenthesis that closes its group; the other branch of the
        # `if` is another command.
        self.assertEqual(msgs(':a\nif defined X (call :log "[INFO] Building it.") else (echo a > f.txt)\n'), [("log", "[INFO] Building it.")])
        self.assertEqual(msgs(':a\nif defined X (call :log "[INFO] Building it." > f.txt) else (echo b)\n'), [("echo", "b")])

    def test_a_group_that_nothing_redirects_keeps_every_command(self):
        self.assertEqual(msgs(":a\n(echo a & echo b)\n"), [("echo", "a"), ("echo", "b")])
        self.assertEqual(msgs(":a\n(echo a & echo b) & echo c\n"), [("echo", "a"), ("echo", "b"), ("echo", "c")])
        self.assertEqual(msgs(":a\nif defined X (echo a) else (echo b)\n"), [("echo", "a"), ("echo", "b")])
        self.assertEqual(msgs(":a\nfor %%I in (a b) do echo Verifying %%I\n"), [("echo", "Verifying %%I")])
        # `||` runs the next command when the group fails: it is not a pipe, so the group still prints.
        self.assertEqual(msgs(":a\n(echo a & echo b) || echo c\n"), [("echo", "a"), ("echo", "b"), ("echo", "c")])
        # Parentheses in the text of an echo are not groups, and a caret-escaped pair is text whatever follows it.
        self.assertEqual(msgs(":a\necho Building (the EXE) now\n"), [("echo", "Building (the EXE) now")])
        self.assertEqual(msgs(":a\necho Building ^(the EXE^) now\n"), [("echo", "Building (the EXE) now")])

    def test_a_closing_parenthesis_escaped_by_a_caret_is_text_and_does_not_end_the_group(self):
        self.assertEqual(msgs(":a\nif defined FLAG (echo Note ^) Building the widget)\n"), [("echo", "Note ) Building the widget")])
        self.assertEqual(msgs(":a\necho Step 1^) Verifying the widget\n"), [("echo", "Step 1) Verifying the widget")])
        self.assertEqual(msgs(":a\nif defined A (echo ^(one^) Building it) else (echo ^(two^) Rebuilding it)\n"),
                         [("echo", "(one) Building it"), ("echo", "(two) Rebuilding it")])
        # An unescaped one still ends it, and what follows is the next branch.
        self.assertEqual(msgs(":a\nif defined A (echo one) else (echo two)\n"), [("echo", "one"), ("echo", "two")])
        # An even run of carets escapes the caret, not the parenthesis.
        self.assertEqual(msgs(":a\nif defined A (echo one^^) else (echo two)\n"), [("echo", "one^"), ("echo", "two")])

    def test_the_rest_of_a_line_is_read_after_a_log_call_a_tagged_call_or_a_prompt(self):
        self.assertEqual(msgs(':a\ncall :log "[INFO] PyInstaller is ready." & echo Building the widget\n'),
                         [("log", "[INFO] PyInstaller is ready."), ("echo", "Building the widget")])
        self.assertEqual(msgs(':a\ncall :hint "[HINT] Packaging failed." & echo Rebuilding the widget\n'),
                         [("log", "[HINT] Packaging failed."), ("echo", "Rebuilding the widget")])
        self.assertEqual(msgs(':a\nchoice /C YN /N /M "Verify it? [Y/N] " & echo Building the widget\n'),
                         [("prompt", "Verify it? [Y/N]"), ("echo", "Building the widget")])
        self.assertEqual(msgs(':a\nif defined X call :log "[INFO] one." & if defined Y echo two\n'),
                         [("log", "[INFO] one."), ("echo", "two")])
        # A line that is only a log call or a prompt adds nothing else, and it still ends a block of echo lines.
        self.assertEqual(msgs(':a\ncall :log "[INFO] one." >> "%LOG%" & echo after\n'), [("echo", "after")])
        self.assertEqual(msgs(':a\necho one\ncall :log "[INFO] x"\necho two\n'), [("echo", "one"), ("log", "[INFO] x"), ("echo", "two")])
        self.assertEqual(msgs(':a\necho one\nchoice /C YN /M "Q? "\necho two\n'), [("echo", "one"), ("prompt", "Q?"), ("echo", "two")])

    def test_a_caret_escaped_redirect_is_text(self):
        self.assertEqual(msgs(":a\necho the symbol ^> here\n"), [("echo", "the symbol > here")])

    def test_a_call_that_writes_its_text_to_a_file_is_not_a_message(self):
        self.assertEqual(msgs(':a\ncall :log "[INFO] Building it." >> "%LOG%"\n'), [])
        self.assertEqual(msgs(':a\ncall :log "[INFO] Building it." >nul\n'), [])
        self.assertEqual(msgs(':a\ncall :log "[INFO] Building it."\n'), [("log", "[INFO] Building it.")])

    def test_inline_if_and_for_forms_are_read(self):
        batch = ":a\n".join(["", "if defined HP_X echo Verifying the executable.\n", 'if not exist "f.txt" if defined Y echo second\n',
                             'if "%A%"=="1" (echo third) else echo fourth\n', "if errorlevel 1 echo fifth\n",
                             'if /i "%A%"=="y" echo sixth\n', 'for /f "delims=" %%I in (list.txt) do echo Verifying %%I\n'])
        self.assertEqual(msgs(batch), [("echo", "Verifying the executable."), ("echo", "second"), ("echo", "third"), ("echo", "fourth"),
                                       ("echo", "fifth"), ("echo", "sixth"), ("echo", "Verifying %%I")])

    def test_both_branches_of_a_one_line_if_else_are_read(self):
        batch = (":a\nif defined A (echo Verifying the executable) else (echo Packaging your app)\n"
                 "if defined A (if defined B (echo x1) else (echo y1)) else (echo z1)\n"
                 "if defined A (echo x2) else if defined B (echo y2) else (echo z2)\n")
        self.assertEqual([t for _, t in msgs(batch)],
                         ["Verifying the executable", "Packaging your app", "x1", "y1", "z1", "x2", "y2", "z2"])

    def test_a_block_with_an_else_branch_is_read_line_by_line(self):
        batch = ":a\nif defined A (\n  echo first\n) else (\n  echo Rebuilding things\n)\n"
        self.assertEqual(msgs(batch), [("echo", "first"), ("echo", "Rebuilding things")])

    def test_carets_banners_and_blanks_are_dropped_and_whitespace_is_collapsed(self):
        self.assertEqual(msgs(":a\necho ***  Building ^(the EXE^)   now  ***\n"), [("echo", "Building (the EXE) now")])
        self.assertEqual(msgs(":a\necho.\necho ***\n"), [])
        self.assertEqual(msgs(":a\n@echo off\necho on\n"), [])

    def test_prompts_are_messages(self):
        batch = (':a\nset /p ANSWER=Build it now? [Y/N] \nset /p "ANSWER=Package it? [Y/N] "\n'
                 'choice /C YN /N /T 30 /D N /M "Verify it? [Y/N] "\nset /p ANSWER=\n')
        self.assertEqual(msgs(batch), [("prompt", "Build it now? [Y/N]"), ("prompt", "Package it? [Y/N]"), ("prompt", "Verify it? [Y/N]")])

    def test_an_unquoted_prompt_ends_where_cmd_ends_the_command_and_the_rest_of_the_line_is_read(self):
        # cmd gives `set /p` the text up to the first `&`, `|`, `<`, `>` or unmatched `)` that no quote or caret protects.
        want = [("prompt", "PyInstaller ready?"), ("echo", "Building the widget")]
        self.assertEqual(msgs(":a\nset /p ANSWER=PyInstaller ready? & echo Building the widget\n"), want)
        self.assertEqual(msgs(":a\nset /p ANSWER=PyInstaller ready? && echo Building the widget\n"), want)
        self.assertEqual(msgs(":a\nset /p ANSWER=PyInstaller ready? || echo Building the widget\n"), want)
        self.assertEqual(msgs(":a\nif defined X (set /p ANSWER=PyInstaller ready? ) else (echo Building the widget)\n"), want)
        # A parenthesis that opens inside the text closes inside it too.
        self.assertEqual(msgs(":a\nif defined X (set /p ANSWER=PyInstaller (the EXE tool) ready? ) else (echo two)\n"),
                         [("prompt", "PyInstaller (the EXE tool) ready?"), ("echo", "two")])

    def test_a_quoted_or_caret_escaped_separator_is_text_of_the_prompt(self):
        self.assertEqual(msgs(':a\nset /p "ANSWER=Verify & build it now? [Y/N] " & echo Rebuilding the widget\n'),
                         [("prompt", "Verify & build it now? [Y/N]"), ("echo", "Rebuilding the widget")])
        self.assertEqual(msgs(":a\nset /p ANSWER=Verify ^& build it now?\n"), [("prompt", "Verify & build it now?")])
        self.assertEqual(msgs(':a\nset /p ANSWER=Do "this & that" now? & echo two\n'), [("prompt", 'Do "this & that" now?'), ("echo", "two")])
        self.assertEqual(msgs(":a\nif defined X (set /p ANSWER=Done ^) now? ) else (echo two)\n"), [("prompt", "Done ) now?"), ("echo", "two")])

    def test_reading_an_answer_from_a_file_is_not_a_prompt(self):
        self.assertEqual(msgs(':a\nif exist "~entry.abs" set /p HP_ENTRY=<"~entry.abs"\n'), [])
        self.assertEqual(msgs(':a\nset /p HP_SYS_EXE=<"%HP_SYS_TMP%"\n'), [])

    def test_a_percent_variable_stays_as_written(self):
        self.assertEqual(msgs(':a\ncall :log "[INFO] Fast path: reusing %HP_FAST_EXE_PATH%."\n'),
                         [("log", "[INFO] Fast path: reusing %HP_FAST_EXE_PATH%.")])

    def test_crlf_and_lf_give_the_same_messages(self):
        self.assertEqual(ew.messages(GOOD), ew.messages(GOOD.replace("\n", "\r\n")))
        self.assertTrue(ew.messages(GOOD))


class Judging(unittest.TestCase):
    """is_about_build, names_exe and console_visible: the three words of the rule."""

    def test_a_message_about_building_bundling_packaging_or_verifying_is_about_the_build(self):
        for text in ("Build it", "Building it", "It builds", "It was built", "rebuild", "Rebuilding", "rebuilt", "packaging", "packaged",
                     "bundle", "bundles", "bundled", "bundling", "Smoke test", "verify", "verifies", "verified", "verification", "verifying",
                     "the next run will rebuild.", "[INFO] Optimized build: declined."):
            with self.subTest(text=text):
                self.assertTrue(ew.is_about_build(text))

    def test_other_messages_are_not(self):
        for text in ("Downloading uv", "package list", "Installing the packages", "the builder", "buildings", "Visual Studio Build Tools",
                     "Install Visual Studio Build Tools to compile it.", "Setting up your Python environment."):
            with self.subTest(text=text):
                self.assertFalse(ew.is_about_build(text))

    def test_visual_studio_build_tools_does_not_hide_a_real_trigger(self):
        self.assertTrue(ew.is_about_build("Install Visual Studio Build Tools and build it."))

    def test_the_verb_package_with_what_it_packages_is_about_the_build(self):
        for text in ("Package your app now?", "We could not package your app into a double-clickable program.", "package my app",
                     "Package this folder.", "Package up the files.", "[INFO] Package our program."):
            with self.subTest(text=text):
                self.assertTrue(ew.is_about_build(text))

    def test_the_noun_package_is_a_dependency_and_stays_quiet(self):
        for text in ("Retrying package installation...", "Package installation could not complete.", "Installing the packages",
                     "the package that provides it", "a package a library needs only at run time", "the package list",
                     "Package names are not case sensitive.", "which package to install", "the package the program needs", "packages",
                     # A determiner in front of it makes it the noun even when a pronoun follows.
                     "the package your program needs", "a package our helper installs", "each package this program imports",
                     "any package my script names", "that package your code uses", "No package these tools need is missing."):
            with self.subTest(text=text):
                self.assertFalse(ew.is_about_build(text))

    def test_a_message_names_the_artifact_or_the_tool_with_one_of_these_words(self):
        for text in ("the EXE", "the exe file", "dist\\x.exe", "an executable", "PyInstaller", "pyinstaller", "Nuitka", "a standalone app",
                     "reusing %HP_FAST_EXE_PATH%"):
            with self.subTest(text=text):
                self.assertTrue(ew.names_exe(text))

    def test_other_words_and_a_bare_variable_do_not(self):
        for text in ("the program", "EXECUTE it", "dist\\EXEC", "%HP_FAST_EXE%", "the build", "the app"):
            with self.subTest(text=text):
                self.assertFalse(ew.names_exe(text))

    def test_diagnostics_and_hooks_are_not_shown_to_a_user(self):
        for text in ("[DEBUG] x", "[TRACE] x", "[INSTALL] x", "[TEST] x", "something HP_TEST_X is set", "HP_SKIP_ENTRY_SMOKE is set"):
            with self.subTest(text=text):
                self.assertFalse(ew.console_visible(text))
        for text in ("[INFO] x", "[WARN] x", "[DEBUGGER] x", "Test run", "x [DEBUG]"):
            with self.subTest(text=text):
                self.assertTrue(ew.console_visible(text))


class RuleFile(unittest.TestCase):
    """parse_rules(): the exempt list's own format."""

    def test_categories_and_entries_are_read_with_their_lines(self):
        rules = ew.parse_rules(GOOD_RULES)
        self.assertEqual(rules.problems, [])
        self.assertEqual(sorted(rules.categories), ["provider"])
        self.assertEqual(rules.entries, [("provider", "[INFO] REQ-009: cascade declined; keeping current build.", 4)])
        self.assertEqual(rules.exempt_texts(), {"[INFO] REQ-009: cascade declined; keeping current build.": "provider"})

    def test_whitespace_in_an_entry_is_collapsed_and_crlf_is_accepted(self):
        text = "category: a | why\r\na |   some    text   here  \r\n"
        rules = ew.parse_rules(text)
        self.assertEqual(rules.problems, [])
        self.assertEqual(rules.entries, [("a", "some text here", 2)])

    def test_each_malformed_line_is_a_problem_that_names_its_line(self):
        cases = [
            ("category: only-a-name\n", "line 1: a category line reads"),
            ("category:  | no name\n", "line 1: a category line reads"),
            ("category: a | \n", "line 1: a category line reads"),
            ("category: a | why\ncategory: a | again\na | text\n", "line 2: category 'a' is defined twice"),
            ("category: a | why\nno separator here\n", "line 2: an entry reads"),
            ("category: a | why\na | \n", "line 2: an entry reads"),
            ("category: a | why\na | text\na |   text\n", "line 3: the message is listed twice (first on line 2)"),
            ("category: a | why\nb | text\n", "line 2: category 'b' is not defined by a 'category:' line"),
        ]
        for text, expected in cases:
            with self.subTest(text=text):
                problems = ew.parse_rules(text).problems
                self.assertTrue(any(expected in p for p in problems), (expected, problems))


class TemplateMatching(unittest.TestCase):
    """_template_regex(): an exempt message whose variables are filled in at run time."""

    def test_a_variable_matches_any_text(self):
        rx = ew._template_regex("[INFO] Running entry script smoke test via %HP_ENV_MODE% interpreter.")
        self.assertTrue(rx.match("[INFO] Running entry script smoke test via venv interpreter."))
        self.assertTrue(rx.match("[INFO] Running entry script smoke test via  interpreter."))
        self.assertFalse(rx.match("[INFO] Running entry script smoke test via venv interpreter. And more."))
        self.assertFalse(rx.match("[INFO] Running the packaged EXE via venv interpreter."))

    def test_the_other_variable_shapes_match_too(self):
        rx = ew._template_regex('[ERROR] You gave: "%~1" Usage: x %%I and %2 and %* end.')
        self.assertTrue(rx.match('[ERROR] You gave: "my app.py" Usage: x A and B and C D end.'))

    def test_literal_regex_characters_in_a_message_are_not_a_pattern(self):
        rx = ew._template_regex("[INFO] a.b (c) [d] *e* +f?")
        self.assertTrue(rx.match("[INFO] a.b (c) [d] *e* +f?"))
        self.assertFalse(rx.match("[INFO] aXb (c) [d] *e* +f?"))


class CheckCanFail(unittest.TestCase):
    """check(): the good batch file is clean, and a mutation of it for each rule turns it red for that rule."""

    def test_the_good_batch_file_is_clean_and_every_kind_of_message_is_in_it(self):
        self.assertEqual(check_text(GOOD), [])
        rows = ew.classify(GOOD, ew.parse_rules(GOOD_RULES))
        statuses = {}
        for _, _, kind, text, status in rows:
            statuses.setdefault(status, []).append((kind, text))
        self.assertEqual(sorted(statuses), ["exempt:provider", "named", "quiet"])
        self.assertEqual({k for k, _ in statuses["named"]}, {"log", "echo", "prompt"})
        self.assertEqual(len(statuses["named"]), 6)
        self.assertEqual(len(statuses["exempt:provider"]), 1)

    def test_the_good_batch_file_is_clean_with_crlf_line_ends(self):
        self.assertEqual(check_text(GOOD.replace("\n", "\r\n"), GOOD_RULES.replace("\n", "\r\n")), [])

    def _one_violation(self, new_lines, text):
        mutated, first = with_lines(*new_lines)
        problems = check_text(mutated)
        self.assertEqual(len(problems), 1, problems)
        problem = problems[0]
        self.assertIn("run_setup.bat line %d (main): " % first, problem)
        self.assertIn("does not name the EXE or the tool: " + text, problem)
        self.assertIn("add the line '<category> | " + text + "' to tests/exe_wording_exempt.txt", problem)
        self.assertIn("(README REQ-007.20)", problem)

    def test_a_log_message_about_building_that_names_nothing_is_a_violation(self):
        self._one_violation(['call :log "[INFO] Building the widget now."'], "[INFO] Building the widget now.")

    def test_a_tagged_call_is_a_violation_too(self):
        self._one_violation(['call :hint "[HINT] Rebuilding the widget."'], "[HINT] Rebuilding the widget.")

    def test_an_echo_block_is_judged_as_one_message(self):
        self._one_violation(["echo Building the widget", "echo and then the other widget"], "Building the widget and then the other widget")

    def test_an_inline_if_echo_is_a_violation(self):
        self._one_violation(["if defined HP_FLAG echo Verifying the widget."], "Verifying the widget.")

    def test_the_other_branch_of_a_one_line_if_else_is_a_violation(self):
        self._one_violation(["if defined HP_FLAG (echo fine) else (echo Packaging the widget.)"], "Packaging the widget.")

    def test_a_set_p_prompt_is_a_violation(self):
        self._one_violation(["set /p ANSWER=Build the widget now? [Y/N] "], "Build the widget now? [Y/N]")

    def test_a_choice_prompt_is_a_violation(self):
        self._one_violation(['choice /C YN /N /T 30 /D N /M "Build the widget now? [Y/N] "'], "Build the widget now? [Y/N]")

    def test_a_banner_does_not_hide_the_words(self):
        self._one_violation(["echo *** Packaging your widget ***"], "Packaging your widget")

    def test_the_imperative_package_is_a_violation_in_an_echo_a_prompt_and_a_log_call(self):
        self._one_violation(["echo Package your widget now?"], "Package your widget now?")
        self._one_violation(["set /p ANSWER=Package your widget now? [Y/N] "], "Package your widget now? [Y/N]")
        self._one_violation(['call :log "[WARN] We could not package your widget."'], "[WARN] We could not package your widget.")

    def test_a_dependency_message_with_the_noun_package_is_not_a_violation(self):
        mutated, _ = with_lines("echo Retrying package installation...", 'call :log "[WARN] A package the program needs is missing."')
        self.assertEqual(check_text(mutated), [])

    def test_a_message_after_a_log_call_on_the_same_line_is_judged(self):
        self._one_violation(['call :log "[INFO] PyInstaller is ready." & echo Building the widget'], "Building the widget")
        self._one_violation(['choice /C YN /N /M "Is it fine? [Y/N] " & echo Rebuilding the widget'], "Rebuilding the widget")

    def test_a_message_after_an_unquoted_prompt_on_the_same_line_is_judged(self):
        self._one_violation(["set /p ANSWER=PyInstaller ready? & echo Building the widget"], "Building the widget")
        self._one_violation(["if defined HP_FLAG (set /p ANSWER=PyInstaller ready? ) else (echo Building the widget)"], "Building the widget")

    def test_a_message_after_a_caret_escaped_parenthesis_is_judged(self):
        self._one_violation(["if defined HP_FLAG (echo Note ^) Building the widget)"], "Note ) Building the widget")

    def test_the_echoes_of_a_group_that_writes_to_a_file_are_not_judged_and_the_same_group_without_the_redirect_is(self):
        mutated, _ = with_lines("(echo Building the widget & echo Bundling it) > f.txt")
        self.assertEqual(check_text(mutated), [])
        mutated, _ = with_lines("(echo Building the widget & echo Bundling it)")
        problems = check_text(mutated)
        self.assertEqual(len(problems), 2, problems)
        self.assertIn("Building the widget", problems[0])
        self.assertIn("Bundling it", problems[1])
        # The redirect of the second command is that command's own: the group's first echo still reaches the console.
        mutated, _ = with_lines("(echo Building the widget) & echo Bundling it > f.txt")
        problems = check_text(mutated)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("Building the widget", problems[0])

    def test_a_group_whose_redirect_is_for_standard_error_or_input_is_still_judged(self):
        # Only a redirect of standard output hides the echoes of a group; `2>`, `2>&1` and `<` leave them on the console.
        for redirect in ("2> f.txt", "2>&1", "< in.txt", "2>nul < in.txt"):
            with self.subTest(redirect=redirect):
                mutated, _ = with_lines("(echo Building the widget & echo Bundling it) " + redirect)
                problems = check_text(mutated)
                self.assertEqual(len(problems), 2, problems)
                self.assertIn("Building the widget", problems[0])
                self.assertIn("Bundling it", problems[1])
        for redirect in ("2>&1 > f.txt", "< in.txt > f.txt", "2>nul >nul"):
            with self.subTest(redirect=redirect):
                mutated, _ = with_lines("(echo Building the widget & echo Bundling it) " + redirect)
                self.assertEqual(check_text(mutated), [])
        mutated, first = with_lines("echo Building the widget 2>nul")
        problems = check_text(mutated)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("line %d (main)" % first, problems[0])
        self.assertIn("does not name the EXE or the tool: Building the widget\n", problems[0])

    def test_the_same_words_with_the_name_are_clean(self):
        for new in ('call :log "[INFO] Building the widget EXE now."', "echo Packaging the widget as a standalone app",
                    'call :log "[INFO] Verifying dist\\widget.exe now."', 'call :log "[INFO] Rebuilding with Nuitka."',
                    'call :log "[INFO] Fast path: reusing %HP_FAST_EXE_PATH% instead of a build."',
                    'call :log "[INFO] The PyInstaller bundle is ready."'):
            with self.subTest(new=new):
                mutated, _ = with_lines(new)
                self.assertEqual(check_text(mutated), [])

    def test_a_block_that_wraps_the_name_onto_its_next_line_is_clean_and_a_blank_echo_splits_it(self):
        mutated, _ = with_lines("echo Building the widget", "echo as a standalone EXE.")
        self.assertEqual(check_text(mutated), [])
        mutated, first = with_lines("echo Building the widget", "echo.", "echo as a standalone EXE.")
        problems = check_text(mutated)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("line %d (main)" % first, problems[0])
        self.assertIn("does not name the EXE or the tool: Building the widget\n", problems[0])

    def test_a_named_message_that_loses_its_name_is_a_violation(self):
        mutated = mutate(GOOD, "Building standalone executable -- this may take", "Building the program -- this may take")
        problems = check_text(mutated)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("does not name the EXE or the tool: [INFO] Building the program -- this may take a minute or two...", problems[0])

    def test_diagnostic_and_hook_messages_are_not_judged_but_the_same_text_without_the_tag_is(self):
        for tag in ("[DEBUG]", "[TRACE]", "[INSTALL]", "[TEST]"):
            with self.subTest(tag=tag):
                hidden, _ = with_lines('call :log "%s Building the widget now."' % tag)
                self.assertEqual(check_text(hidden), [])
                shown, _ = with_lines('call :log "[INFO] Building the widget now."')
                self.assertEqual(len(check_text(shown)), 1)
        for variable in ("HP_TEST_FORCE_BUILD", "HP_SKIP_EXE_BUILD"):
            with self.subTest(variable=variable):
                hidden, _ = with_lines('call :log "[INFO] %s is set: building nothing."' % variable)
                self.assertEqual(check_text(hidden), [])

    def test_visual_studio_build_tools_is_not_a_trigger_but_a_second_build_in_the_same_message_is(self):
        mutated, first = with_lines('call :log "[INFO] Install Visual Studio Build Tools and build it."')
        problems = check_text(mutated)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("line %d" % first, problems[0])

    def test_a_comment_that_says_build_is_not_a_message(self):
        mutated, _ = with_lines("rem Building the widget now.", ":: Verifying the widget.")
        self.assertEqual(check_text(mutated), [])

    def test_an_echo_into_a_file_is_not_a_message(self):
        mutated, _ = with_lines('echo Building the widget > "%TEMP%\\widget.txt"', '>> "%LOG%" echo Verifying the widget')
        self.assertEqual(check_text(mutated), [])

    def test_a_message_that_changes_wording_leaves_a_stale_entry_and_a_violation(self):
        mutated = mutate(GOOD, "cascade declined; keeping current build.", "cascade declined; keeping the current build.")
        problems = check_text(mutated)
        self.assertEqual(len(problems), 2, problems)
        self.assertTrue(any("does not name the EXE or the tool: [INFO] REQ-009: cascade declined; keeping the current build." in p for p in problems), problems)
        self.assertTrue(any("exe_wording_exempt.txt line 4: no console message of run_setup.bat reads this any more, remove or update it: "
                            "[INFO] REQ-009: cascade declined; keeping current build." in p for p in problems), problems)

    def test_an_entry_for_a_message_that_now_names_the_exe_is_reported(self):
        rules = GOOD_RULES + "provider | [INFO] Building standalone executable -- this may take a minute or two...\n"
        problems = check_text(GOOD, rules)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("exe_wording_exempt.txt line 5: the message does not need an exemption (it names the EXE), remove it: "
                      "[INFO] Building standalone executable", problems[0])

    def test_an_entry_for_a_message_that_is_not_about_the_build_is_reported(self):
        rules = GOOD_RULES + "provider | [INFO] Downloading the tools.\n"
        problems = check_text(GOOD, rules)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("the message does not need an exemption (it is not about the build), remove it: [INFO] Downloading the tools.", problems[0])

    def test_a_category_nobody_uses_is_reported(self):
        problems = check_text(GOOD, GOOD_RULES + "category: extra | a category with no entry\n")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("the category 'extra' has no entry, remove its 'category:' line", problems[0])

    def test_the_problems_of_the_rule_file_are_part_of_the_result(self):
        problems = check_text(GOOD, GOOD_RULES + "provider | [INFO] REQ-009: cascade declined; keeping current build.\n")
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("the message is listed twice (first on line 4)", problems[0])
        problems = check_text(GOOD, GOOD_RULES + "nocat | something\n")
        self.assertTrue(any("category 'nocat' is not defined" in p for p in problems), problems)

    def test_one_entry_covers_every_place_that_prints_the_same_message_and_goes_stale_when_none_does(self):
        twice = mutate(GOOD, "exit /b 0\n:second", 'call :log "[INFO] REQ-009: cascade declined; keeping current build."\nexit /b 0\n:second')
        self.assertEqual(check_text(twice), [])
        gone = GOOD.replace('call :log "[INFO] REQ-009: cascade declined; keeping current build."\n', "")
        problems = check_text(gone)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("no console message of run_setup.bat reads this any more", problems[0])


class ConsoleJudge(unittest.TestCase):
    """console_check(): the timestamped lines of a real run, judged by the same rules."""

    LOG = "\n".join([
        "Sat 11/14/2026  9:05:03.10 [INFO] Downloading the tools.",
        "Sat 11/14/2026  9:05:04.11 [INFO] Building standalone executable -- this may take a minute or two...",
        "Sat 11/14/2026  9:05:05.12 [INFO] REQ-009: cascade declined; keeping current build.",
        "[2026-11-14 12:00:00.00] [WARN] The build did not finish.",
        "Sat 11/14/2026  9:05:06.13 [DEBUG] Verification detail.",
        "This line has no timestamp but it says build.",
        "",
    ])

    def test_each_timestamped_line_is_judged_and_the_counts_say_what_was_judged(self):
        problems, stats = ew.console_check(self.LOG, ew.parse_rules(GOOD_RULES))
        self.assertEqual(problems, ["console line talks about building or verifying and does not name the EXE or the tool: "
                                    "[WARN] The build did not finish."])
        self.assertEqual(stats["timestamped"], 5)
        self.assertEqual(stats["triggered"], 3)
        self.assertEqual((stats["named"], stats["exempt"], stats["violations"]), (1, 1, 1))

    def test_a_line_without_a_timestamp_is_not_judged(self):
        problems, stats = ew.console_check("Building the widget.\nVerifying the widget.\n", ew.parse_rules(GOOD_RULES))
        self.assertEqual((problems, stats["timestamped"], stats["triggered"]), ([], 0, 0))

    def test_the_verb_package_is_judged_in_a_run_and_the_noun_is_not(self):
        log = ("Sat 11/14/2026  9:05:03.10 [INFO] Package your widget now?\n"
               "Sat 11/14/2026  9:05:04.11 [INFO] Retrying package installation...\n"
               "Sat 11/14/2026  9:05:05.12 [INFO] Package your widget into a standalone EXE.\n")
        problems, stats = ew.console_check(log, ew.parse_rules(GOOD_RULES))
        self.assertEqual(problems, ["console line talks about building or verifying and does not name the EXE or the tool: "
                                    "[INFO] Package your widget now?"])
        self.assertEqual((stats["triggered"], stats["named"], stats["violations"]), (2, 1, 1))

    def test_an_exempt_message_with_a_variable_matches_the_line_the_variable_was_filled_into(self):
        rules = ew.parse_rules("category: interpreter | the check runs through the interpreter\n"
                               "interpreter | [INFO] Running entry script smoke test via %HP_ENV_MODE% interpreter.\n")
        line = "Sat 11/14/2026  9:05:03.10 [INFO] Running entry script smoke test via venv interpreter."
        problems, stats = ew.console_check(line + "\n", rules)
        self.assertEqual((problems, stats["exempt"]), ([], 1))
        problems, stats = ew.console_check(line.replace("interpreter.", "interpreter, twice.") + "\n", rules)
        self.assertEqual((len(problems), stats["violations"]), (1, 1))

    def test_a_rule_file_problem_is_not_hidden_by_a_clean_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules, log = Path(tmp) / "rules.txt", Path(tmp) / "console.log"
            rules.write_text("category: a | why\na | one\na | one\n", encoding="ascii")
            log.write_text("Sat 11/14/2026  9:05:03.10 [INFO] Downloading the tools.\n", encoding="ascii")
            code, out, _ = run_main(["console", "--file", str(log), "--rules", str(rules)])
        result = json.loads(out)
        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        self.assertTrue(any("listed twice" in p for p in result["problems"]), result)


class CommandLine(unittest.TestCase):
    """main(): the three commands, their output and their exit codes."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.rules = self.dir / "rules.txt"
        self.rules.write_text(GOOD_RULES, encoding="ascii")

    def _bat(self, text):
        path = self.dir / "run_setup.bat"
        path.write_bytes(text.replace("\n", "\r\n").encode("ascii"))
        return path

    def test_check_prints_the_count_and_exits_zero_for_a_clean_file(self):
        code, out, err = run_main(["check", "--bat", str(self._bat(GOOD)), "--rules", str(self.rules)])
        self.assertEqual((code, out, err), (0, "exe_wording: 0 problem(s)\n", ""))

    def test_check_prints_each_problem_then_the_count_and_exits_one(self):
        mutated, _ = with_lines('call :log "[INFO] Building the widget now."')
        code, out, _ = run_main(["check", "--bat", str(self._bat(mutated)), "--rules", str(self.rules)])
        self.assertEqual(code, 1)
        self.assertIn("does not name the EXE or the tool: [INFO] Building the widget now.", out)
        self.assertTrue(out.endswith("exe_wording: 1 problem(s)\n"), out)

    def test_list_prints_the_messages_that_are_about_the_build_with_their_status(self):
        code, out, _ = run_main(["list", "--bat", str(self._bat(GOOD)), "--rules", str(self.rules)])
        self.assertEqual(code, 0)
        self.assertIn("named", out)
        self.assertIn("exempt:provider", out)
        self.assertNotIn("Downloading the tools.", out)

    def test_a_missing_file_is_exit_two_with_a_message_on_stderr(self):
        code, out, err = run_main(["check", "--bat", str(self.dir / "missing.bat"), "--rules", str(self.rules)])
        self.assertEqual((code, out), (2, ""))
        self.assertTrue(err.startswith("error: "), err)
        code, out, err = run_main(["console", "--file", str(self.dir / "missing.log"), "--rules", str(self.rules)])
        self.assertEqual((code, out), (2, ""))

    def test_console_prints_one_json_line_with_the_verdict_the_counts_and_the_problems(self):
        log = self.dir / "console.log"
        log.write_text(ConsoleJudge.LOG, encoding="ascii")
        code, out, _ = run_main(["console", "--file", str(log), "--rules", str(self.rules)])
        self.assertEqual(code, 1)
        result = json.loads(out)
        self.assertEqual(sorted(result), ["ok", "problems", "stats"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["stats"]["violations"], 1)
        self.assertEqual(len(out.strip().split("\n")), 1)

    def test_console_of_a_clean_run_is_ok_and_exit_zero(self):
        log = self.dir / "console.log"
        log.write_text("Sat 11/14/2026  9:05:04.11 [INFO] Building standalone executable -- this may take a minute or two...\n", encoding="ascii")
        code, out, _ = run_main(["console", "--file", str(log), "--rules", str(self.rules)])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out), {"ok": True, "problems": [], "stats": {"lines": 2, "timestamped": 1, "triggered": 1, "named": 1,
                                                                              "exempt": 0, "violations": 0}})

    def test_the_script_runs_alone_from_any_folder_with_nothing_but_the_standard_library(self):
        log = self.dir / "console.log"
        log.write_text("Sat 11/14/2026  9:05:03.10 [INFO] The build did not finish.\n", encoding="ascii")
        done = subprocess.run([sys.executable, "-I", str(TOOL), "console", "--file", str(log), "--rules", str(self.rules)],
                              cwd=str(self.dir), capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertFalse(json.loads(done.stdout)["ok"])
        done = subprocess.run([sys.executable, "-I", str(TOOL), "check", "--bat", str(self._bat(GOOD)), "--rules", str(self.rules)],
                              cwd=str(self.dir), capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "exe_wording: 0 problem(s)\n", ""))


class RealFiles(unittest.TestCase):
    """The rule applied to the real run_setup.bat and the real exempt list."""

    @classmethod
    def setUpClass(cls):
        cls.bat = read(BATCH).replace("\r\n", "\n")
        cls.rules = ew.parse_rules(read(RULES))

    def test_the_exempt_list_is_plain_ascii_with_lf_line_ends_and_parses_clean(self):
        raw = RULES.read_bytes()
        self.assertTrue(raw.isascii())
        self.assertNotIn(b"\r", raw)
        self.assertTrue(raw.endswith(b"\n"))
        self.assertEqual(self.rules.problems, [])
        self.assertTrue(TOOL.read_bytes().isascii())

    def test_the_exempt_list_does_not_grow_without_this_file_changing(self):
        self.assertLessEqual(len(self.rules.entries), MAX_EXEMPT_ENTRIES,
                             "tests/exe_wording_exempt.txt holds %d entries and README REQ-007.20 asks for the EXE or the tool to be named "
                             "in every message about the build; reword the new message, or raise MAX_EXEMPT_ENTRIES together with a "
                             "reason a reader can check" % len(self.rules.entries))

    def test_every_category_of_the_list_says_why_in_a_sentence(self):
        for name, meaning in self.rules.categories.items():
            with self.subTest(category=name):
                self.assertGreaterEqual(len(meaning.split()), 6)

    def test_the_reader_finds_the_messages_of_the_real_file(self):
        rows = ew.classify(self.bat, self.rules)
        kinds = {kind for _, _, kind, _, _ in rows}
        self.assertEqual(kinds, {"log", "echo", "prompt"})
        self.assertGreaterEqual(len(rows), 500)
        self.assertGreaterEqual(sum(1 for r in rows if r[4] == "named"), 45)
        texts = [r[3] for r in rows]
        for needle in ("[INFO] Building standalone executable -- this may take a minute or two...",
                       "Build the optimized version now? [Y/N]"):
            with self.subTest(needle=needle):
                self.assertIn(needle, texts)

    def test_a_message_added_to_the_real_file_is_caught(self):
        before = violation_texts(self.bat, self.rules)
        mutated = mutate(self.bat, "\n:offer_optimized_build\n", '\n:offer_optimized_build\ncall :log "[INFO] Building the widget now."\n')
        first = lines_of(mutated).index('call :log "[INFO] Building the widget now."') + 1
        self.assertEqual(sorted(violation_texts(mutated, self.rules)), sorted(before + ["[INFO] Building the widget now."]))
        added = [p for p in ew.check(mutated, self.rules) if "[INFO] Building the widget now." in p]
        self.assertEqual(len(added), 1, added)
        self.assertIn("run_setup.bat line %d (offer_optimized_build): " % first, added[0])
        self.assertIn("does not name the EXE or the tool: [INFO] Building the widget now.", added[0])

    def test_the_same_message_as_a_hidden_diagnostic_is_not_a_violation(self):
        before = violation_texts(self.bat, self.rules)
        mutated = mutate(self.bat, "\n:offer_optimized_build\n", '\n:offer_optimized_build\ncall :log "[DEBUG] Building the widget now."\n')
        self.assertEqual(violation_texts(mutated, self.rules), before)

    def test_a_named_message_of_the_real_file_that_loses_its_name_is_caught(self):
        before = violation_texts(self.bat, self.rules)
        mutated = mutate(self.bat, "Building standalone executable -- this may take", "Building the program -- this may take")
        self.assertEqual(sorted(violation_texts(mutated, self.rules)),
                         sorted(before + ["[INFO] Building the program -- this may take a minute or two..."]))

    def test_every_console_message_about_the_build_names_the_exe_or_the_tool(self):
        problems = ew.check(self.bat, self.rules)
        self.assertEqual(problems, [], "README REQ-007.20: %d problem(s)\n%s" % (len(problems), "\n".join(problems)))


class TheFirstWindowsRun(unittest.TestCase):
    """The two console lines the first Windows run of the scenario flagged, as that run printed them, and the same two after the rewording.

    Run 43740185058 (contract-uv) judged the console of the accepted system-Python build with the real exempt list: 48 timestamped
    lines, 9 about the build, 5 naming the EXE, 2 exempt and these 2 violations. The lines are copied from its console log with the
    CRLF line ends a cmd.exe redirect writes and the date form of that runner (two-digit hour), so the judge is shown to read the
    real shape of a console line and not only the shape the synthetic cases above use. The second pair is what the same two
    messages print since the rewording, copied from a local run of the real batch file."""

    OLD = (
        "Sun 11/15/2026 17:26:39.44 [INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / "
        "~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and "
        "_frozen_importlib_external are expected on Windows and are filtered out automatically; cStringIO and StringIO "
        "(Python-2-only compatibility shims some packages still reference) are filtered out automatically too.",
        "Sun 11/15/2026 17:26:41.29 [INFO] Optimized build: declined.",
    )
    NEW = (
        OLD[0].replace("automatically bundled (full list", "automatically bundled into the EXE (full list"),
        OLD[1] + " No optimized EXE was built and your current EXE is unchanged.",
    )
    FILLER = (
        "Sun 11/15/2026 17:26:30.10 [INFO] Selected Python provider: system.",
        "Sun 11/15/2026 17:26:31.20 [INFO] Building standalone executable -- this may take a minute or two...",
    )

    @classmethod
    def setUpClass(cls):
        cls.rules = ew.parse_rules(read(RULES))

    def _console(self, *lines):
        return "\r\n".join(self.FILLER + tuple(lines)) + "\r\n"

    def test_the_two_lines_as_the_run_printed_them_are_the_only_violations(self):
        problems, stats = ew.console_check(self._console(*self.OLD), self.rules)
        self.assertEqual(stats["violations"], 2, problems)
        self.assertEqual(len(problems), 2)
        self.assertTrue(problems[0].endswith(self.OLD[0].split(" ", 3)[3]), problems[0])
        self.assertTrue(problems[1].endswith("[INFO] Optimized build: declined."), problems[1])
        self.assertEqual((stats["timestamped"], stats["triggered"], stats["named"]), (4, 3, 1))

    def test_the_same_two_messages_after_the_rewording_pass_and_are_counted_as_naming_the_exe(self):
        problems, stats = ew.console_check(self._console(*self.NEW), self.rules)
        self.assertEqual(problems, [])
        self.assertEqual((stats["timestamped"], stats["triggered"], stats["named"], stats["violations"]), (4, 3, 3, 0))

    def test_either_line_alone_is_enough_to_fail_the_run(self):
        for index in (0, 1):
            with self.subTest(old_line=index):
                lines = [self.NEW[0], self.NEW[1]]
                lines[index] = self.OLD[index]
                problems, stats = ew.console_check(self._console(*lines), self.rules)
                self.assertEqual((len(problems), stats["violations"]), (1, 1), problems)

    def test_the_old_wording_of_the_two_lines_is_no_longer_in_the_batch_file(self):
        bat = read(BATCH).replace("\r\n", "\n")
        self.assertIn("could not be automatically bundled into the EXE (full list in", bat)
        self.assertNotIn("could not be automatically bundled (full list in", bat)
        self.assertIn("Optimized build: declined. No optimized EXE was built and your current EXE is unchanged.", bat)


if __name__ == "__main__":
    unittest.main()

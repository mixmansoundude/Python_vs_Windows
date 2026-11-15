"""Shared helpers for the unit tests of the scripts that cut a block out of run_setup.bat and judge what it did (Item 122).

Not a test file: pytest collects only test_*.py, and a test imports this module by name (the tests folder is on sys.path).
tests/test_visa_signals.py, tests/test_choice_cancel.py and the other tests of that family carry their own copies of the same
helpers, written before this module existed; the tests of Item 122 (tests/test_conda_evict.py, tests/test_visa_present.py) share
one copy so that a fix to a helper is made once. Moving the older files over is a separate change.

What is here, and why each part is a function and not a copy:
  * text helpers for batch and PowerShell sources (norm, lines_of, live_bat, live_hash, cut_block, variables_in, label_section,
    enclosing: the parentheses a line of a batch block sits inside);
  * the registry reader (registry_ids): ids on their own line inside a fenced block, which is what tools/check_ndjson_registry.py reads;
  * mutate(): a mutation case replaces text that must occur exactly once, because with two matches the case would edit the first one,
    which may be another block of the file, and the pin under test would never see the change;
  * builders of synthetic ledgers for the judging functions (text_of, swap, drop, drop_last, after): each asserts that the line it
    changes is there exactly once (drop_last: at least once), so a case cannot pass because it changed nothing;
  * step_block(): one step of batch-check.yml, found by the name of the script it runs;
  * the pwsh driver (DRIVER, run_cases, case): the script's own judging functions, run alone and in strict mode through a real pwsh.
    A judge may use only its parameters and its own locals; the driver's variables start with two underscores so that none can be
    read by accident, and strict mode turns a read of a variable nobody set into an error instead of a quiet $null.
ASCII only.
"""
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

PWSH = shutil.which("pwsh")
HARD_TIMEOUT = 120  # seconds, for pwsh start-up on a busy runner


def norm(text):
    return text.replace("\r\n", "\n")


def lines_of(text):
    return norm(text).split("\n")


def is_bat_comment(line):
    return re.match(r"(?i)\s*(rem\b|::)", line) is not None


def live_bat(lines):
    return [ln for ln in lines if ln.strip() and not is_bat_comment(ln)]


def live_hash(text):
    """The lines of a PowerShell or Python file that are not blank and not a comment line, stripped."""
    return [ln.strip() for ln in norm(text).split("\n") if ln.strip() and not ln.strip().startswith("#")]


def cut_block(text, start, end):
    """Lines from the line that is exactly `start` up to, not including, the line that is exactly `end`."""
    lines = lines_of(text)
    s = next((i for i, ln in enumerate(lines) if ln.strip() == start), None)
    if s is None:
        return None
    e = next((j for j in range(s + 1, len(lines)) if lines[j].strip() == end), None)
    if e is None:
        return None
    return lines[s:e]


def variables_in(lines):
    """Names of the variables the live lines read (%X%, %X:~0,1%, defined X) or set (set "X=)."""
    names = set()
    for ln in live_bat(lines):
        names.update(re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)(?::[^%]*)?%", ln))
        names.update(re.findall(r"(?i)\bdefined\s+([A-Za-z_][A-Za-z0-9_]*)", ln))
        names.update(re.findall(r'(?i)\bset\s+"?([A-Za-z_][A-Za-z0-9_]*)=', ln))
    return names


def label_section(body, label):
    """The lines of one label up to the next label (label line excluded). `body` is a list of stripped lines."""
    start = body.index(label)
    out = []
    for ln in body[start + 1:]:
        if ln.startswith(":"):
            break
        out.append(ln)
    return out


def enclosing(body, index):
    """The opening lines of the parentheses still open at body[index] (`body` is a list of stripped live lines): a line that ends
    with ( opens one, a line that starts with ) closes one, and a line that starts with ) and ends with ( closes one and opens
    another, which is how else branches read."""
    stack = []
    for ln in body[:index]:
        if ln.startswith(")"):
            if stack:
                stack.pop()
            if ln.endswith("("):
                stack.append(ln)
        elif ln.endswith("("):
            stack.append(ln)
    return stack


def registry_ids(text):
    """The ids on their own line inside a fenced block, which is what tools/check_ndjson_registry.py reads (prose does not count)."""
    ids, inside = set(), False
    for ln in norm(text).split("\n"):
        if ln.startswith("```"):
            inside = not inside
        elif inside and ln.strip():
            ids.update(part.strip(",") for part in ln.split() if part.strip(","))
    return ids


def mutate(text, old, new):
    """Replace `old` by `new` in `text`; `old` must occur exactly once (see the module text for why)."""
    assert text.count(old) == 1, "the synthetic case needs the text to hold %r exactly once, found %d" % (old[:60], text.count(old))
    return text.replace(old, new, 1)


def text_of(lines):
    """A ledger or log file as the batch writes it: CRLF line ends and a final one."""
    return "\r\n".join(lines) + "\r\n"


def swap(lines, old, new):
    """The ledger with the one line `old` replaced by `new`."""
    assert lines.count(old) == 1, old
    return [new if ln == old else ln for ln in lines]


def drop(lines, gone):
    """The ledger without the one line `gone`."""
    assert lines.count(gone) == 1, gone
    return [ln for ln in lines if ln != gone]


def drop_last(lines, gone):
    """The ledger without the last of the lines equal to `gone` (a ledger can hold the same line twice, a registry look for one)."""
    assert gone in lines, gone
    at = len(lines) - 1 - lines[::-1].index(gone)
    return lines[:at] + lines[at + 1:]


def after(lines, anchor, *new):
    """The ledger with the lines `new` inserted after the first line equal to `anchor`."""
    i = lines.index(anchor)
    return lines[:i + 1] + list(new) + lines[i + 1:]


def step_block(text, script_name):
    """The text of the step of batch-check.yml that runs `script_name`, or None. A step starts at a line `      - name:`."""
    lines = norm(text).split("\n")
    starts = [i for i, ln in enumerate(lines) if re.match(r"^      - name:", ln)]
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "\n".join(lines[start:end])
        if script_name in block:
            return block
    return None


DRIVER = r"""
$ErrorActionPreference = 'Stop'
# A judging function may use only its parameters and its own locals. Strict mode makes a read of a variable nobody set an error
# (and not $null), and the driver's own variables start with two underscores, so no judge can read one of them by accident.
Set-StrictMode -Version 1.0
$__tokens = $null; $__errs = $null
$__ast = [System.Management.Automation.Language.Parser]::ParseFile($env:CC_SCRIPT, [ref]$__tokens, [ref]$__errs)
if ($__errs.Count -gt 0) { throw ('parse errors: ' + $__errs[0].Message) }
$__want = @($env:CC_WANT -split ',')
$__defs = $__ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $__want -contains $n.Name }, $true)
if (@($__defs).Count -ne $__want.Count) { throw 'a judging function is missing from the script' }
foreach ($__f in $__defs) { Invoke-Expression $__f.Extent.Text }
$__cases = Get-Content -LiteralPath $env:CC_CASES -Raw | ConvertFrom-Json
$__all = New-Object System.Collections.ArrayList
foreach ($__c in $__cases) {
    $__h = @{}
    foreach ($__p in $__c.args.PSObject.Properties) { $__h[$__p.Name] = $__p.Value }
    $__r = @(& $__c.fn @__h)
    [void]$__all.Add([ordered]@{ name = $__c.name; result = $__r })
}
ConvertTo-Json -InputObject @($__all) -Compress -Depth 8
"""


def run_cases(script, want, cases, tmp):
    """Run the named functions of a script on the cases; returns {case name: list of what the function returned}."""
    tmp = Path(tmp)
    cases_file = tmp / "cases.json"
    cases_file.write_text(json.dumps(cases), encoding="ascii")
    driver = tmp / "driver.ps1"
    driver.write_text(DRIVER, encoding="ascii")
    env = dict(os.environ)
    env["CC_SCRIPT"] = str(script)
    env["CC_WANT"] = ",".join(want)
    env["CC_CASES"] = str(cases_file)
    proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(driver)], env=env,
                          capture_output=True, text=True, timeout=HARD_TIMEOUT)
    if proc.returncode != 0:
        raise AssertionError("pwsh failed (%s): %s %s" % (proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    return {item["name"]: item["result"] for item in json.loads(proc.stdout)}


def case(name, fn, **args):
    return {"name": name, "fn": fn, "args": args}

"""Item 90 follow-up: Dependabot has to be able to read .github/dependabot.yml.

The file was added 2026-08-17 with `open-pull-request-limit: 5`; the option is spelled `open-pull-requests-limit`.
Dependabot validates the file against a schema that allows no other property. Its options reference says nothing about
invalid options, so the evidence that the file was never used is the error below and ten weeks without one pull request
or `dependabot/*` branch while six of the nine pinned actions fell one or two majors behind (docs/open-questions.md used
to ask why). The only sign was a failed check run named after the file, titled "Your .github/dependabot.yml contained
invalid details", with the text: The property '#/updates/0/' contains additional properties ["open-pull-request-limit"]
outside of the schema when none are allowed. Dependabot posts it on a pull request that touches the file; it is not a
required check, so it stayed red and unread until PR #513 edited the file's comment (2026-10-30).

These rules read the file as text (the pytest step installs no YAML library, same style as test_aggregate_gate.py) and
hold it to the option names of GitHub's options reference,
https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference ,
read on 2026-10-31 and compared with the community JSON schema of the file,
https://www.schemastore.org/dependabot-2.0.json (`additionalProperties: false`). The two agree on every name in the lists
below except `name`, which only the schema has for an update entry; it is left out until the reference lists it.
`reviewers` is in neither. When Dependabot gains an option this repository wants, add its spelling to the list in the
same change; a mistyped option is what these lists exist to catch. Synthetic cases prove each rule can fail.
"""
import difflib
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONFIG = REPO / ".github" / "dependabot.yml"

TOP_KEYS = frozenset({"version", "updates", "registries", "enable-beta-ecosystems", "multi-ecosystem-groups"})
UPDATE_KEYS = frozenset({
    "allow", "assignees", "commit-message", "cooldown", "directories", "directory", "exclude-paths", "groups", "ignore",
    "insecure-external-code-execution", "labels", "milestone", "multi-ecosystem-group", "open-pull-requests-limit",
    "package-ecosystem", "patterns", "pull-request-branch-name", "rebase-strategy", "registries", "schedule",
    "target-branch", "vendor", "versioning-strategy",
})
SCHEDULE_KEYS = frozenset({"interval", "day", "time", "timezone", "cronjob"})
INTERVALS = frozenset({"daily", "weekly", "monthly", "quarterly", "semiannually", "yearly", "cron"})

KEY_LINE = re.compile(r"^(?P<dash>-\s+)?(?P<key>[A-Za-z0-9_-]+):(?:\s+(?P<value>\S.*?))?\s*$")


def parse(text):
    """Read the three levels the checks need: (top, entries). `top` maps a top-level key to (line, value); each entry is
    {"keys": {key: (line, value)}, "schedule": {key: (line, value)}}. Comment-only and blank lines are skipped. Only
    the block layout is understood (a dash, then keys indented under it), which is what the file has used since it was
    added; `updates:` written in flow style reads as no entries and is reported as such."""
    top = {}
    entries = []
    section = None
    item_indent = None
    key_indent = None
    current = None
    for no, raw in enumerate(text.splitlines(), 1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#") or stripped == "---":
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        m = KEY_LINE.match(stripped)
        if indent == 0 and not stripped.startswith("-"):
            if not m:
                continue
            section = m.group("key")
            top[section] = (no, m.group("value") or "")
            item_indent = None
            current = None
            continue
        if section != "updates":
            continue
        if stripped.startswith("-") and (item_indent is None or indent == item_indent):
            item_indent = indent
            entries.append({"keys": {}, "schedule": {}})
            current = None
            rest = stripped[1:].lstrip()
            key_indent = indent + (len(stripped) - len(rest))
            m = KEY_LINE.match(rest)
            if m:
                entries[-1]["keys"][m.group("key")] = (no, m.group("value") or "")
                current = m.group("key")
            continue
        if not entries or not m:
            continue
        if indent == key_indent:
            entries[-1]["keys"][m.group("key")] = (no, m.group("value") or "")
            current = m.group("key")
        elif indent > (key_indent or 0) and current == "schedule":
            entries[-1]["schedule"][m.group("key")] = (no, m.group("value") or "")
    return top, entries


def unknown(name, allowed):
    close = difflib.get_close_matches(name, sorted(allowed), n=1, cutoff=0.8)
    return " (did you mean %s?)" % close[0] if close else ""


def problems(text):
    found = []
    top, entries = parse(text)
    version = top.get("version")
    if version is None or version[1].strip("'\"") != "2":
        found.append("the file must say `version: 2`")
    for key, (no, _) in sorted(top.items(), key=lambda kv: kv[1][0]):
        if key not in TOP_KEYS:
            found.append("line %d: `%s` is not a top-level option Dependabot's schema allows; it rejects the whole file%s"
                         % (no, key, unknown(key, TOP_KEYS)))
    if not entries:
        found.append("`updates:` holds no entries that this reader can see (block layout, one `- package-ecosystem:` per entry)")
    for n, entry in enumerate(entries, 1):
        keys = entry["keys"]
        for key, (no, _) in sorted(keys.items(), key=lambda kv: kv[1][0]):
            if key not in UPDATE_KEYS:
                found.append("line %d: `%s` is not an option Dependabot's schema allows; it rejects the whole file%s"
                             % (no, key, unknown(key, UPDATE_KEYS)))
        if "package-ecosystem" not in keys:
            found.append("updates entry %d has no package-ecosystem" % n)
        if "directory" not in keys and "directories" not in keys:
            found.append("updates entry %d has neither directory nor directories" % n)
        if "schedule" not in keys:
            found.append("updates entry %d has no schedule" % n)
        schedule = entry["schedule"]
        for key, (no, _) in sorted(schedule.items(), key=lambda kv: kv[1][0]):
            if key not in SCHEDULE_KEYS:
                found.append("line %d: `%s` is not a schedule option Dependabot's schema allows%s" % (no, key, unknown(key, SCHEDULE_KEYS)))
        if "schedule" in keys:
            interval = schedule.get("interval")
            if interval is None:
                found.append("updates entry %d: schedule has no interval" % n)
            elif interval[1].strip("'\"") not in INTERVALS:
                found.append("line %d: schedule interval %s is not one of %s" % (interval[0], interval[1], sorted(INTERVALS)))
    if not any(e["keys"].get("package-ecosystem", (0, ""))[1].strip("'\"") == "github-actions" for e in entries):
        found.append("no updates entry watches the github-actions ecosystem, which is what the file exists for")
    return found


GOOD = """---
version: 2
updates:
  # a comment
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
"""


class RealFile(unittest.TestCase):
    def test_dependabot_can_read_the_config(self):
        found = problems(CONFIG.read_text(encoding="utf-8"))
        self.assertEqual(found, [], "\n".join(found))


class EachRuleCanFail(unittest.TestCase):
    def test_the_good_fixture_passes(self):
        self.assertEqual(problems(GOOD), [])

    def test_the_mistyped_limit_that_disabled_dependabot_is_named_with_its_correction(self):
        bad = GOOD.replace("open-pull-requests-limit", "open-pull-request-limit")
        found = problems(bad)
        self.assertEqual(len(found), 1, found)
        self.assertIn("open-pull-request-limit", found[0])
        self.assertIn("did you mean open-pull-requests-limit", found[0])

    def test_unknown_top_level_key(self):
        found = problems(GOOD.replace("updates:", "update:"))
        self.assertTrue(any("`update` is not a top-level option" in f for f in found), found)
        self.assertTrue(any("holds no entries" in f for f in found), found)

    def test_wrong_version(self):
        self.assertTrue(any("version: 2" in f for f in problems(GOOD.replace("version: 2", "version: 1"))))
        self.assertTrue(any("version: 2" in f for f in problems(GOOD.replace("version: 2\n", ""))))

    def test_unknown_schedule_option_and_bad_interval(self):
        found = problems(GOOD.replace("interval:", "intervall:"))
        self.assertTrue(any("`intervall` is not a schedule option" in f for f in found), found)
        self.assertTrue(any("schedule has no interval" in f for f in found), found)
        found = problems(GOOD.replace('"weekly"', '"fortnightly"'))
        self.assertTrue(any("fortnightly" in f for f in found), found)

    def test_missing_ecosystem_directory_and_schedule(self):
        self.assertTrue(any("no package-ecosystem" in f for f in problems(GOOD.replace("package-ecosystem", "package-ecosysten"))))
        self.assertTrue(any("neither directory" in f for f in problems(GOOD.replace('    directory: "/"\n', ""))))
        no_schedule = GOOD.replace('    schedule:\n      interval: "weekly"\n', "")
        self.assertTrue(any("no schedule" in f for f in problems(no_schedule)))

    def test_only_the_actions_ecosystem_counts_as_the_files_purpose(self):
        found = problems(GOOD.replace("github-actions", "pip"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("github-actions", found[0])

    def test_a_second_entry_is_checked_too(self):
        two = GOOD + '  - package-ecosystem: "pip"\n    directory: "/"\n    schedule:\n      interval: "daily"\n    open-pull-request-limit: 3\n'
        found = problems(two)
        self.assertEqual(len(found), 1, found)
        self.assertIn("open-pull-request-limit", found[0])

    def test_nested_keys_are_not_mistaken_for_options(self):
        nested = GOOD + '    ignore:\n      - dependency-name: "actions/checkout"\n        versions: ["8.x"]\n    labels:\n      - "dependencies"\n'
        self.assertEqual(problems(nested), [])


if __name__ == "__main__":
    unittest.main()

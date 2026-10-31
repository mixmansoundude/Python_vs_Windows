"""The live-network row self.ux.connectivity.online (tests/selfapps_ux_hardening.ps1) may run its scenario again when the
runner's own network blipped, and may not hide a real failure behind that.

Under the aggregate self-test gate a single red row in any lane holds a PR, and this row's premise is that the runner has
internet (run 41034407669, uv-dl-fallback: "no internet detected (ICMP and HTTPS check failed)", nothing in the PR touched
it). The rules, read as text because the script needs a Windows runner:
- the run repeats only while the product printed its own "no internet detected" line, and stops at three runs;
- a log with neither the reachable line nor the offline line is a real failure and is not repeated;
- the row's pass is still the reachable line of the last run, so a network that stays down stays red;
- the row records how many runs it took and whether the offline line was seen.
Synthetic cases prove each rule can fail.
"""
import re
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "selfapps_ux_hardening.ps1"


def online_section(text):
    start = text.index("REQ-013: Connectivity guard ONLINE")
    end = text.index("REQ-013: Connectivity guard Y-RETRY")
    return text[start:end]


def problems(text):
    sec = online_section(text)
    found = []
    if not re.search(r"-ge\s+3\b", sec):
        found.append("the scenario must stop after three runs")
    if not re.search(r"if\s*\(\s*\$connReachableFound\s*-or\s*-not\s*\$connNoInternetSeen\s*-or\s*\$connAttempts\s*-ge\s*3\s*\)\s*\{\s*break\s*\}", sec):
        found.append("the loop must break on reachable, on a log without the offline line, or after three runs")
    if "REQ-013: Connectivity check: no internet detected" not in sec:
        found.append("the retry must be keyed on the product's own offline line")
    if not re.search(r"pass\s*=\s*\$connReachableFound\b", sec):
        found.append("the row must pass only on the reachable line of the last run")
    if "attempts = $connAttempts" not in sec or "noInternetSeen = $connNoInternetSeen" not in sec:
        found.append("the row must record attempts and noInternetSeen")
    if re.search(r"pass\s*=\s*\$true", sec):
        found.append("the row must not pass unconditionally")
    return found


GOOD = """# ===== REQ-013: Connectivity guard ONLINE (reachable) cascade path =====
while ($true) {
    $connAttempts++
    $connReachableFound = $connOnlineText -match [regex]::Escape('REQ-013: Connectivity check: internet reachable')
    $connNoInternetSeen = $connOnlineText -match [regex]::Escape('REQ-013: Connectivity check: no internet detected')
    if ($connReachableFound -or -not $connNoInternetSeen -or $connAttempts -ge 3) { break }
    Start-Sleep -Seconds 20
}
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.online'
    pass    = $connReachableFound
    details = [ordered]@{ reachableLogFound = $connReachableFound; attempts = $connAttempts; noInternetSeen = $connNoInternetSeen }
})
# ===== REQ-013: Connectivity guard Y-RETRY re-prompt loop =====
"""


class OnlineRowRetry(unittest.TestCase):
    def test_script(self):
        self.assertEqual(problems(SCRIPT.read_text(encoding="utf-8")), [])

    def test_good_shape_is_clean(self):
        self.assertEqual(problems(GOOD), [])

    def test_endless_retry_is_caught(self):
        bad = GOOD.replace(" -or $connAttempts -ge 3", "").replace("-ge 3", "-ge 30")
        self.assertTrue(any("three runs" in f or "loop must break" in f for f in problems(bad)), problems(bad))

    def test_retry_of_a_real_failure_is_caught(self):
        bad = GOOD.replace("-not $connNoInternetSeen", "$false")
        self.assertTrue(any("loop must break" in f for f in problems(bad)), problems(bad))

    def test_unconditional_pass_is_caught(self):
        bad = GOOD.replace("pass    = $connReachableFound", "pass    = $true")
        self.assertTrue(any("pass only on the reachable line" in f for f in problems(bad)), problems(bad))

    def test_missing_attempt_count_is_caught(self):
        bad = GOOD.replace("attempts = $connAttempts; ", "")
        self.assertTrue(any("record attempts" in f for f in problems(bad)), problems(bad))

    def test_retry_not_keyed_on_the_offline_line_is_caught(self):
        bad = GOOD.replace("no internet detected", "something else")
        self.assertTrue(any("offline line" in f for f in problems(bad)), problems(bad))


if __name__ == "__main__":
    unittest.main()

import unittest

from tools.diag.publish_index import _validate_iterate_status_line


class IterateStatusLineTest(unittest.TestCase):
    def test_accepts_single_iterate_logs_line(self) -> None:
        sample = "\n".join(
            [
                "# CI Diagnostics",
                "",
                "## Status",
                "* Iterate logs: found",
                "- Batch-check run id: missing",
            ]
        )
        # Should not raise
        _validate_iterate_status_line(sample)

    def test_rejects_missing_iterate_logs_line(self) -> None:
        sample = "\n".join(["# CI Diagnostics", "", "## Status"])
        with self.assertRaises(ValueError):
            _validate_iterate_status_line(sample)

    def test_rejects_multiple_iterate_logs_lines(self) -> None:
        sample = "\n".join(
            [
                "# CI Diagnostics",
                "",
                "## Status",
                "* Iterate logs: found",
                "* Iterate logs: missing",
            ]
        )
        with self.assertRaises(ValueError):
            _validate_iterate_status_line(sample)


if __name__ == "__main__":
    unittest.main()

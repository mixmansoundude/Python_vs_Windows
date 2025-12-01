import pytest

from tools import apply_patch


def _run_patch(tmp_path, patch_text):
    target = tmp_path / "file.txt"
    target.write_text("old\n", encoding="utf-8")

    def _open(path):
        return (tmp_path / path).read_text(encoding="utf-8")

    def _write(path, content):
        path_obj = tmp_path / path
        path_obj.parent.mkdir(parents=True, exist_ok=True)
        path_obj.write_text(content, encoding="utf-8")

    def _remove(path):
        (tmp_path / path).unlink()

    result = apply_patch.process_patch(patch_text, _open, _write, _remove)
    assert result == "Done!"
    return target.read_text(encoding="utf-8")


def _build_unified_diff(content: str) -> str:
    return "\n".join(
        [
            "--- a/file.txt",
            "+++ b/file.txt",
            "@@",
            content,
            "",
        ]
    )


def test_accepts_diff_fence(tmp_path):
    patch = "```diff\n" + _build_unified_diff("-old\n+new") + "\n```"
    result = _run_patch(tmp_path, patch)
    assert result == "new\n"


def test_accepts_patch_fence(tmp_path):
    patch = "```patch\n" + _build_unified_diff("-old\n+new") + "\n```"
    result = _run_patch(tmp_path, patch)
    assert result == "new\n"


def test_accepts_bare_code_fence(tmp_path):
    patch = "```\n" + _build_unified_diff("-old\n+new") + "\n```"
    result = _run_patch(tmp_path, patch)
    assert result == "new\n"


def test_non_fenced_text_raises_diff_error(tmp_path):
    with pytest.raises(apply_patch.DiffError):
        _run_patch(tmp_path, "this is not a diff")

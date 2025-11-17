import argparse
import json

from tools import inline_model_fix as imf


def test_fail_list_filters_none(tmp_path):
    fail_path = tmp_path / "batchcheck_failing.txt"
    fail_path.write_text("none\n\n", encoding="utf-8")

    path, entries = imf._load_fail_list_from_candidates([tmp_path])

    assert path == fail_path
    assert entries == []


def test_record_decision_tracks_patch_count(tmp_path):
    ctx_dir = tmp_path

    imf._record_decision(
        ctx_dir,
        status="success",
        reason="diff_generated",
        response_payload={},
        patch_text="diff-content\n",
        model="gpt-5-codex",
        patch_count=1,
    )
    decision_path = ctx_dir / "decision.json"
    decision = json.loads(decision_path.read_text(encoding="utf-8"))
    assert decision["patches_applied_count"] == 1

    imf._record_decision(
        ctx_dir,
        status="skipped",
        reason="no_failing_tests",
        response_payload=None,
        patch_text="",
        model="gpt-5-codex",
        patch_count=0,
    )
    decision = json.loads(decision_path.read_text(encoding="utf-8"))
    assert decision["patches_applied_count"] == 0


def test_call_phase_skips_when_patch_limit_hit(tmp_path, monkeypatch):
    repo_root = tmp_path
    monkeypatch.chdir(repo_root)

    diag_root = repo_root / "diag"
    diag_root.mkdir()
    (diag_root / "batchcheck_failing.txt").write_text("case-1\n", encoding="utf-8")

    ctx_dir = imf.ensure_ctx(repo_root)
    imf._record_decision(
        ctx_dir,
        status="success",
        reason="diff_generated",
        response_payload={},
        patch_text="diff-content\n",
        model="gpt-5-codex",
        patch_count=1,
    )

    monkeypatch.setenv("DIAG", str(diag_root))
    args = argparse.Namespace(model="gpt-5-codex")
    imf.call_phase(args)

    decision_path = ctx_dir / "decision.json"
    decision = json.loads(decision_path.read_text(encoding="utf-8"))
    assert decision["patches_applied_count"] == 1
    assert decision["status"] == "skipped"
    assert decision["reason"] == "patch_limit_reached"

    patch_text = (ctx_dir / "fix.patch").read_text(encoding="utf-8")
    assert "diff-content" in patch_text

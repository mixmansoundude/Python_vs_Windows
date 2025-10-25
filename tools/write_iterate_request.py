"""Helper to build Responses API request with repo bundle attachment."""
from __future__ import annotations

import json
import pathlib
import sys


def main() -> int:
    if len(sys.argv) != 6:
        print(
            "usage: write_iterate_request.py <prompt_path> <out_path> <model> <file_id> <max_tokens>",
            file=sys.stderr,
        )
        return 1

    prompt_path = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    model = sys.argv[3]
    file_id = sys.argv[4]
    try:
        max_tokens = int(sys.argv[5])
    except ValueError:
        print("max_tokens must be an integer", file=sys.stderr)
        return 1

    prompt = prompt_path.read_text(encoding="utf-8")
    # derived requirement: keep iterate prompt lean while shipping the curated repo
    # bundle via code_interpreter so the model can open files on demand.
    payload = {
        "model": model,
        "tools": [{"type": "code_interpreter"}],
        "input": [
            {
                "role": "system",
                "content": [
                    {
                        "type": "input_text",
                        "text": (
                            "You are an expert software engineer that proposes precise, "
                            "minimal unified diffs."
                        ),
                    }
                ],
            },
            {
                "role": "user",
                "content": [
                    {"type": "input_text", "text": prompt},
                    {"type": "input_file", "file_id": file_id},
                ],
            },
        ],
        "max_output_tokens": max_tokens,
    }

    out_path.write_text(json.dumps(payload), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Unit tests for _findings_lib. Runnable standalone: python3 tests/test_findings_lib.py"""
import json, os, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
from _findings_lib import norm, load_findings  # noqa: E402

def test_norm_strips_line_numbers_and_parens():
    assert norm("SKILL.md:106-109") == "skill.md"
    assert norm("scripts/glm_review.sh:119 (the echo)") == "scripts/glm_review.sh"
    assert norm("References/Rubric.md") == "references/rubric.md"

def test_norm_same_location_different_lines_matches():
    assert norm("scripts/glm_review.sh:119-120") == norm("scripts/glm_review.sh:120")

def test_norm_handles_none():
    assert norm(None) == ""

def test_load_findings_roundtrip():
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump({"findings": []}, fh); p = fh.name
    try:
        assert load_findings(p) == {"findings": []}
    finally:
        os.unlink(p)

if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn(); print(f"  ok   {fn.__name__}")
    print(f"{len(fns)} passed")

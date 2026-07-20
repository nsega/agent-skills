"""Shared helpers for cross-review finding tools.

Kept in one place so the location-normalization used by the disagreement checker
(check_disagreements.sh) and the multi-pass aggregator (aggregate_passes.py)
cannot drift apart. See the design spec under docs/superpowers/specs/.
"""
import json
import re


def norm(loc):
    """Normalize a location for matching: lowercase, drop line numbers and
    parenthetical asides, keep the file/section stem."""
    loc = (loc or "").lower().strip()
    loc = re.sub(r"\(.*?\)", "", loc)
    loc = re.sub(r"[:#]\s*l?\d+(\s*[-–]\s*\d+)?", "", loc)
    return re.sub(r"\s+", " ", loc).strip(" .,:;-")


def loc_key(location):
    """Exact-location key for aggregating repeated passes over the SAME packet.
    Keeps file:line (the same issue cites the same line across passes), unlike
    norm(), which strips the line for cross-REVIEWER matching in the checker."""
    loc = (location or "").lower().strip()
    loc = re.sub(r"\(.*?\)", "", loc)
    return re.sub(r"\s+", " ", loc).strip(" .,:;-")


def load_findings(path):
    """Load a findings document. Raises OSError / json.JSONDecodeError on failure."""
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)

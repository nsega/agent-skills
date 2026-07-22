"""Shared helpers for cross-review finding tools.

Kept in one place so the location-normalization used by the disagreement checker
(check_disagreements.sh) and the multi-pass aggregator (aggregate_passes.py)
cannot drift apart. See the design spec under docs/superpowers/specs/.
"""
import json
import re


def _strip_parens(s):
    """Remove parenthetical asides, innermost-out, so nested parens like
    '(handles the (edge) case)' are fully removed rather than half-stripped."""
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\([^()]*\)", "", s)
    return s


def _normalize(loc, keep_line):
    """Shared location normalization. `keep_line=False` also strips line numbers
    (for cross-REVIEWER matching); `keep_line=True` keeps file:line (for
    cross-PASS matching over one packet)."""
    loc = (loc or "").lower().strip()
    loc = _strip_parens(loc)
    if not keep_line:
        loc = re.sub(r"[:#]\s*l?\d+(\s*[-–]\s*\d+)?", "", loc)
    return re.sub(r"\s+", " ", loc).strip(" .,:;-")


def norm(loc):
    """Normalize a location for matching: lowercase, drop line numbers and
    parenthetical asides, keep the file/section stem. Used by the checker."""
    return _normalize(loc, keep_line=False)


def loc_key(location):
    """Exact-location key for aggregating repeated passes over the SAME packet.
    Keeps file:line (the same issue cites the same line across passes), unlike
    norm(), which strips the line for cross-REVIEWER matching in the checker."""
    return _normalize(location, keep_line=True)


def issue_norm(issue):
    """Normalize a finding's issue text into a content identity: lowercase alnum
    tokens, single-spaced. Two passes merge only when BOTH location and this
    signal match, so distinct issues at one location never collapse and are never
    paired by position. Reworded restatements under-count agreement rather than
    risk a wrong merge."""
    return re.sub(r"[^a-z0-9]+", " ", (issue or "").lower()).strip()


def load_findings(path):
    """Load a findings document. Raises OSError / json.JSONDecodeError on failure."""
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)

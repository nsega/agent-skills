#!/usr/bin/env python3
"""expand_cites.py: expand and validate {{cite:...}} macros in a wiki.

Usage: expand_cites.py [--repo OWNER/REPO] [--sha SHA] [WIKI.md]

Run it from the root of the repo the wiki describes: cited paths are read
relative to the current directory. WIKI.md defaults to wiki.md and is
rewritten in place.

Each {{cite:RELPATH:START-END}}, {{cite:RELPATH:LINE}} or {{cite:RELPATH}}
becomes a link pinned to the commit:
  [RELPATH:START-END](https://github.com/OWNER/REPO/blob/SHA/RELPATH#LSTART-LEND)
and is checked: the path must exist and the range must end within the file.

--repo defaults to the origin remote (git@, ssh:// and https:// forms) and
--sha to `git rev-parse HEAD`.

Prints one summary line to stdout. Exits 1, with one line per bad citation
on stderr, when a path is missing, a range runs past the end of its file, or
a macro is left unexpanded. Standard library only.
"""
import argparse
import pathlib
import re
import subprocess
import sys


def git(*args):
    return subprocess.run(
        ["git", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def owner_repo_from_remote(url):
    """owner/repo from a git@host:o/r.git, ssh://git@host/o/r or https URL."""
    m = re.match(r"^(?:[\w.+-]+://)?(?:[^@/]+@)?[^/:]+[:/](.+?)(?:\.git)?/?$", url)
    if not m:
        return None
    parts = m.group(1).split("/")
    return "/".join(parts[-2:]) if len(parts) >= 2 else None


def resolve_facts(repo, sha):
    if repo is None:
        try:
            url = git("remote", "get-url", "origin")
        except (OSError, subprocess.CalledProcessError):
            sys.exit("expand_cites: no origin remote; pass --repo OWNER/REPO")
        repo = owner_repo_from_remote(url)
        if repo is None:
            sys.exit(f"expand_cites: cannot read owner/repo from {url!r}; pass --repo")
    if sha is None:
        try:
            sha = git("rev-parse", "HEAD")
        except (OSError, subprocess.CalledProcessError):
            sys.exit("expand_cites: no commit to pin; pass --sha")
    return repo, sha


def expand(src, sha, owner_repo):
    """The step-6 expander from SKILL.md, unchanged: returns (out, problems)."""
    base = f"https://github.com/{owner_repo}/blob/{sha}/"
    problems = []

    def repl(m):
        body = m.group(1)
        if re.search(r":\d+(-\d+)?$", body):
            path, lines = body.rsplit(":", 1); s, _, e = lines.partition("-"); e = e or s
            n = len(pathlib.Path(path).read_text().splitlines()) if pathlib.Path(path).exists() else None
            if n is None: problems.append(f"missing {path}")
            elif int(e) > n: problems.append(f"range {path}:{lines} > {n}")
            anchor = f"#L{s}" + (f"-L{e}" if e != s else "")
            return f"[{path}:{lines}]({base}{path}{anchor})"
        if not pathlib.Path(body).exists(): problems.append(f"missing {body}")
        return f"[{body}]({base}{body})"

    out = re.sub(r"\{\{cite:([^}]+)\}\}", repl, src)
    return out, problems


def main(argv=None):
    ap = argparse.ArgumentParser(description="Expand and validate {{cite:...}} macros in a wiki.")
    ap.add_argument("--repo", help="OWNER/REPO (default: from the origin remote)")
    ap.add_argument("--sha", help="commit to pin links to (default: HEAD)")
    ap.add_argument("wiki", nargs="?", default="wiki.md", help="wiki to rewrite in place")
    args = ap.parse_args(argv)

    owner_repo, sha = resolve_facts(args.repo, args.sha)
    wiki = pathlib.Path(args.wiki)
    out, problems = expand(wiki.read_text(), sha, owner_repo)
    wiki.write_text(out)
    print("UNRESOLVED:", out.count("{{cite"), "PROBLEMS:", problems or "none")

    for p in problems:
        print(f"{wiki}: {p}", file=sys.stderr)
    for left in re.findall(r"\{\{cite[^}\n]*\}*", out):
        print(f"{wiki}: unresolved {left}", file=sys.stderr)
    return 1 if problems or "{{cite" in out else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
set -euo pipefail
# models/dual-model.json is the one place model ids and defaults live for the
# dual-model-* skills. This suite fails when a skill's copy drifts from it, when
# the opencode config disagrees with it, or when an id shows up anywhere else.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DATA="$ROOT/models/dual-model.json"
SKILLS="dual-model-review dual-model-debate"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 1: the source parses and says when and from where it was last checked.
python3 - "$DATA" <<'PY' && ok || bad "models/dual-model.json needs a YYYY-MM-DD as_of and at least one source"
import json, re, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if re.fullmatch(r"\d{4}-\d{2}-\d{2}", d.get("as_of", "")) and d.get("sources") else 1)
PY

# 2: each skill folder carries a byte-identical copy (`make models` writes it).
for s in $SKILLS; do
  cmp -s "$DATA" "$ROOT/skills/$s/models.json" && ok \
    || bad "skills/$s/models.json differs from models/dual-model.json: run 'make models'"
done

# 3: both skills default to the same GPT model.
python3 - "$DATA" <<'PY' && ok || bad "review and debate must share one codex default model"
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d["review"]["backends"]["codex"]["model"] == d["debate"]["codex"]["model"] else 1)
PY

# 4: the opencode config names exactly the Zen ids the data file declares.
python3 - "$DATA" "$ROOT/skills/dual-model-review/config/opencode.zen.json" <<'PY' && ok || bad "config/opencode.zen.json disagrees with models/dual-model.json"
import json, re, sys
d = json.load(open(sys.argv[1]))["review"]
# JSONC: drop whole-line // comments (the "$schema" URL is not at line start).
cfg = json.loads(re.sub(r"(?m)^\s*//.*$", "", open(sys.argv[2], encoding="utf-8").read()))
want = sorted(b["model"].split("/", 1)[1] for b in d["backends"].values()
              if b["model"].startswith("opencode/"))
got = sorted(cfg["provider"]["opencode"]["models"])
if got != want:
    sys.exit(f"provider.opencode.models is {got}, data file says {want}")
if cfg["small_model"] != d["opencode_small_model"]:
    sys.exit(f"small_model is {cfg['small_model']}, data file says {d['opencode_small_model']}")
PY

# 5: no model id or versioned model name outside the data file. Scans README.md,
# the Makefile and both skill folders, except tests/ (fixtures assert defaults)
# and the models.json copies. The opencode config may hold only the ids from 4.
python3 - "$DATA" "$ROOT" $SKILLS <<'PY' && ok || bad "a model id or versioned model name lives outside models/dual-model.json (listed above)"
import json, os, re, sys
data, root, skills = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3:]

# Every id and label the data file knows, plus the shapes a future id would take.
known = set(data["codex_catalog"]["models"])
def walk(node):
    if isinstance(node, dict):
        for key, val in node.items():
            if key in ("model", "label", "flagship", "flagship_label", "opencode_small_model"):
                known.add(val)
                known.add(val.split("/")[-1])
            walk(val)
walk(data)
shapes = re.compile(
    r"gpt-\d|claude-(?:opus|sonnet|haiku|fable)-\d|(?:opus|sonnet|haiku|fable) \d"
    r"|glm-\d|kimi[- ]k\d|deepseek-v\d|"
    + "|".join(re.escape(k) for k in sorted(known, key=len, reverse=True)),
    re.IGNORECASE)

config = os.path.join("skills", "dual-model-review", "config", "opencode.zen.json")
review = data["review"]
config_ids = [b["model"].split("/", 1)[1] for b in review["backends"].values()
              if b["model"].startswith("opencode/")] + [review["opencode_small_model"]]

files = [os.path.join(root, "README.md"), os.path.join(root, "Makefile")]
for s in skills:
    for dirpath, dirnames, names in os.walk(os.path.join(root, "skills", s)):
        dirnames[:] = [n for n in dirnames if n != "tests"]
        files += [os.path.join(dirpath, n) for n in names
                  if not (n == "models.json" and dirpath.endswith(s))]

hits = 0
for path in files:
    rel = os.path.relpath(path, root)
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            text = line
            if rel == config and not line.lstrip().startswith("//"):
                for i in config_ids:
                    text = text.replace(i, "")
            m = shapes.search(text)
            if m:
                hits += 1
                print(f"{rel}:{n}: {m.group(0)}", file=sys.stderr)
sys.exit(1 if hits else 0)
PY

# 6: frontmatter descriptions load every session, so they carry no numbers at all.
for s in $SKILLS; do
  python3 - "$ROOT/skills/$s/SKILL.md" <<'PY' && ok || bad "skills/$s/SKILL.md frontmatter contains a digit (no version numbers there)"
import re, sys
front = open(sys.argv[1], encoding="utf-8").read().split("---", 2)[1]
sys.exit(1 if re.search(r"\d", front) else 0)
PY
done

# 7: the README says where the defaults live.
grep -q "models/dual-model.json" "$ROOT/README.md" && ok || bad "README.md should point at models/dual-model.json"

echo "models: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

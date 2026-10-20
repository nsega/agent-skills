#!/usr/bin/env bash
# The suites must not depend on the machine's git config. A global config
# that forces commit signing (or runs a hook through a mocked binary) used to
# break every case that builds a state repo. build_mockbin now points git at a
# private config, so this hostile one must have no effect.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n' > "$WORK/hostile.gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/hostile.gitconfig"

MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

STATE="$WORK/state"
build_state "$STATE" --git >/dev/null 2>&1 && ok || bad "build_state --git must not use the machine's global git config"
git -C "$STATE" commit --quiet --allow-empty -m again >/dev/null 2>&1 \
  && ok || bad "a commit in a test state repo must not be signed by the machine's config"
[ "$(git config --global --get commit.gpgsign || true)" != "true" ] \
  && ok || bad "git must read a private global config once build_mockbin has run"

summary "helpers hermetic"

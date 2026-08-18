# Personal Agent Skills — install/uninstall/status via per-folder symlinks.
#
# Each skill lives at <src>/<name>/SKILL.md and is symlinked (per folder) into
# the target skills dir so edits in the source repo are live (no copying).
#
# Sources linked into each Claude config:
#   REPO_SRC       this repo's own skills/ (all of them).
#   UPSTREAM_REPO  a curated subset (UPSTREAM_SKILLS) of the anthropics/skills
#                  mirror at nsega/skills. Linked WITHOUT copying so the mirror
#                  stays the upstream-tracking source of truth. Skipped if the
#                  repo isn't present locally.
#
# CLAUDE_SKILLS_DIRS is a space-separated list — one entry per Claude Code
# identity (each CLAUDE_CONFIG_DIR has its own skills/ folder). install,
# uninstall, and status run against every dir in the list.
#
# Override target/source dirs for testing:
#   CLAUDE_SKILLS_DIRS=/tmp/t make install
#   CLAUDE_SKILLS_DIRS="/tmp/a /tmp/b" make install
#   UPSTREAM_REPO=/tmp/up UPSTREAM_SKILLS="foo bar" make install
#   CODEX_SKILLS_DIR=/tmp/t2 make install-codex

CLAUDE_SKILLS_DIRS ?= $(HOME)/.claude/skills $(HOME)/.claude-work/skills
CODEX_SKILLS_DIR   ?= $(HOME)/.codex/skills

REPO_SRC        := $(abspath skills)
UPSTREAM_REPO   ?= $(HOME)/src/github.com/nsega/skills
UPSTREAM_SKILLS ?= mcp-builder skill-creator

LINK := scripts/link.sh

# oss-lab launchd job (see install-oss-lab)
OSS_LAB_PLIST_LABEL := dev.nsega.oss-scout
OSS_LAB_PLIST_SRC   := $(REPO_SRC)/oss-lab/$(OSS_LAB_PLIST_LABEL).plist
OSS_LAB_PLIST_DST   := $(HOME)/Library/LaunchAgents/$(OSS_LAB_PLIST_LABEL).plist

.PHONY: install uninstall status install-codex uninstall-codex status-codex install-oss-lab new help

help:
	@echo "Targets:"
	@echo "  install / uninstall / status            (targets: $(CLAUDE_SKILLS_DIRS))"
	@echo "  install-codex / uninstall-codex / status-codex  (target: $(CODEX_SKILLS_DIR))"
	@echo "  install-oss-lab                         symlink oss-lab + install launchd job"
	@echo "  new name=<skill-name>                   scaffold a new skill"
	@echo ""
	@echo "Sources: $(REPO_SRC) (all)"
	@echo "         $(UPSTREAM_REPO) ($(UPSTREAM_SKILLS))"

# --- Claude Code (default target) ---
# For each identity's skills dir: link all of this repo's skills, plus the
# curated upstream subset.
install:
	@for d in $(CLAUDE_SKILLS_DIRS); do \
	  echo "==> $$d"; \
	  $(LINK) install   "$$d" "$(REPO_SRC)"; \
	  $(LINK) install   "$$d" "$(UPSTREAM_REPO)" $(UPSTREAM_SKILLS); \
	done

uninstall:
	@for d in $(CLAUDE_SKILLS_DIRS); do \
	  echo "==> $$d"; \
	  $(LINK) uninstall "$$d" "$(REPO_SRC)"; \
	  $(LINK) uninstall "$$d" "$(UPSTREAM_REPO)"; \
	done

status:
	@for d in $(CLAUDE_SKILLS_DIRS); do \
	  echo "==> $$d"; \
	  $(LINK) status    "$$d" "$(REPO_SRC)"; \
	  $(LINK) status    "$$d" "$(UPSTREAM_REPO)" $(UPSTREAM_SKILLS); \
	  $(LINK) unmanaged "$$d" "$(REPO_SRC)" "$(UPSTREAM_REPO)"; \
	done

# --- oss-lab (opt-in; symlink the skill + install the hourly launchd job) ---
# Personal identity only: run-scout.sh refuses to run unless
# CLAUDE_CONFIG_DIR is the personal ~/.claude, so the work identity never
# gets this skill. The plist is COPIED (launchd dislikes symlinked plists)
# with the repo path rewritten to this checkout's location. If the copy
# changed while the job is loaded, it is unloaded first so the new plist
# takes effect; launchctl load -w runs only when the job is not loaded.
install-oss-lab:
	@echo "==> $(HOME)/.claude/skills"
	@$(LINK) install "$(HOME)/.claude/skills" "$(REPO_SRC)" oss-lab
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	@tmp=$$(mktemp); \
	sed 's|~/dev/agent-skills|$(abspath .)|' "$(OSS_LAB_PLIST_SRC)" > "$$tmp"; \
	if cmp -s "$$tmp" "$(OSS_LAB_PLIST_DST)"; then \
	  rm -f "$$tmp"; echo "ok      $(OSS_LAB_PLIST_DST) (unchanged)"; \
	else \
	  if launchctl list "$(OSS_LAB_PLIST_LABEL)" >/dev/null 2>&1; then \
	    launchctl unload "$(OSS_LAB_PLIST_DST)" 2>/dev/null || true; \
	    echo "unloaded $(OSS_LAB_PLIST_LABEL) (plist changed)"; \
	  fi; \
	  mv "$$tmp" "$(OSS_LAB_PLIST_DST)"; \
	  echo "copied  $(OSS_LAB_PLIST_DST)"; \
	fi
	@if launchctl list "$(OSS_LAB_PLIST_LABEL)" >/dev/null 2>&1; then \
	  echo "loaded  $(OSS_LAB_PLIST_LABEL) (already loaded)"; \
	else \
	  launchctl load -w "$(OSS_LAB_PLIST_DST)" && echo "loaded  $(OSS_LAB_PLIST_LABEL)"; \
	fi

# --- Codex (opt-in; this repo's own skills only) ---
install-codex:
	@$(LINK) install   "$(CODEX_SKILLS_DIR)" "$(REPO_SRC)"

uninstall-codex:
	@$(LINK) uninstall "$(CODEX_SKILLS_DIR)" "$(REPO_SRC)"

status-codex:
	@$(LINK) status    "$(CODEX_SKILLS_DIR)" "$(REPO_SRC)"
	@$(LINK) unmanaged "$(CODEX_SKILLS_DIR)" "$(REPO_SRC)"

# --- Scaffold ---
new:
	@scripts/new.sh "$(name)"

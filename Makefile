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

.PHONY: install uninstall status install-codex uninstall-codex status-codex new help

help:
	@echo "Targets:"
	@echo "  install / uninstall / status            (targets: $(CLAUDE_SKILLS_DIRS))"
	@echo "  install-codex / uninstall-codex / status-codex  (target: $(CODEX_SKILLS_DIR))"
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
	done

# --- Codex (opt-in; this repo's own skills only) ---
install-codex:
	@$(LINK) install   "$(CODEX_SKILLS_DIR)" "$(REPO_SRC)"

uninstall-codex:
	@$(LINK) uninstall "$(CODEX_SKILLS_DIR)" "$(REPO_SRC)"

status-codex:
	@$(LINK) status    "$(CODEX_SKILLS_DIR)" "$(REPO_SRC)"

# --- Scaffold ---
new:
	@scripts/new.sh "$(name)"

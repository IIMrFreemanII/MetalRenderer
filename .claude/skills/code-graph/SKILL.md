---
name: code-graph
description: Build graphify's knowledge graph with `graphify update .` when this checkout doesn't have one. Use whenever graphify-out/graph.json is missing - a fresh worktree, `graphify query`, `path` or `explain` failing with "graph file not found", or before a codebase question CLAUDE.md says to answer with the graph first - instead of skipping the graph and grepping.
---

# Build the graph when it's missing

CLAUDE.md answers codebase questions with `graphify query`, `path` and `explain` first. They read
`graphify-out/graph.json`, which is gitignored, so every new worktree under `.claude/worktrees/` starts without it, and
the query fails with `graph file not found`. The `graphify hook-guard` hook can still say the graph exists: it sees the
main checkout's. Trust the query's error, not the hook.

## Rules

* **A missing graph is built, not skipped.** Don't fall back to grep because the graph isn't there: build it, then run
  the query you meant to run.
* Build it with `graphify update .` in this checkout. It is AST only: no API cost, and about 4 s for the whole repo.
* Don't copy the main checkout's `graphify-out/`: it describes that tree, not this branch.
* A graph that is there but stale is refreshed with `graphify update .` after changing code, as CLAUDE.md says. The
  script below only builds a missing one.

## Run it: `scripts/ensure-graph.sh`

```bash
.claude/skills/code-graph/scripts/ensure-graph.sh
```
* It builds `graphify-out/graph.json` at the checkout's root with `graphify update .` when it is missing, and does
  nothing when it is there.
* `--check` only reports: exit 0 when the graph is there, 1 when it is missing.
* A `SessionStart` hook in `.claude/settings.json` runs it at the start of every session, so a new worktree usually
  has its graph before the first query. Run it by hand when the graph is still missing, or was deleted mid-session.

By hand, from the checkout's root:
```bash
graphify update .
```

#!/usr/bin/env bash
# scripts/snapshot.sh - TimeMachine-style local snapshot checkpoint
# Usage: ./scripts/snapshot.sh "optional turn or task summary"
#
# Creates a local git commit snapshot recording all staged, unstaged, and untracked files
# with a timestamp. This allows agents and users to jump back in time to any previous state
# without pushing to a remote repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SUMMARY="${*:-Turn checkpoint}"
TIMESTAMP="$(date "+%Y-%m-%d %H:%M:%S")"

# Check if there are uncommitted changes or untracked files
if git diff --quiet && git diff --cached --quiet && [ -z "$(git status --porcelain)" ]; then
    echo "TimeMachine: Workspace is clean. Nothing to snapshot."
    exit 0
fi

echo "TimeMachine: Creating local snapshot checkpoint..."
git add -A
git commit -m "[Snapshot TimeMachine] $SUMMARY - $TIMESTAMP"

HASH="$(git rev-parse --short HEAD)"
echo "TimeMachine: Snapshot created successfully -> $HASH"
echo "  To jump to this snapshot: git checkout $HASH"
echo "  To view snapshot history: git log --oneline --grep=\"TimeMachine\" -n 10"

#!/bin/bash
# Runs every 60s via launchd (com.inference.sync). Fetches origin and, if the
# remote branch has a commit we haven't applied yet, hard-resets the working
# tree to it and runs apply.sh. The applied commit is recorded only on a
# successful apply, so a failed apply is retried on the next tick.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$HOME/.local/state/inference-server"
APPLIED_FILE="$STATE_DIR/applied-commit"
BRANCH="${INFERENCE_BRANCH:-main}"
mkdir -p "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [sync] $*"; }

cd "$REPO_DIR"

if ! git fetch --quiet origin "$BRANCH"; then
  log "git fetch failed (offline?); will retry next interval"
  exit 0
fi

REMOTE="$(git rev-parse "origin/$BRANCH")"
APPLIED="$(cat "$APPLIED_FILE" 2>/dev/null || echo none)"

if [ "$REMOTE" = "$APPLIED" ]; then
  exit 0
fi

log "new commit on origin/$BRANCH: $REMOTE (last applied: $APPLIED)"
git checkout --quiet "$BRANCH" 2>/dev/null || true
git reset --hard --quiet "origin/$BRANCH"

if "$REPO_DIR/scripts/apply.sh"; then
  echo "$REMOTE" > "$APPLIED_FILE"
  log "applied $REMOTE"
else
  log "apply failed; will retry next interval"
  exit 1
fi

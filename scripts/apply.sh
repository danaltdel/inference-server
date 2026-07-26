#!/bin/bash
# Idempotent "make the machine match the repo" step. Run by sync.sh after
# every repo update and once by bootstrap.sh. Safe to run by hand.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$HOME/.local/state/inference-server"
SERVICE="gui/$(id -u)/com.inference.ollama"
mkdir -p "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [apply] $*"; }

# ---- 1. dependencies ------------------------------------------------------
if ! command -v ollama >/dev/null 2>&1; then
  log "ollama not found; installing standalone binary"
  "$REPO_DIR/scripts/install-ollama.sh"
fi

# ---- 2. server config -----------------------------------------------------
set -a
source "$REPO_DIR/config/server.env"
set +a

PORT="${OLLAMA_HOST##*:}"
[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=11434
API="http://127.0.0.1:$PORT"

# ---- 3. restart the server if its config changed --------------------------
if ! launchctl print "$SERVICE" >/dev/null 2>&1; then
  log "service com.inference.ollama is not loaded; run bootstrap.sh first"
  exit 1
fi

CONFIG_HASH="$(cat "$REPO_DIR/config/server.env" "$REPO_DIR/scripts/run-server.sh" | shasum -a 256 | cut -d' ' -f1)"
LAST_HASH="$(cat "$STATE_DIR/server-config-hash" 2>/dev/null || true)"

if [ "$CONFIG_HASH" != "$LAST_HASH" ]; then
  log "server config changed; restarting ollama"
  launchctl kickstart -k "$SERVICE"
  echo "$CONFIG_HASH" > "$STATE_DIR/server-config-hash"
fi

# ---- 3b. web test page service --------------------------------------------
WEB_SERVICE="gui/$(id -u)/com.inference.web"
if launchctl print "$WEB_SERVICE" >/dev/null 2>&1; then
  WEB_HASH="$(cat "$REPO_DIR/config/server.env" "$REPO_DIR/scripts/run-web.sh" "$REPO_DIR/scripts/serve.py" | shasum -a 256 | cut -d' ' -f1)"
  LAST_WEB_HASH="$(cat "$STATE_DIR/web-config-hash" 2>/dev/null || true)"
  if [ "$WEB_HASH" != "$LAST_WEB_HASH" ]; then
    log "web server config changed; restarting"
    launchctl kickstart -k "$WEB_SERVICE"
    echo "$WEB_HASH" > "$STATE_DIR/web-config-hash"
  fi
else
  # Non-fatal: the API is the product, the test page is a convenience.
  log "NOTE: com.inference.web not loaded; re-run bootstrap.sh to enable the test page"
fi

# ---- 4. wait for the API --------------------------------------------------
UP=false
for _ in $(seq 1 30); do
  if curl -fsS --max-time 2 "$API/api/version" >/dev/null 2>&1; then
    UP=true
    break
  fi
  sleep 2
done
if [ "$UP" != true ]; then
  log "server did not answer on $API after 60s; check ollama.log"
  exit 1
fi

# ---- 5. sync models -------------------------------------------------------
WANTED=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(echo "$line" | xargs)"
  [ -n "$line" ] && WANTED+=("$line")
done < "$REPO_DIR/config/models.txt"

if [ "${#WANTED[@]}" -eq 0 ]; then
  log "config/models.txt lists no models; nothing to pull"
else
  for model in "${WANTED[@]}"; do
    log "ensuring model: $model"
    OLLAMA_HOST="127.0.0.1:$PORT" ollama pull "$model"
  done
fi

if [ "${INFERENCE_PRUNE_MODELS:-false}" = "true" ] && [ "${#WANTED[@]}" -gt 0 ]; then
  while IFS= read -r installed; do
    keep=false
    for model in "${WANTED[@]}"; do
      [ "$installed" = "$model" ] && keep=true
    done
    if [ "$keep" = false ]; then
      log "pruning model not in models.txt: $installed"
      OLLAMA_HOST="127.0.0.1:$PORT" ollama rm "$installed"
    fi
  done < <(OLLAMA_HOST="127.0.0.1:$PORT" ollama list | tail -n +2 | awk '{print $1}')
fi

# ---- 6. flag launchd template changes (need a re-bootstrap) ----------------
PLIST_HASH="$(cat "$REPO_DIR"/launchd/*.tmpl | shasum -a 256 | cut -d' ' -f1)"
LAST_PLIST_HASH="$(cat "$STATE_DIR/plist-hash" 2>/dev/null || true)"
if [ -n "$LAST_PLIST_HASH" ] && [ "$PLIST_HASH" != "$LAST_PLIST_HASH" ]; then
  log "NOTE: launchd/ templates changed; run bootstrap.sh again on this machine to apply them"
fi
echo "$PLIST_HASH" > "$STATE_DIR/plist-hash"

log "apply complete"

#!/bin/bash
# Quick health overview. Run over ssh from anywhere:
#   ssh mac-studio '~/inference-server/scripts/status.sh'
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
source "$REPO_DIR/config/server.env"
set +a
PORT="${OLLAMA_HOST##*:}"
[[ "$PORT" =~ ^[0-9]+$ ]] || PORT=11434

echo "== launchd services =="
launchctl list | grep com.inference || echo "  none loaded - run bootstrap.sh"

echo
echo "== repo =="
git -C "$REPO_DIR" log --oneline -1
echo "  applied: $(cat "$HOME/.local/state/inference-server/applied-commit" 2>/dev/null || echo never)"

echo
echo "== server =="
if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/api/version" 2>/dev/null; then
  echo
  echo "-- loaded models --"
  OLLAMA_HOST="127.0.0.1:$PORT" ollama ps
  echo "-- installed models --"
  OLLAMA_HOST="127.0.0.1:$PORT" ollama list
else
  echo "  NOT RESPONDING on port $PORT (see ~/Library/Logs/inference-server/ollama.log)"
fi

echo
echo "== test page =="
WEB_PORT="${INFERENCE_WEB_PORT:-8080}"
if curl -fsS --max-time 2 "http://127.0.0.1:$WEB_PORT/" >/dev/null 2>&1; then
  echo "  serving on :$WEB_PORT"
else
  echo "  NOT RESPONDING on :$WEB_PORT (see ~/Library/Logs/inference-server/web.log)"
fi

echo
echo "== disk =="
df -h / | tail -1

echo
echo "== recent sync log =="
tail -5 "$HOME/Library/Logs/inference-server/sync.log" 2>/dev/null || echo "  no log yet"

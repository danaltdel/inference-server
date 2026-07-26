#!/bin/bash
# Serves web/ (the browser test page) on INFERENCE_WEB_PORT.
# Invoked by launchd (com.inference.web).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
source "$REPO_DIR/config/server.env"
set +a

exec python3 "$REPO_DIR/scripts/serve.py" "${INFERENCE_WEB_PORT:-8080}" "$REPO_DIR/web"

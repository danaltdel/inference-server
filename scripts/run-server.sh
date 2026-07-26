#!/bin/bash
# Runs the Ollama server with settings from config/server.env.
# Invoked by launchd (com.inference.ollama); don't run it manually while the
# service is loaded or the two will fight over the port.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
source "$REPO_DIR/config/server.env"
set +a

exec ollama serve

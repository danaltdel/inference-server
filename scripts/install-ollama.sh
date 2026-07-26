#!/bin/bash
# Installs the standalone Ollama CLI into ~/.local/bin from the official
# GitHub release tarball. No Homebrew, no sudo - works for a standard
# (non-admin) macOS user. Used by bootstrap.sh and apply.sh; safe to run
# by hand. Pass --force to reinstall/upgrade an existing binary.
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

BIN_DIR="${INFERENCE_BIN_DIR:-$HOME/.local/bin}"
FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [install-ollama] $*"; }

if command -v ollama >/dev/null 2>&1 && [ "$FORCE" != true ]; then
  log "already installed: $(command -v ollama) ($(ollama --version 2>&1 | grep -i version | head -1 || true))"
  exit 0
fi

URL="$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*ollama-darwin\.tgz"' \
  | grep -o 'https://[^"]*' | head -1)"
if [ -z "$URL" ]; then
  log "could not resolve the ollama-darwin.tgz download URL from the GitHub API"
  exit 1
fi

log "downloading $URL"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fSL --progress-bar "$URL" -o "$TMP/ollama.tgz"
tar -xzf "$TMP/ollama.tgz" -C "$TMP"

if [ ! -f "$TMP/ollama" ]; then
  log "unexpected tarball layout - no 'ollama' binary at the root:"
  ls -la "$TMP"
  exit 1
fi

mkdir -p "$BIN_DIR"
# Copy everything extracted (binary plus any bundled libs), not the tarball.
find "$TMP" -mindepth 1 -maxdepth 1 ! -name ollama.tgz -exec cp -R {} "$BIN_DIR"/ \;
chmod +x "$BIN_DIR/ollama"

log "installed to $BIN_DIR: $("$BIN_DIR/ollama" --version 2>&1 | grep -i version | head -1 || echo ollama)"

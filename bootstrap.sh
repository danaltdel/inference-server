#!/bin/bash
# One-time setup. Run this ON the Mac Studio, as the user that will stay
# logged in. Works for a standard (non-admin) account: no Homebrew, no sudo.
# Re-running it is safe (it updates the clone and reloads the services).
#
# Option A - clone first:
#   git clone https://github.com/danaltdel/inference-server.git ~/inference-server
#   ~/inference-server/bootstrap.sh
#
# Option B - one-liner for a public repo (also updates an existing clone):
#   curl -fsSL https://raw.githubusercontent.com/danaltdel/inference-server/main/bootstrap.sh \
#     | REPO_URL=https://github.com/danaltdel/inference-server.git bash
#
# Env / flags:
#   REPO_URL      git URL to clone (required for option B on first run)
#   REPO_DIR      where the clone lives (default: ~/inference-server)
#   --keep-awake  obsolete no-op; the com.inference.awake service (caffeinate)
#                 now prevents sleep without needing sudo
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_DIR="${REPO_DIR:-$HOME/inference-server}"
BRANCH="${INFERENCE_BRANCH:-main}"
for arg in "$@"; do
  case "$arg" in
    --keep-awake) echo "[bootstrap] note: --keep-awake is obsolete (handled by the awake service)" ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[bootstrap] $*"; }

# If this script is already inside a clone of the repo, use that clone as-is.
IN_CLONE=false
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -d "$SCRIPT_DIR/.git" ]; then
    REPO_DIR="$SCRIPT_DIR"
    IN_CLONE=true
  fi
fi

# Piped/standalone invocation: clone the repo (or bring an existing clone up
# to date), then hand off to the repo's own copy of this script so what runs
# is always the current version.
if [ "$IN_CLONE" != true ]; then
  if [ -d "$REPO_DIR/.git" ]; then
    log "updating existing clone at $REPO_DIR"
    git -C "$REPO_DIR" fetch origin "$BRANCH"
    git -C "$REPO_DIR" reset --hard "origin/$BRANCH"
  else
    : "${REPO_URL:?Set REPO_URL=https://github.com/you/repo.git when piping this script}"
    log "cloning $REPO_URL -> $REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
  fi
  exec "$REPO_DIR/bootstrap.sh" "$@"
fi

log "using repo at $REPO_DIR"

# ---- ollama (standalone binary into ~/.local/bin, no admin needed) --------
"$REPO_DIR/scripts/install-ollama.sh"

# ---- directories ----------------------------------------------------------
LOG_DIR="$HOME/Library/Logs/inference-server"
STATE_DIR="$HOME/.local/state/inference-server"
AGENTS_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR" "$STATE_DIR" "$AGENTS_DIR"

# ---- render + load launchd services ---------------------------------------
UID_N="$(id -u)"
render() {
  sed -e "s|__REPO_DIR__|$REPO_DIR|g" -e "s|__HOME__|$HOME|g" "$1" > "$2"
}

for name in com.inference.ollama com.inference.web com.inference.awake com.inference.sync; do
  render "$REPO_DIR/launchd/$name.plist.tmpl" "$AGENTS_DIR/$name.plist"
  launchctl bootout "gui/$UID_N/$name" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$UID_N" "$AGENTS_DIR/$name.plist"
  launchctl enable "gui/$UID_N/$name"
  log "loaded $name"
done

# ---- make `ollama` usable from interactive shells too ---------------------
if ! grep -qs '\.local/bin' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n# added by inference-server bootstrap\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.zshrc"
  log 'added ~/.local/bin to PATH in ~/.zshrc (so you can run ollama yourself)'
fi

# ---- first apply ----------------------------------------------------------
log "running first apply - model downloads can take a while..."
if "$REPO_DIR/scripts/apply.sh"; then
  git -C "$REPO_DIR" rev-parse HEAD > "$STATE_DIR/applied-commit"
  log "first apply succeeded"
else
  log "first apply FAILED - fix and re-run: $REPO_DIR/scripts/apply.sh"
fi

# ---- summary --------------------------------------------------------------
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<this-mac-ip>')"
PORT="$(grep -E '^OLLAMA_HOST=' "$REPO_DIR/config/server.env" | cut -d: -f2)"
[ -n "$PORT" ] || PORT=11434
WEB_PORT="$(grep -E '^INFERENCE_WEB_PORT=' "$REPO_DIR/config/server.env" | cut -d= -f2)"
[ -n "$WEB_PORT" ] || WEB_PORT=8080

cat <<EOF

[bootstrap] done. From another machine on your network try:

  http://$IP:$WEB_PORT  <- browser test page (model toggle + chat)

  curl http://$IP:$PORT/api/version
  curl http://$IP:$PORT/v1/chat/completions -H 'Content-Type: application/json' -d '{
    "model": "gpt-oss:120b",
    "messages": [{"role": "user", "content": "hello"}]
  }'

Logs:    $LOG_DIR/{ollama,web,sync}.log
Status:  $REPO_DIR/scripts/status.sh

Reminder for a headless box: enable automatic login (System Settings >
Users & Groups) so the services come back after a reboot; FileVault must be
off for auto-login to work. Sleep is prevented by the awake service while
you're logged in - no pmset/sudo required.
EOF

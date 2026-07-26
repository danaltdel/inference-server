#!/bin/bash
# One-time setup. Run this ON the Mac Studio, as the user that will stay
# logged in. Re-running it is safe (it re-renders and reloads the services).
#
# Option A - clone first:
#   git clone https://github.com/danaltdel/inference-server.git ~/inference-server
#   ~/inference-server/bootstrap.sh
#
# Option B - one-liner for a public repo:
#   curl -fsSL https://raw.githubusercontent.com/danaltdel/inference-server/main/bootstrap.sh \
#     | REPO_URL=https://github.com/danaltdel/inference-server.git bash -s -- --keep-awake
#
# Env / flags:
#   REPO_URL      git URL to clone (required for option B)
#   REPO_DIR      where the clone lives (default: ~/inference-server)
#   --keep-awake  also disable system sleep via pmset (asks for sudo)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_DIR="${REPO_DIR:-$HOME/inference-server}"
KEEP_AWAKE=false
for arg in "$@"; do
  case "$arg" in
    --keep-awake) KEEP_AWAKE=true ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[bootstrap] $*"; }

# If this script is already inside a clone of the repo, use that clone.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -d "$SCRIPT_DIR/.git" ]; then
    REPO_DIR="$SCRIPT_DIR"
  fi
fi

# Otherwise clone, then hand off to the repo's own copy of this script.
if [ ! -d "$REPO_DIR/.git" ]; then
  : "${REPO_URL:?Set REPO_URL=https://github.com/you/repo.git when piping this script}"
  log "cloning $REPO_URL -> $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
  exec "$REPO_DIR/bootstrap.sh" "$@"
fi

log "using repo at $REPO_DIR"

# ---- homebrew + ollama ----------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "installing Homebrew (you may be asked for your password)"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

if ! command -v ollama >/dev/null 2>&1; then
  log "installing ollama"
  brew install ollama
fi

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

for name in com.inference.ollama com.inference.web com.inference.sync; do
  render "$REPO_DIR/launchd/$name.plist.tmpl" "$AGENTS_DIR/$name.plist"
  launchctl bootout "gui/$UID_N/$name" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$UID_N" "$AGENTS_DIR/$name.plist"
  launchctl enable "gui/$UID_N/$name"
  log "loaded $name"
done

# ---- keep the machine awake (optional) ------------------------------------
if [ "$KEEP_AWAKE" = true ]; then
  log "disabling system sleep (sudo)"
  sudo pmset -a sleep 0 disksleep 0 displaysleep 10
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
off for auto-login to work.
EOF

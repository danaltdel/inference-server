# inference-server

GitOps for a home LLM box. This repo is the single source of truth for a
Mac Studio (or any Apple Silicon Mac) that serves local models over an
OpenAI-compatible API. Push a change here; the machine notices within a
minute, downloads whatever it needs, and reconfigures itself.

```
 your laptop                GitHub                        Mac Studio
 ───────────                ──────                        ──────────
 edit config  ──push──▶  public repo  ◀──fetch every 60s── com.inference.sync (launchd)
                                                              │ new commit?
                                                              ▼
                                                           apply.sh
                                                              │ restart server if config changed
                                                              │ pull models in models.txt
                                                              ▼
 any device on LAN ──────────────────────────────▶  ollama serve (launchd, always on)
      http://mac-studio.local:11434/v1  ── the API
      http://mac-studio.local:8080      ── browser test page (launchd)
```

Backend is [Ollama](https://ollama.com): native Metal support on Apple
Silicon, built-in model management, and an OpenAI-compatible API — the right
trade-off for a headless always-on box. (If you later want maximum tokens/sec
on the biggest models, MLX-based servers are the alternative; the sync
machinery here doesn't care what it manages.)

## Repo layout

| path | purpose |
|---|---|
| `config/server.env` | every `ollama serve` setting (port, context, keep-alive, ...) |
| `config/models.txt` | models the box must have, one per line |
| `scripts/sync.sh` | poller: fetch, reset to origin, apply |
| `scripts/apply.sh` | idempotent reconciler (restart server, pull/prune models) |
| `scripts/run-server.sh` | launchd entry point for the server |
| `scripts/status.sh` | health overview, handy over ssh |
| `web/index.html` | browser test page: model toggle + streaming chat |
| `scripts/serve.py` + `run-web.sh` | no-cache static server behind the test page |
| `launchd/*.plist.tmpl` | service definitions, rendered by bootstrap |
| `bootstrap.sh` | one-time machine setup |

## 1. The repo

This config lives at <https://github.com/danaltdel/inference-server>. The Mac
Studio tracks `main`, so changes land via PR (or a direct push to `main`) and
apply themselves within a minute.

## 2. Set up the Mac Studio (once)

Prerequisites: you're logged in as an admin user, and Xcode Command Line
Tools are installed (`xcode-select --install` — macOS also offers this
automatically the first time `git` runs).

```sh
curl -fsSL https://raw.githubusercontent.com/danaltdel/inference-server/main/bootstrap.sh \
  | REPO_URL=https://github.com/danaltdel/inference-server.git bash -s -- --keep-awake
```

This clones the repo to `~/inference-server`, installs Homebrew + Ollama if
missing, loads the two launchd services, disables system sleep
(`--keep-awake`), and does the first model download (~65 GB for the default
model — give it time).

For a box that survives reboots unattended: enable **automatic login**
(System Settings → Users & Groups) and leave **FileVault off** (it blocks
auto-login). launchd brings both services back on login.

## 3. Use it

The server speaks the OpenAI API on port 11434:

```sh
curl http://mac-studio.local:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "gpt-oss:120b", "messages": [{"role": "user", "content": "hello"}]}'
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://mac-studio.local:11434/v1", api_key="unused")
r = client.chat.completions.create(model="gpt-oss:120b",
                                   messages=[{"role": "user", "content": "hello"}])
print(r.choices[0].message.content)
```

The `ollama` CLI on any machine can also target it:
`OLLAMA_HOST=mac-studio.local:11434 ollama run gpt-oss:120b`.

(`mac-studio.local` is the machine's local hostname — set it under System
Settings → General → Sharing, or use its IP.)

## Test page

Open <http://mac-studio.local:8080> from any device on the LAN: a
zero-dependency chat page served by the box itself. Pick any installed model
from the dropdown (resident ones are marked "loaded"), send messages, and
watch the reply stream in with a tokens/sec readout when it finishes.
Switching models mid-conversation keeps the history — useful for asking two
models the same follow-up back to back. Enter sends, Shift+Enter is a
newline, the Send button doubles as Stop while streaming.

The page calls the Ollama API directly from your browser;
`OLLAMA_ORIGINS=*` in `config/server.env` is what permits that cross-port
request. It's plain HTML/JS served with caching disabled — edit
`web/index.html`, push, and a plain refresh shows the new version.

## Day-2 operations

Everything is a git push:

- **Change/add a model** — edit `config/models.txt`, push. New models are
  pulled on the next sync; the server keeps running meanwhile.
- **Tune the server** — edit `config/server.env`, push. The server restarts
  automatically (drops in-flight requests) only when this file changes.
- **Remove old models from disk** — set `INFERENCE_PRUNE_MODELS=true` in
  `server.env`, and anything not listed in `models.txt` is deleted on apply.
- **Check on it** — `ssh mac-studio '~/inference-server/scripts/status.sh'`
- **Logs** — `~/Library/Logs/inference-server/{ollama,sync}.log` on the box.
- **Force a re-apply without a commit** —
  `ssh mac-studio 'rm ~/.local/state/inference-server/applied-commit'`
  (next sync tick re-runs apply), or run `scripts/apply.sh` directly.
- **Changed `launchd/` templates?** Those can't safely reload themselves —
  re-run `bootstrap.sh` on the box (it's idempotent).

A failed apply (typo'd model name, network hiccup) is retried every 60s and
logged to `sync.log`; the last good server keeps serving throughout.

## Which models fit in 256 GB?

Approximate resident memory at the default 4-bit quantization (as of
July 2026):

| model | memory | notes |
|---|---|---|
| `qwen3.6:27b` | ~20 GB | Apr 2026; beats the previous 397B Qwen3.5 flagship on SWE-bench Verified, has vision — best quality-per-GB |
| `gpt-oss:120b` | ~70 GB | default here — MoE, fast, strong generalist |
| `qwen3:235b` | ~150 GB | about the biggest sensible fit; top of the Qwen3 generation |
| `llama3.3:70b` | ~45 GB | solid dense generalist |
| `deepseek-r1:70b` | ~45 GB | reasoning |

With `OLLAMA_MAX_LOADED_MODELS=2` the two default models (`gpt-oss:120b` +
`qwen3.6:27b`, ~90 GB together) stay resident simultaneously and switch
per-request with zero load time. Leave headroom above the model size for the
KV cache — roughly 10–30 GB at long contexts even with the quantized cache
enabled.

The July 2026 open-weights frontier (Kimi K3 at 2.8T params, DeepSeek V4)
is out of reach for any single machine; the one exception that *barely*
fits is below.

## Frontier experiment: GLM-5.2 in 2-bit

GLM-5.2 (Z.ai, 744B-A40B MoE) is the current #1 open-weights model. Ollama
only offers it as a `:cloud` tag, but Unsloth's 2-bit dynamic quant
(`UD-IQ2_M`, ~239 GB) fits a 256 GB Mac — barely. Treat it as an offline
experiment, not a serving config: single-digit tokens/sec, visible 2-bit
quality loss, and almost no memory left for context.

```sh
# free the memory ollama's resident models hold (they reload on demand)
launchctl kickstart -k "gui/$(id -u)/com.inference.ollama"

# let the GPU wire ~245 of 256 GB (default cap is ~75%; resets on reboot)
sudo sysctl iogpu.wired_limit_mb=245000

brew install llama.cpp
llama-server -hf unsloth/GLM-5.2-GGUF:UD-IQ2_M --port 8081
```

See the [Unsloth GLM-5.2 guide](https://unsloth.ai/docs/models/glm-5.2)
for current file names and recommended flags. Run it on a separate port and
leave the launchd services alone; the sync machinery neither manages nor
interferes with it.

## Security

- The API has **no authentication**. It binds to `0.0.0.0` so your LAN can
  reach it — do **not** port-forward it to the internet.
- For access away from home, install [Tailscale](https://tailscale.com) on
  the Mac Studio and your devices; the API is then reachable over the
  tailnet with zero exposed ports.
- The repo is public by design (the curl bootstrap needs it) and contains no
  secrets — keep it that way. If you'd rather make it private, clone with an
  SSH deploy key and use bootstrap option A instead of the curl one-liner.
- Sync uses `git reset --hard origin/main`: whoever can push to this repo
  controls the machine. Keep force-push protection on and don't add
  collaborators you wouldn't hand a shell.
- `OLLAMA_ORIGINS=*` means any webpage open in a browser on your LAN may
  attempt requests against the API (modern browsers increasingly block
  public→private-network requests, but don't rely on that alone). On a
  trusted home network it's a fair trade for the test page working via
  hostname or IP alike; tighten it to explicit origins such as
  `OLLAMA_ORIGINS=http://mac-studio.local:8080` if you'd rather.

## Troubleshooting

| symptom | check |
|---|---|
| services gone after reboot | auto-login enabled? FileVault off? `launchctl list \| grep com.inference` |
| server not answering | `tail -50 ~/Library/Logs/inference-server/ollama.log` |
| changes not applying | `tail -20 ~/Library/Logs/inference-server/sync.log` — fetch failures and apply errors land here |
| port already in use | a manually-started `ollama serve` (or Ollama.app) is running; quit it — launchd owns the server |
| model pull is slow | it's a 65–150 GB download; `sync.log` shows progress lines |

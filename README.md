# claude-proxy

A self-contained installer for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) + [Factory Droid CLI](https://docs.factory.ai/cli) that routes AI model requests through your existing OAuth subscriptions (Claude Max, OpenAI Max / Codex, Antigravity) on `localhost:8317`.

The upstream CLIProxyAPI source is vendored at `vendor/cliproxyapi/` via `git subtree`, so this repo is **standalone** — you can build, modify, and ship without depending on a live upstream.

## Why this fork: subscription billing for agent traffic

The reason this repo is a **patched** fork (not just an installer) is the Claude Max
"extra usage" problem. Anthropic's OAuth billing classifier only bills a request to
your **subscription** pool if the request looks like genuine Claude Code. Agent
frameworks (Hermes, custom clients, MCP-heavy tools) send a request *shape* that
gets classified as third-party and billed as **pay-per-token "extra usage"** instead —
so with extra-usage disabled you get an immediate:

```
HTTP 400: You're out of extra usage. Add more at claude.ai/settings/usage and keep going.
```

…even while your subscription quota is nearly empty. This was confirmed by bisecting a
real 328k-token agent request: the same request billed to the subscription once its
request shape was corrected.

**Two independent triggers, both fixed on the vendored source** (`internal/runtime/executor/claude_executor.go`):

1. **Tool names.** Arbitrary tool names (`read_file`, `bash`, …) → extra-usage. Genuine
   Claude Code sends MCP tools shaped `mcp__<server>__<tool>`, so the proxy prefixes
   third-party tool names to `mcp__agent__<name>` (with lossless response-side
   restoration, and leaving already-MCP-shaped and official Claude Code names untouched).
2. **System prompt.** A large custom `system[]` block → extra-usage. The client's system
   prompt is forwarded into the **first user message** instead, so `system[]` keeps only
   the Claude Code identity blocks.

Plus fingerprint hardening: a **stabilized device profile** (consistent macOS/arm64
`X-Stainless-*` headers matching the `claude-cli` User-Agent, instead of leaking the
Linux host), and an unconditional `x-client-request-id`. Net result: tool-bearing agent
traffic returns `200` with `service_tier: standard` (subscription), not the extra-usage 400.

> **You need the patched build for this.** The stock upstream `router-for-me/CLIProxyAPI`
> release does **not** carry these fixes. `setup-linux.sh` downloads this repo's patched
> release binary first, and building from `vendor/cliproxyapi/` (Go ≥ 1.26) always includes
> them. The generated `config.yaml` already contains the `claude-header-defaults`
> stabilization block — no extra config needed.

**Verify it's working** (a *tool-bearing* request — tool-less requests bill to the
subscription even unpatched, so they don't prove anything):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8317/v1/messages \
  -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"claude-fable-5","max_tokens":16,
       "tools":[{"name":"read_file","input_schema":{"type":"object"}}],
       "messages":[{"role":"user","content":"hi"}]}'
# 200  -> billing to the Max subscription (patched, working)
# 400  -> "out of extra usage" = unpatched binary, or subscription genuinely exhausted
```

> ⚠️ **Caveat.** This makes non-Claude-Code traffic *look like* Claude Code to obtain
> subscription pricing. Anthropic actively polices this (it tightened, then partially
> rolled back, mid-2026) and can change the classification at any time — treat it as
> maintenance, not set-and-forget. It is against the spirit of Anthropic's ToS; use it
> with your own subscription and your own judgment. The fully-legitimate alternative is
> to route inference through the real `claude` CLI (`claude -p`), which *is* Claude Code.

## Repo layout

```
.
├── setup.sh                 # macOS interactive installer
├── setup-linux.sh           # Headless Linux installer (VPS, Railway, CI)
├── scripts/
│   └── sync-upstream.sh     # Pull latest CLIProxyAPI main into vendor/
└── vendor/
    └── cliproxyapi/         # Vendored upstream source (git subtree)
```

## Install (macOS)

```bash
git clone https://github.com/andydoucet/claude-proxy.git
cd claude-proxy
bash setup.sh
```

The installer will:
1. Build `cli-proxy-api` from `vendor/cliproxyapi/` if Go is installed (`brew install go`), otherwise fall back to downloading the upstream release binary.
2. Generate `~/.cli-proxy-api/config.yaml` with max-reasoning overrides.
3. Install Factory Droid CLI via `brew install --cask droid` (if not present).
4. **Merge** (not overwrite) `~/.factory/settings.json` via `jq` when possible — your existing hooks, allowlist, denylist, and autonomy settings are preserved.
5. Run OAuth logins for your selected providers (browser flow).
6. Add a `droidc()` helper function to `~/.zshrc`.
7. Start the proxy and validate by querying `/v1/models`.

## Install (Linux, headless)

```bash
git clone https://github.com/andydoucet/claude-proxy.git
cd claude-proxy
bash setup-linux.sh                                       # interactive
bash setup-linux.sh --non-interactive --providers claude  # one-liner
```

### Non-interactive flags

```
--non-interactive    Run without prompts (use defaults or --providers)
--providers LIST     Comma-separated: claude,codex,antigravity
--port PORT          Proxy port (default: 8317)
--skip-auth          Skip OAuth (configure tokens later)
--skip-droid         Skip Factory Droid CLI installation
```

Linux also installs a `systemctl --user` service for auto-start.

## Build from source (recommended — this is what "standalone" means)

If Go ≥ 1.26 is installed, the installer auto-prefers building from `vendor/cliproxyapi/`. To tweak the proxy itself: edit Go source under `vendor/cliproxyapi/` then re-run `bash setup.sh` (or just `(cd vendor/cliproxyapi && go build -o ~/.local/bin/cli-proxy-api-plus ./cmd/server)`).

**Install Go:**
- macOS: `brew install go`
- Linux (Debian/Ubuntu): `apt-get install golang`
- Any: https://go.dev/dl

If Go is missing, the installer falls back to downloading the matching release binary from `router-for-me/CLIProxyAPI` GitHub releases. You lose the tweak-ability but the install still works.

## Syncing the vendored source

```bash
bash scripts/sync-upstream.sh           # pull upstream main
bash scripts/sync-upstream.sh v6.9.31   # pin to a tag/branch/SHA
```

This runs `git subtree pull --prefix=vendor/cliproxyapi --squash` and commits the merge onto your current branch. The working tree must be clean before you run it. See the script for details.

## Claude Max models

The installers register current Claude Max models as first-class proxy-routed models, including:

- `claude-opus-4-8` — Opus 4.8
- `claude-fable-5` — Fable 5
- `claude-sonnet-4-6` — Sonnet 4.6
- `claude-haiku-4-5` — Haiku 4.5

The generated CLIProxy config also keeps convenience aliases for stable client usage:

```yaml
oauth-model-alias:
  claude:
    - name: claude-opus-4-8
      alias: claude-opus-4.8
      fork: true
      force-mapping: true
    - name: claude-sonnet-4-6
      alias: claude-sonnet-latest
      fork: true
      force-mapping: true
```

Fable 5 is intentionally **not** aliased to another model. It routes only as `claude-fable-5`, so clients can tell when they are actually using Fable instead of a fallback wearing a fake mustache.

Quick live check:

```bash
curl -s http://localhost:8317/v1/models | jq -r '.data[].id' | grep claude-fable-5
curl -s http://localhost:8317/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-fable-5","messages":[{"role":"user","content":"Reply exactly: FABLE5_OK"}],"max_tokens":32}'
```

## Post-install authentication

Re-auth any provider at any time:

```bash
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -claude-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -codex-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -antigravity-login
```

Tokens auto-refresh every 15 min while the proxy is running.

## Systemd service (Linux)

```bash
systemctl --user start cli-proxy-api
systemctl --user stop cli-proxy-api
systemctl --user status cli-proxy-api
journalctl --user -u cli-proxy-api -f   # live logs
```

## Using with Claude Code / OpenClaw / other Anthropic SDK consumers

```bash
export ANTHROPIC_BASE_URL=http://localhost:8317
# ANTHROPIC_API_KEY can be any non-empty string; OAuth at the proxy does the real auth
export ANTHROPIC_API_KEY=sk-dummy
```

For Railway deployments, set `ANTHROPIC_BASE_URL=http://localhost:8317` as an environment variable.

**Hermes Agent / per-channel model overrides.** If your consumer routes per model rather
than a global base URL (e.g. Hermes `channel_model_overrides.json`), point that model at
the proxy with full Anthropic routing:

```json
{
  "model": "claude-fable-5",
  "provider": "anthropic",
  "base_url": "http://127.0.0.1:8317",
  "api_mode": "anthropic_messages",
  "api_key": "sk-dummy"
}
```

The proxy exposes both the Anthropic (`/v1/messages`) and OpenAI (`/v1/chat/completions`)
surfaces, so either `api_mode` works. Keep the proxy running as a long-lived localhost
service (systemd on a VPS, or a boot-launched process + watchdog on Railway).

## What gets changed on your machine

| Path | What | How |
|---|---|---|
| `~/.local/bin/cli-proxy-api-plus` | Binary (built or downloaded) | Installed |
| `~/.cli-proxy-api/config.yaml` | Proxy config | Generated |
| `~/.cli-proxy-api/<provider>-*.json` | OAuth tokens | Written on login |
| `~/.factory/settings.json` | Factory customModels + default model | **Merged** via jq when possible (non-destructive) |
| `~/.zshrc` | `droidc()` helper + PATH | Appended once (idempotent) |
| `~/.factory/settings.json.bak.<ts>` | Pre-merge backup | Kept before any change |

## Rollback

```bash
# stop proxy
pkill -f cli-proxy-api-plus

# restore settings.json from the most recent backup
cp ~/.factory/settings.json.bak.$(ls -t ~/.factory/settings.json.bak.* | head -1 | sed 's/.*\.bak\.//') ~/.factory/settings.json

# remove binary + config (asks for your confirmation on rm)
rm ~/.local/bin/cli-proxy-api-plus
rm -rf ~/.cli-proxy-api/
```

Remove the `droidc()` block from `~/.zshrc` by hand — it's between `# >>> claude-proxy >>>` and `# <<< claude-proxy <<<` sentinels.

## License

Upstream CLIProxyAPI is MIT-licensed (see `vendor/cliproxyapi/LICENSE`). The installer scripts in this repo are provided as-is.

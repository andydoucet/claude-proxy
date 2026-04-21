# claude-proxy

A self-contained installer for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) + [Factory Droid CLI](https://docs.factory.ai/cli) that routes AI model requests through your existing OAuth subscriptions (Claude Max, GitHub Copilot, OpenAI Max, Antigravity) on `localhost:8317`.

The upstream CLIProxyAPI source is vendored at `vendor/cliproxyapi/` via `git subtree`, so this repo is **standalone** — you can build, modify, and ship without depending on a live upstream.

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
--providers LIST     Comma-separated: claude,github-copilot,codex,antigravity
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

## Post-install authentication

Re-auth any provider at any time:

```bash
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -claude-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -github-copilot-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -codex-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -antigravity-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -kimi-login
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

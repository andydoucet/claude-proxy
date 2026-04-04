# CLIProxyAPIPlus Installer Scripts

Installer scripts for [CLIProxyAPIPlus](https://github.com/router-for-me/CLIProxyAPIPlus) — a local proxy that routes AI model requests through your existing subscriptions (Claude Max, GitHub Copilot, OpenAI Max, Antigravity) with max reasoning enabled on all models.

## Scripts

| Script | Platform | Notes |
|--------|----------|-------|
| `setup.sh` | macOS | Interactive installer with Homebrew, browser OAuth |
| `setup-linux.sh` | Linux (headless) | Designed for VPS, Railway, CI — no GUI needed |

## Quick Install (Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/andydoucet/claude-proxy/main/setup-linux.sh | bash
```

### Non-Interactive (for servers)

```bash
curl -fsSL https://raw.githubusercontent.com/andydoucet/claude-proxy/main/setup-linux.sh -o /tmp/setup-linux.sh
bash /tmp/setup-linux.sh --non-interactive --providers claude --skip-auth --skip-droid
```

### Options

```
--non-interactive    Run without prompts (use defaults or --providers)
--providers LIST     Comma-separated: claude,github-copilot,codex,antigravity
--port PORT          Proxy port (default: 8317)
--skip-auth          Skip OAuth authentication (configure tokens later)
--skip-droid         Skip Factory Droid CLI installation
```

## What It Does

1. Downloads the CLIProxyAPIPlus binary for your architecture
2. Generates proxy config (`~/.cli-proxy-api/config.yaml`) with max reasoning overrides
3. Optionally installs Factory Droid CLI and generates its settings
4. Sets up OAuth authentication (device-code flow for headless servers)
5. Installs a systemd user service for auto-start (Linux)
6. Adds shell helper function and PATH configuration

## Post-Install Authentication

```bash
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -claude-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -github-copilot-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -codex-login
cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml -antigravity-login
```

## Systemd Service (Linux)

```bash
systemctl --user start cli-proxy-api    # start
systemctl --user stop cli-proxy-api     # stop
systemctl --user status cli-proxy-api   # check
journalctl --user -u cli-proxy-api -f   # logs
```

## Using with OpenClaw / Claude Code

Set the base URL environment variable to route through the proxy:

```bash
export ANTHROPIC_BASE_URL=http://localhost:8317
```

For Railway deployments, add `ANTHROPIC_BASE_URL=http://localhost:8317` as an environment variable.

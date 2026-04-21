#!/bin/bash
# =============================================================================
# claude-proxy — lifecycle CLI for the local CLIProxyAPI daemon
# =============================================================================
# Install / start / stop / restart / status / logs / update / uninstall / auth.
# Platform-aware: macOS (launchd) + Linux user-systemd.
#
# Typical install:
#   ln -s "$(pwd)/scripts/claude-proxy.sh" ~/.local/bin/claude-proxy
#   claude-proxy install
#
# =============================================================================

set -uo pipefail

# ── Constants (match setup.sh / setup-linux.sh) ──────────────────────────────
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_SOURCE" ]; do
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    case "$SCRIPT_SOURCE" in /*) ;; *) SCRIPT_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$SCRIPT_SOURCE" ;; esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROXY_PORT=8317
CONFIG_DIR="$HOME/.cli-proxy-api"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOG_FILE="$CONFIG_DIR/proxy.log"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="cli-proxy-api-plus"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
UPSTREAM_BINARY="cli-proxy-api"
FACTORY_SETTINGS="$HOME/.factory/settings.json"
VENDOR_DIR="$REPO_ROOT/vendor/cliproxyapi"

# launchd (macOS)
LAUNCHD_LABEL="sh.claude-proxy.daemon"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
# systemd user (Linux)
SYSTEMD_UNIT="cli-proxy-api.service"

OS_KIND="$(uname -s)"   # Darwin | Linux

# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
    RED=; GREEN=; YELLOW=; BLUE=; BOLD=; DIM=; RESET=
fi
info()    { printf "${BLUE}→${RESET} %s\n" "$*"; }
ok()      { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}!${RESET} %s\n" "$*"; }
err()     { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
die()     { err "$*"; exit 1; }

# ── Helpers ──────────────────────────────────────────────────────────────────
pid_on_port() {
    lsof -ti "tcp:${PROXY_PORT}" -sTCP:LISTEN 2>/dev/null | head -1
}

process_name() {
    local pid="$1"
    ps -p "$pid" -o comm= 2>/dev/null | xargs -I{} basename {} 2>/dev/null
}

is_our_proxy_pid() {
    local pid="$1" name
    name="$(process_name "$pid")"
    case "$name" in
        "$BINARY_NAME"|"$UPSTREAM_BINARY"|cli-proxy-api*) return 0 ;;
        *) return 1 ;;
    esac
}

launchd_loaded() {
    # Avoid `launchctl list | grep -q` — grep -q closes stdout on match, launchctl
    # then SIGPIPEs (141), and pipefail propagates that as failure. Capture first.
    [ "$OS_KIND" = "Darwin" ] || return 1
    local out
    out="$(launchctl list 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -q "$LAUNCHD_LABEL"
}

systemd_active() {
    [ "$OS_KIND" = "Linux" ] && systemctl --user is-active --quiet "$SYSTEMD_UNIT" 2>/dev/null
}

supervisor_kind() {
    # Returns: launchd | systemd | nohup | none
    if [ "$OS_KIND" = "Darwin" ] && [ -f "$LAUNCHD_PLIST" ]; then
        echo launchd; return
    fi
    if [ "$OS_KIND" = "Linux" ] && systemctl --user cat "$SYSTEMD_UNIT" >/dev/null 2>&1; then
        echo systemd; return
    fi
    if pid_on_port >/dev/null && [ -n "$(pid_on_port)" ] && is_our_proxy_pid "$(pid_on_port)"; then
        echo nohup; return
    fi
    echo none
}

proxy_version() {
    [ -x "$BINARY_PATH" ] || { echo "not-installed"; return; }
    # Capture to var so pipefail + early-SIGPIPE from `head` doesn't double-output.
    local out first v
    out="$("$BINARY_PATH" --help 2>&1)" || true
    first="$(printf '%s\n' "$out" | head -1)" || true
    v="$(printf '%s' "$first" | grep -o 'Version: [^ ,]*' | cut -d' ' -f2 2>/dev/null)" || true
    echo "${v:-unknown}"
}

models_count() {
    curl -fsS --max-time 3 "http://localhost:$PROXY_PORT/v1/models" 2>/dev/null \
        | jq -r '.data | length' 2>/dev/null || echo "?"
}

require_binary() {
    [ -x "$BINARY_PATH" ] || die "Binary not installed at $BINARY_PATH. Run: claude-proxy install"
}

# ── Subcommands ──────────────────────────────────────────────────────────────

cmd_help() {
    cat <<EOF
${BOLD}claude-proxy${RESET} — lifecycle CLI for the local CLIProxyAPI daemon

${BOLD}USAGE${RESET}
  claude-proxy <command> [args]

${BOLD}COMMANDS${RESET}
  install [args]       Run the interactive installer (setup.sh / setup-linux.sh)
  start                Start the proxy (uses launchd/systemd if installed)
  stop                 Stop the proxy
  restart              Stop + start
  status               Show supervisor, PID, port state, proxy version, model count
  logs [-f]            Tail the proxy log (\`-f\` to follow)
  update               git subtree pull upstream source, rebuild, restart
  uninstall [flags]    Reverse the install. Flags: --keep-tokens --keep-config
  auth <provider>      Run OAuth for: claude|github-copilot|codex|antigravity|kimi
  models               List models served by \`/v1/models\`
  version              Print binary version
  help                 This message

${BOLD}LOCATIONS${RESET}
  Binary:       $BINARY_PATH
  Config:       $CONFIG_FILE
  Log:          $LOG_FILE
  launchd:      $LAUNCHD_PLIST
  Vendor src:   $VENDOR_DIR

${BOLD}EXAMPLES${RESET}
  claude-proxy install
  claude-proxy status
  claude-proxy auth claude
  claude-proxy update
  claude-proxy logs -f
EOF
}

cmd_install() {
    local installer
    if [ "$OS_KIND" = "Darwin" ]; then
        installer="$REPO_ROOT/setup.sh"
    else
        installer="$REPO_ROOT/setup-linux.sh"
    fi
    [ -f "$installer" ] || die "Installer not found: $installer"
    info "Running $installer $*"
    exec bash "$installer" "$@"
}

cmd_start() {
    require_binary
    local sup
    sup="$(supervisor_kind)"
    case "$sup" in
        launchd)
            if launchd_loaded; then
                ok "launchd already supervising (label=$LAUNCHD_LABEL)"
                return
            fi
            info "Loading launchd plist..."
            launchctl load "$LAUNCHD_PLIST" || die "launchctl load failed"
            sleep 2
            launchd_loaded && ok "launchd loaded" || die "launchd did not come up"
            ;;
        systemd)
            if systemd_active; then
                ok "systemd --user already active ($SYSTEMD_UNIT)"
                return
            fi
            info "Starting systemd --user $SYSTEMD_UNIT"
            systemctl --user start "$SYSTEMD_UNIT" || die "systemctl start failed"
            ok "systemd started"
            ;;
        nohup|none)
            # Bare start — no supervisor installed.
            if [ -n "$(pid_on_port)" ]; then
                local p; p="$(pid_on_port)"
                if is_our_proxy_pid "$p"; then
                    ok "Already running (PID $p)"
                    return
                else
                    die "Port $PROXY_PORT held by '$(process_name "$p")' (PID $p). Not ours — not killing."
                fi
            fi
            info "Starting via nohup (no supervisor installed)"
            nohup "$BINARY_PATH" -config "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
            local pid=$!
            disown
            echo "$pid" > /tmp/claude-proxy.pid
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                ok "Started (PID $pid). No auto-restart on crash."
                info "Install a supervisor: claude-proxy install (re-run to set up launchd/systemd)"
            else
                die "Proxy exited immediately — check log: $LOG_FILE"
            fi
            ;;
    esac
}

cmd_stop() {
    local sup
    sup="$(supervisor_kind)"
    case "$sup" in
        launchd)
            if launchd_loaded; then
                info "Unloading launchd plist (stops proxy + disables at-boot)"
                launchctl unload "$LAUNCHD_PLIST" && ok "Stopped" || die "launchctl unload failed"
            else
                ok "launchd plist present but not loaded; nothing to stop"
            fi
            ;;
        systemd)
            if systemd_active; then
                info "Stopping systemd --user $SYSTEMD_UNIT"
                systemctl --user stop "$SYSTEMD_UNIT" && ok "Stopped"
            else
                ok "systemd unit present but not active; nothing to stop"
            fi
            ;;
        nohup)
            local p; p="$(pid_on_port)"
            if [ -n "$p" ] && is_our_proxy_pid "$p"; then
                info "Killing nohup proxy (PID $p)"
                kill "$p" 2>/dev/null
                sleep 1
                kill -0 "$p" 2>/dev/null && { warn "Still alive; sending KILL"; kill -9 "$p" 2>/dev/null; }
                rm -f /tmp/claude-proxy.pid
                ok "Stopped"
            else
                ok "Nothing running on :$PROXY_PORT"
            fi
            ;;
        none)
            ok "No supervisor or running proxy detected"
            ;;
    esac
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    local sup pid cmd ver mc
    sup="$(supervisor_kind)"
    pid="$(pid_on_port)"
    cmd="${pid:+$(process_name "$pid")}"
    ver="$(proxy_version)"
    mc="$(models_count)"

    printf "${BOLD}claude-proxy status${RESET}\n"
    printf "  OS:             %s\n" "$OS_KIND"
    printf "  Binary:         %s %s\n" "$BINARY_PATH" "${ver:+($ver)}"
    printf "  Config:         %s%s\n" "$CONFIG_FILE" "$([ -f "$CONFIG_FILE" ] && echo "" || echo " ${RED}(missing)${RESET}")"
    printf "  Supervisor:     %s\n" "$sup"
    if [ "$sup" = launchd ]; then
        if launchd_loaded; then
            local st pid2
            st="$(launchctl list 2>/dev/null | awk -v l="$LAUNCHD_LABEL" '$0 ~ l {print "pid="$1" exit="$2}')"
            printf "  launchd:        loaded (%s)\n" "$st"
        else
            printf "  launchd:        plist present, not loaded\n"
        fi
    fi
    if [ "$sup" = systemd ]; then
        if systemd_active; then
            printf "  systemd:        active\n"
        else
            printf "  systemd:        inactive\n"
        fi
    fi
    if [ -n "$pid" ]; then
        printf "  Port $PROXY_PORT:       ${GREEN}LISTEN${RESET} (PID $pid, '%s')\n" "$cmd"
    else
        printf "  Port $PROXY_PORT:       ${RED}free${RESET} (proxy not running)\n"
    fi
    printf "  /v1/models:     %s models\n" "$mc"
    printf "  Factory config: %s%s\n" "$FACTORY_SETTINGS" "$(
        if [ -f "$FACTORY_SETTINGS" ] && command -v jq >/dev/null; then
            local n; n=$(jq -r '.customModels | length // 0' "$FACTORY_SETTINGS" 2>/dev/null)
            echo " ($n customModels)"
        fi
    )"
    if [ -f "$LAUNCHD_PLIST" ]; then
        printf "  Plist:          %s\n" "$LAUNCHD_PLIST"
    fi
    printf "  Vendor src:     %s%s\n" "$VENDOR_DIR" "$([ -d "$VENDOR_DIR" ] && echo "" || echo " ${YELLOW}(missing — run: git subtree add)${RESET}")"
}

cmd_logs() {
    [ -f "$LOG_FILE" ] || die "Log file does not exist: $LOG_FILE"
    case "${1:-}" in
        -f|--follow) exec tail -f "$LOG_FILE" ;;
        *)           exec tail -n 200 "$LOG_FILE" ;;
    esac
}

cmd_update() {
    [ -d "$REPO_ROOT/.git" ] || die "Not a git repo: $REPO_ROOT"
    [ -d "$VENDOR_DIR" ] || die "No vendor/cliproxyapi; initial setup required"
    info "Pulling latest upstream source into vendor/cliproxyapi..."
    bash "$REPO_ROOT/scripts/sync-upstream.sh" "${1:-main}" || die "Upstream sync failed"

    info "Rebuilding binary..."
    if command -v go >/dev/null; then
        mkdir -p "$INSTALL_DIR"
        ( cd "$VENDOR_DIR" && GOFLAGS="-mod=mod" go build -trimpath -ldflags "-s -w" \
            -o "$BINARY_PATH" ./cmd/server ) || die "go build failed"
        ok "Built: $BINARY_PATH ($(proxy_version))"
    else
        warn "Go not installed; falling back to release download."
        info "Install Go (brew install go) to build from the updated vendored source."
        # Re-use setup.sh's download function by sourcing it with main stripped.
        local setup
        if [ "$OS_KIND" = "Darwin" ]; then setup="$REPO_ROOT/setup.sh"; else setup="$REPO_ROOT/setup-linux.sh"; fi
        tmpsh="$(mktemp)"
        sed '/^main "$@"$/d' "$setup" > "$tmpsh"
        # shellcheck disable=SC1090
        source "$tmpsh"
        detect_arch
        download_release_binary || { rm -f "$tmpsh"; die "Release download failed"; }
        rm -f "$tmpsh"
    fi

    info "Restarting proxy..."
    cmd_restart
    ok "Update complete"
}

cmd_uninstall() {
    local keep_tokens=false keep_config=false
    for arg in "$@"; do
        case "$arg" in
            --keep-tokens) keep_tokens=true ;;
            --keep-config) keep_config=true ;;
            *) die "Unknown flag: $arg" ;;
        esac
    done

    echo "${BOLD}claude-proxy uninstall${RESET}"
    echo "This will:"
    echo "  - stop the proxy"
    [ "$OS_KIND" = Darwin ] && echo "  - remove LaunchAgent plist ($LAUNCHD_PLIST)"
    [ "$OS_KIND" = Linux  ] && echo "  - remove systemd --user unit"
    echo "  - remove binary ($BINARY_PATH)"
    $keep_config  || echo "  - remove config dir ($CONFIG_DIR) INCLUDING OAUTH TOKENS"
    $keep_tokens  && echo "  - preserve $CONFIG_DIR auth files (other config removed)"
    $keep_config  && echo "  - preserve entire $CONFIG_DIR"
    echo "  - leave ~/.factory/settings.json alone (re-merge it by hand if desired)"
    echo "  - leave ~/.zshrc droidc() block — remove by hand"
    printf "Proceed? [y/N]: "
    read -r answer
    case "$answer" in y|Y) ;; *) info "Aborted."; exit 0 ;; esac

    cmd_stop

    if [ "$OS_KIND" = Darwin ] && [ -f "$LAUNCHD_PLIST" ]; then
        info "Removing $LAUNCHD_PLIST"
        rm -f "$LAUNCHD_PLIST"
    fi
    if [ "$OS_KIND" = Linux ] && systemctl --user cat "$SYSTEMD_UNIT" >/dev/null 2>&1; then
        info "Disabling + removing systemd --user unit"
        systemctl --user disable --now "$SYSTEMD_UNIT" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/$SYSTEMD_UNIT"
        systemctl --user daemon-reload 2>/dev/null || true
    fi

    if [ -f "$BINARY_PATH" ]; then
        info "Removing $BINARY_PATH"
        rm -f "$BINARY_PATH"
    fi

    if ! $keep_config; then
        if $keep_tokens; then
            info "Removing $CONFIG_FILE (keeping auth tokens)"
            rm -f "$CONFIG_FILE"
            rm -f "$LOG_FILE"
        else
            info "Removing $CONFIG_DIR (tokens included)"
            rm -rf "$CONFIG_DIR"
        fi
    fi

    rm -f /tmp/claude-proxy.pid

    ok "Uninstalled. Factory settings.json and zshrc not touched (remove by hand if desired)."
}

cmd_auth() {
    require_binary
    local provider="${1:-}"
    case "$provider" in
        claude|github-copilot|codex|antigravity|kimi) ;;
        "") die "Usage: claude-proxy auth <claude|github-copilot|codex|antigravity|kimi>" ;;
        *) die "Unknown provider: $provider" ;;
    esac
    info "Starting $provider OAuth (browser will open; complete login)..."
    "$BINARY_PATH" -config "$CONFIG_FILE" "-${provider}-login"
}

cmd_models() {
    local resp
    resp="$(curl -fsS --max-time 5 "http://localhost:$PROXY_PORT/v1/models" 2>/dev/null)" \
        || die "Cannot reach proxy at :$PROXY_PORT — is it running? (claude-proxy status)"
    echo "$resp" | jq -r '.data[] | "\(.id)\t\(.owned_by // "?")"' 2>/dev/null | column -t -s $'\t'
}

cmd_version() {
    proxy_version
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"
    shift || true
    case "$cmd" in
        install|--install)      cmd_install "$@" ;;
        start|--start)          cmd_start ;;
        stop|--stop)            cmd_stop ;;
        restart|--restart)      cmd_restart ;;
        status|--status)        cmd_status ;;
        logs|--logs)            cmd_logs "$@" ;;
        update|--update)        cmd_update "$@" ;;
        uninstall|--uninstall)  cmd_uninstall "$@" ;;
        auth|--auth)            cmd_auth "$@" ;;
        models|--models)        cmd_models ;;
        version|--version|-v)   cmd_version ;;
        help|--help|-h)         cmd_help ;;
        *)                      err "Unknown command: $cmd"; echo ""; cmd_help; exit 1 ;;
    esac
}

main "$@"

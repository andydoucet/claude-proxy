#!/bin/bash
# =============================================================================
# CLIProxyAPIPlus + Factory Droid CLI — Headless Linux Installer
# =============================================================================
# Configures a proxy that routes AI model requests through your existing
# subscriptions (Claude Max, GitHub Copilot, OpenAI Max, Antigravity)
# to Factory Droid CLI with max reasoning enabled on all models.
#
# Designed for headless servers (Railway, VPS, CI) — no GUI or browser needed.
#
# Usage:
#   Interactive:     bash setup-linux.sh
#   Non-interactive: bash setup-linux.sh --non-interactive --providers claude,github-copilot
#   Skip auth:       bash setup-linux.sh --skip-auth
#   Custom port:     bash setup-linux.sh --port 9000
# =============================================================================

set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor/cliproxyapi"
VENDOR_MAIN="$VENDOR_DIR/cmd/server"

PROXY_PORT=8317
CONFIG_DIR="$HOME/.cli-proxy-api"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
FACTORY_DIR="$HOME/.factory"
SETTINGS_FILE="$FACTORY_DIR/settings.json"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="cli-proxy-api-plus"          # install target (kept for backward compat with droidc())
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
UPSTREAM_BINARY="cli-proxy-api"           # name of binary inside upstream release tarballs
GITHUB_REPO="router-for-me/CLIProxyAPI"   # fallback source when building-from-source unavailable
PROXY_PID=""

# ── CLI flags ────────────────────────────────────────────────────────────────
NON_INTERACTIVE=false
SKIP_AUTH=false
SKIP_DROID=false
CLI_PROVIDERS=""

# ── Colors (disabled if not a terminal) ─────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

info()    { printf "${BLUE}→${RESET} %s\n" "$1"; }
success() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}!${RESET} %s\n" "$1"; }
error()   { printf "${RED}✗${RESET} %s\n" "$1"; }
ask()     { printf "${YELLOW}?${RESET} %s" "$1"; }

# ── Parse CLI arguments ─────────────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=true ;;
            --skip-auth)       SKIP_AUTH=true ;;
            --skip-droid)      SKIP_DROID=true ;;
            --providers)       shift; CLI_PROVIDERS="$1" ;;
            --port)            shift; PROXY_PORT="$1" ;;
            -h|--help)         show_usage; exit 0 ;;
            *)                 warn "Unknown option: $1" ;;
        esac
        shift
    done
}

show_usage() {
    cat << 'EOF'
Usage: bash setup-linux.sh [OPTIONS]

Options:
  --non-interactive         Run without prompts (use defaults or --providers)
  --providers LIST          Comma-separated: claude,github-copilot,codex,antigravity
  --port PORT               Proxy port (default: 8317)
  --skip-auth               Skip OAuth authentication (configure tokens later)
  --skip-droid              Skip Factory Droid CLI installation
  -h, --help                Show this help

Examples:
  bash setup-linux.sh
  bash setup-linux.sh --non-interactive --providers claude --skip-auth
  bash setup-linux.sh --port 9000 --skip-droid
EOF
}

# ── Cleanup trap ─────────────────────────────────────────────────────────────
cleanup() {
    if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

# ── Utility functions ────────────────────────────────────────────────────────
command_exists() { command -v "$1" &>/dev/null; }

backup_if_exists() {
    local file="$1"
    if [ -f "$file" ]; then
        local bak="${file}.bak.$(date +%s)"
        cp "$file" "$bak"
        warn "Backed up existing $(basename "$file") → $(basename "$bak")"
    fi
}

# Port check — works on headless Linux without lsof
port_in_use() {
    local port="$1"
    if command_exists ss; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif [ -f /proc/net/tcp ]; then
        # /proc/net/tcp uses hex port numbers
        local hex_port
        hex_port=$(printf '%04X' "$port")
        grep -qi ":${hex_port} " /proc/net/tcp 2>/dev/null
    elif command_exists netstat; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} "
    elif command_exists lsof; then
        lsof -i :"$port" &>/dev/null
    else
        # Last resort: try to connect
        (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null
    fi
}

pid_on_port() {
    local port="$1"
    if command_exists ss; then
        ss -tlnp 2>/dev/null | grep ":${port} " | grep -oP 'pid=\K[0-9]+' | head -1
    elif command_exists lsof; then
        lsof -t -i :"$port" 2>/dev/null | head -1
    else
        echo ""
    fi
}

# ── Welcome banner ───────────────────────────────────────────────────────────
show_banner() {
    printf "\n${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║   CLIProxyAPIPlus + Factory Droid CLI Installer   ║"
    echo "  ║              (Headless Linux Edition)              ║"
    echo "  ║                                                   ║"
    echo "  ║   Route your AI subscriptions through a proxy     ║"
    echo "  ║   with max reasoning on all models.               ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    printf "${RESET}\n"
    printf "  ${DIM}Supports: Claude Max • GitHub Copilot • OpenAI Max • Antigravity${RESET}\n\n"
}

# ── Step 1: Prerequisites ───────────────────────────────────────────────────
check_linux() {
    local os
    os=$(uname -s)
    case "$os" in
        Linux)  success "Linux detected" ;;
        Darwin)
            warn "macOS detected — consider using setup.sh (macOS version) instead."
            ask "Continue with Linux installer anyway? [y/N]: "
            if $NON_INTERACTIVE; then
                error "Cannot run Linux installer on macOS in non-interactive mode."
                exit 1
            fi
            read -r answer
            if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
                exit 1
            fi
            ;;
        *)
            error "Unsupported OS: $os (expected Linux)"
            exit 1
            ;;
    esac
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   DOWNLOAD_ARCH="linux_amd64" ;;
        aarch64|arm64)   DOWNLOAD_ARCH="linux_arm64" ;;
        *)               error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    success "Architecture: $ARCH → $DOWNLOAD_ARCH"
}

check_dependencies() {
    local missing=()
    for cmd in curl tar; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        error "Missing required commands: ${missing[*]}"
        info "Install them with your package manager, e.g.:"
        info "  apt-get install -y ${missing[*]}"
        info "  yum install -y ${missing[*]}"
        exit 1
    fi
    success "Required tools present (curl, tar)"
}

install_droid_linux() {
    if $SKIP_DROID; then
        info "Skipping Factory Droid CLI installation (--skip-droid)"
        return
    fi

    if command_exists droid; then
        success "Factory Droid CLI already installed ($(droid --version 2>/dev/null || echo 'unknown'))"
        if ! $NON_INTERACTIVE; then
            ask "Re-install latest? [y/N]: "
            read -r answer
            if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
                return
            fi
        else
            return
        fi
    fi

    info "Installing Factory Droid CLI via install script..."

    # Try the official install script first
    if curl -fsSL https://app.factory.ai/install.sh -o /tmp/droid-install.sh 2>/dev/null; then
        bash /tmp/droid-install.sh
        rm -f /tmp/droid-install.sh
        if command_exists droid; then
            success "Factory Droid CLI installed"
            return
        fi
    fi

    # Fallback: try npm
    if command_exists npm; then
        info "Trying npm install..."
        npm install -g @anthropic-ai/droid 2>/dev/null && {
            success "Factory Droid CLI installed via npm"
            return
        }
    fi

    warn "Could not install Factory Droid CLI automatically."
    warn "Install it manually: https://docs.factory.ai/install"
}

build_from_vendor() {
    # Returns 0 on successful build, 1 if vendor/source/go unavailable or build failed.
    [ -d "$VENDOR_DIR" ] || return 1
    [ -f "$VENDOR_DIR/go.mod" ] || return 1
    command -v go >/dev/null 2>&1 || return 1

    info "Building cli-proxy-api from vendor/cliproxyapi (Go $(go version 2>/dev/null | awk '{print $3}'))..."
    mkdir -p "$INSTALL_DIR"
    ( cd "$VENDOR_DIR" && GOFLAGS="-mod=mod" go build -trimpath -ldflags "-s -w" \
        -o "$BINARY_PATH" ./cmd/server ) || return 1
    success "Built from vendored source → $BINARY_PATH"
    return 0
}

download_release_binary() {
    info "Fetching latest CLIProxyAPI release from $GITHUB_REPO..."
    local auth_header=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")

    local download_url
    download_url=$(curl -fsSL "${auth_header[@]}" "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | \
        grep "browser_download_url" | grep "$DOWNLOAD_ARCH" | head -1 | cut -d'"' -f4)

    if [ -z "$download_url" ]; then
        error "Could not find download URL for $DOWNLOAD_ARCH"
        error "Possible causes: GitHub rate-limit (set GITHUB_TOKEN), network error, or repo renamed."
        error "Repo: https://github.com/$GITHUB_REPO/releases/latest"
        return 1
    fi

    info "Downloading: $(basename "$download_url")"
    local tmpdir
    tmpdir=$(mktemp -d)
    curl -fsSL "${auth_header[@]}" "$download_url" -o "$tmpdir/proxy.tar.gz" || { rm -rf "$tmpdir"; return 1; }
    tar xzf "$tmpdir/proxy.tar.gz" -C "$tmpdir" || { rm -rf "$tmpdir"; return 1; }

    mkdir -p "$INSTALL_DIR"
    local found_binary
    found_binary=$(find "$tmpdir" -name "$UPSTREAM_BINARY" -type f 2>/dev/null | head -1)
    if [ -z "$found_binary" ]; then
        # last resort: first executable in tree
        found_binary=$(find "$tmpdir" -type f -executable 2>/dev/null | head -1)
    fi
    if [ -z "$found_binary" ]; then
        error "Could not find '$UPSTREAM_BINARY' in downloaded archive"
        ls -1 "$tmpdir" | sed 's/^/  /'
        rm -rf "$tmpdir"
        return 1
    fi

    cp "$found_binary" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf "$tmpdir"
    success "Downloaded release binary → $BINARY_PATH"
    return 0
}

install_proxy_binary() {
    if [ -f "$BINARY_PATH" ]; then
        local version
        version=$("$BINARY_PATH" --help 2>&1 | head -1 | grep -o 'Version: [^ ,]*' | cut -d' ' -f2 || echo "unknown")
        success "cli-proxy-api already installed ($version)"
        if ! $NON_INTERACTIVE; then
            ask "Re-install (from vendored source if Go present, else download)? [y/N]: "
            read -r answer
            if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
                return
            fi
        else
            return
        fi
    fi

    # Prefer vendored source build — keeps the repo standalone-tweakable.
    if build_from_vendor; then
        return
    fi

    if [ -d "$VENDOR_DIR" ] && ! command -v go >/dev/null 2>&1; then
        warn "vendor/cliproxyapi exists but Go toolchain is missing."
        warn "Install Go (e.g. apt-get install golang, or from https://go.dev/dl) and re-run to build from source."
        warn "Falling back to release download for now."
    fi
    download_release_binary || { error "Could not install cli-proxy-api."; exit 1; }

    local version
    version=$("$BINARY_PATH" --help 2>&1 | head -1 | grep -o 'Version: [^ ,]*' | cut -d' ' -f2 || echo "unknown")
    success "cli-proxy-api installed ($version)"
}

ensure_path() {
    if echo "$PATH" | tr ':' '\n' | grep -q "$INSTALL_DIR"; then
        return
    fi

    # Detect user's shell and update the right profile
    local shell_rc=""
    local user_shell
    user_shell=$(basename "${SHELL:-/bin/bash}")

    case "$user_shell" in
        zsh)  shell_rc="$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                shell_rc="$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                shell_rc="$HOME/.bash_profile"
            else
                shell_rc="$HOME/.bashrc"
            fi
            ;;
        *)    shell_rc="$HOME/.profile" ;;
    esac

    if [ -n "$shell_rc" ] && [ -f "$shell_rc" ] && grep -q "$INSTALL_DIR" "$shell_rc"; then
        return
    fi

    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$shell_rc"
    export PATH="$INSTALL_DIR:$PATH"
    success "Added $INSTALL_DIR to PATH in $shell_rc"
}

# ── Step 2: Provider & Model Selection ───────────────────────────────────────

get_models_for_provider() {
    case "$1" in
        claude)
            # First claude-opus-* wins as session default (see selector below).
            echo "claude-opus-4-7|Opus 4.7 [Claude Max]|128000|anthropic|http://localhost:$PROXY_PORT"
            echo "claude-opus-4-6|Opus 4.6 1M [Claude Max]|128000|anthropic|http://localhost:$PROXY_PORT"
            echo "claude-sonnet-4-6|Sonnet 4.6 [Claude Max]|64000|anthropic|http://localhost:$PROXY_PORT"
            echo "claude-haiku-4-5|Haiku 4.5 [Claude Max]|32000|anthropic|http://localhost:$PROXY_PORT"
            ;;
        github-copilot)
            echo "gpt-5.4|GPT-5.4 High [Copilot]|32768|openai|http://localhost:$PROXY_PORT/v1"
            echo "gpt-5.4-mini|GPT-5.4 Mini Fast [Copilot]|16384|openai|http://localhost:$PROXY_PORT/v1"
            echo "gpt-5.3-codex|GPT-5.3-Codex High [Copilot]|64000|openai|http://localhost:$PROXY_PORT/v1"
            echo "gemini-3.1-pro-preview|Gemini 3.1 Pro High [Copilot]|65536|generic-chat-completion-api|http://localhost:$PROXY_PORT/v1"
            ;;
        codex)
            echo "gpt-5-codex|GPT-5-Codex High [OpenAI Max]|64000|openai|http://localhost:$PROXY_PORT/v1"
            echo "gpt-5|GPT-5 High [OpenAI Max]|32768|openai|http://localhost:$PROXY_PORT/v1"
            ;;
        antigravity)
            echo "gemini-3-pro-high|Gemini 3 Pro [Antigravity]|65536|generic-chat-completion-api|http://localhost:$PROXY_PORT/v1"
            echo "gemini-3-flash|Gemini 3 Flash [Antigravity]|65536|generic-chat-completion-api|http://localhost:$PROXY_PORT/v1"
            ;;
    esac
}

get_provider_name() {
    case "$1" in
        claude)          echo "Claude Max" ;;
        github-copilot)  echo "GitHub Copilot" ;;
        codex)           echo "OpenAI Max / Codex" ;;
        antigravity)     echo "Antigravity" ;;
    esac
}

get_provider_desc() {
    case "$1" in
        claude)          echo "Opus 4.6, Sonnet 4.6, Haiku 4.5" ;;
        github-copilot)  echo "GPT-5.4, GPT-5.4 Mini, GPT-5.3-Codex, Gemini 3.1 Pro" ;;
        codex)           echo "GPT-5-Codex, GPT-5" ;;
        antigravity)     echo "Gemini 3 Pro, Gemini 3 Flash" ;;
    esac
}

get_auth_flag() {
    case "$1" in
        claude)          echo "-claude-login" ;;
        github-copilot)  echo "-github-copilot-login" ;;
        codex)           echo "-codex-login" ;;
        antigravity)     echo "-antigravity-login" ;;
    esac
}

# Global arrays
SELECTED_PROVIDERS=()
SELECTED_MODELS=()

select_providers() {
    local providers=("claude" "github-copilot" "codex" "antigravity")

    # Non-interactive: use CLI_PROVIDERS or all
    if $NON_INTERACTIVE; then
        if [ -n "$CLI_PROVIDERS" ]; then
            IFS=',' read -ra SELECTED_PROVIDERS <<< "$CLI_PROVIDERS"
            # Validate
            for p in "${SELECTED_PROVIDERS[@]}"; do
                local valid=false
                for vp in "${providers[@]}"; do
                    if [ "$p" = "$vp" ]; then valid=true; break; fi
                done
                if ! $valid; then
                    error "Invalid provider: $p"
                    error "Valid: claude, github-copilot, codex, antigravity"
                    exit 1
                fi
            done
        else
            SELECTED_PROVIDERS=("${providers[@]}")
        fi
        success "Selected providers: $(printf '%s, ' "${SELECTED_PROVIDERS[@]}" | sed 's/, $//')"
        return
    fi

    echo ""
    printf "${BOLD}Which providers do you want to configure?${RESET}\n"
    echo ""
    local i=1
    for p in "${providers[@]}"; do
        printf "  ${BOLD}%d)${RESET} %-22s ${DIM}— %s${RESET}\n" "$i" "$(get_provider_name "$p")" "$(get_provider_desc "$p")"
        i=$((i + 1))
    done
    echo ""
    ask "Enter choices (e.g., 1 2 3 4 or all) [all]: "
    read -r choices
    choices="${choices:-all}"

    if [ "$choices" = "all" ]; then
        SELECTED_PROVIDERS=("${providers[@]}")
    else
        SELECTED_PROVIDERS=()
        for num in $choices; do
            local idx=$((num - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#providers[@]}" ]; then
                SELECTED_PROVIDERS+=("${providers[$idx]}")
            else
                warn "Skipping invalid choice: $num"
            fi
        done
    fi

    if [ "${#SELECTED_PROVIDERS[@]}" -eq 0 ]; then
        error "No providers selected. Exiting."
        exit 1
    fi

    echo ""
    success "Selected: $(printf '%s, ' "${SELECTED_PROVIDERS[@]}" | sed 's/, $//')"
}

select_models_for_provider() {
    local provider="$1"
    local models=()
    local display_names=()

    while IFS='|' read -r mid dname mtokens ptype burl; do
        models+=("$mid|$dname|$mtokens|$ptype|$burl")
        display_names+=("$dname")
    done < <(get_models_for_provider "$provider")

    # Non-interactive: select all models
    if $NON_INTERACTIVE; then
        for m in "${models[@]}"; do
            SELECTED_MODELS+=("$m")
        done
        return
    fi

    echo ""
    printf "${BOLD}Models for $(get_provider_name "$provider"):${RESET}\n"
    local i=1
    for name in "${display_names[@]}"; do
        printf "  ${BOLD}%d)${RESET} %s\n" "$i" "$name"
        i=$((i + 1))
    done
    echo ""
    ask "Which models? (e.g., 1 2 or all) [all]: "
    read -r choices
    choices="${choices:-all}"

    if [ "$choices" = "all" ]; then
        for m in "${models[@]}"; do
            SELECTED_MODELS+=("$m")
        done
    else
        for num in $choices; do
            local idx=$((num - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#models[@]}" ]; then
                SELECTED_MODELS+=("${models[$idx]}")
            fi
        done
    fi
}

confirm_selection() {
    echo ""
    printf "${BOLD}═══ Configuration Summary ═══${RESET}\n"
    echo ""
    printf "  %-35s %-15s %s\n" "MODEL" "PROVIDER" "SOURCE"
    printf "  %-35s %-15s %s\n" "─────────────────────────────────" "───────────────" "──────────"

    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"
        printf "  %-35s %-15s %s\n" "$dname" "$ptype" "$mid"
    done

    echo ""
    printf "  ${DIM}Proxy port: $PROXY_PORT | Claude: client-controlled thinking | GPT/Gemini: high reasoning forced${RESET}\n"
    echo ""

    if ! $NON_INTERACTIVE; then
        ask "Proceed with this configuration? [Y/n]: "
        read -r answer
        if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
            error "Aborted."
            exit 0
        fi
    fi
}

# ── Step 4: Generate config files ────────────────────────────────────────────

generate_config_yaml() {
    mkdir -p "$CONFIG_DIR"
    backup_if_exists "$CONFIG_FILE"

    local has_claude=false has_gpt=false has_gemini_copilot=false has_gemini_antigravity=false

    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"
        case "$mid" in
            claude-*)  has_claude=true ;;
            gpt-*)     has_gpt=true ;;
        esac
    done

    for p in "${SELECTED_PROVIDERS[@]}"; do
        case "$p" in
            github-copilot)
                for m in "${SELECTED_MODELS[@]}"; do
                    case "$m" in gemini-*) has_gemini_copilot=true ;; esac
                done
                ;;
            antigravity) has_gemini_antigravity=true ;;
        esac
    done

    cat > "$CONFIG_FILE" << YAML_HEADER
port: $PROXY_PORT

auth-dir: "~/.cli-proxy-api"

# Empty = no API key required from clients (OAuth tokens used instead)
api-keys: []

debug: false
logging-to-file: false
usage-statistics-enabled: true
proxy-url: ""
request-retry: 3

# Auto-switch on rate limits
quota-exceeded:
  switch-project: true
  switch-preview-model: true

remote-management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: true

claude-api-key: []

# Thinking/reasoning overrides
# Claude: no override — clients set their own thinking mode (e.g. adaptive)
# GPT/Gemini: force high reasoning at proxy level
payload:
  override:
YAML_HEADER

    if $has_gpt; then
        cat >> "$CONFIG_FILE" << 'GPT_BLOCK'
    # GPT full models: force high reasoning (excludes mini for fast validation)
    - models:
        - name: "gpt-5.4"
        - name: "gpt-5.3-codex"
        - name: "gpt-5-codex"
        - name: "gpt-5"
      params:
        "reasoning.effort": "high"
GPT_BLOCK
    fi

    if $has_gemini_copilot; then
        cat >> "$CONFIG_FILE" << 'GEMINI_COPILOT_BLOCK'
    # Gemini models via Copilot: force high thinking
    - models:
        - name: "gemini-*"
      protocol: "gemini"
      params:
        "generationConfig.thinkingConfig.thinkingLevel": "high"
GEMINI_COPILOT_BLOCK
    fi

    if $has_gemini_antigravity; then
        cat >> "$CONFIG_FILE" << 'GEMINI_AG_BLOCK'
    # Gemini models via Antigravity: force high thinking
    - models:
        - name: "gemini-*"
      protocol: "antigravity"
      params:
        "generationConfig.thinkingConfig.thinkingLevel": "high"
GEMINI_AG_BLOCK
    fi

    success "Generated $CONFIG_FILE"
}

generate_settings_json() {
    if $SKIP_DROID; then
        info "Skipping settings.json generation (--skip-droid)"
        return
    fi

    mkdir -p "$FACTORY_DIR"
    backup_if_exists "$SETTINGS_FILE"

    local index=0
    local models_json=""

    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"

        local safe_name
        safe_name=$(echo "$dname" | sed 's/ /-/g; s/[^A-Za-z0-9._\[\]-]//g')
        local model_id="custom:${safe_name}-${index}"

        if [ "$index" -gt 0 ]; then
            models_json="${models_json},"
        fi

        models_json="${models_json}
    {
      \"model\": \"${mid}\",
      \"id\": \"${model_id}\",
      \"index\": ${index},
      \"baseUrl\": \"${burl}\",
      \"apiKey\": \"sk-dummy\",
      \"displayName\": \"${dname}\",
      \"maxOutputTokens\": ${mtokens},
      \"noImageSupport\": false,
      \"provider\": \"${ptype}\"
    }"
        index=$((index + 1))
    done

    # First claude-opus-* wins as default (order in get_models_for_provider controls which).
    local default_model_id=""
    local default_opus_set=""
    local validation_model_id=""
    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"
        local safe_name
        safe_name=$(echo "$dname" | sed 's/ /-/g; s/[^A-Za-z0-9._\[\]-]//g')
        local midx=0
        for m2 in "${SELECTED_MODELS[@]}"; do
            IFS='|' read -r mid2 dname2 mtokens2 ptype2 burl2 <<< "$m2"
            if [ "$mid2" = "$mid" ] && [ "$dname2" = "$dname" ]; then
                break
            fi
            midx=$((midx + 1))
        done
        local this_id="custom:${safe_name}-${midx}"
        if [ -z "$default_model_id" ]; then
            default_model_id="$this_id"
        fi
        case "$mid" in
            claude-opus-*)
                if [ -z "$default_opus_set" ]; then
                    default_model_id="$this_id"
                    default_opus_set=1
                fi
                ;;
        esac
        case "$mid" in
            gpt-5.4-mini) validation_model_id="$this_id" ;;
        esac
    done
    if [ -z "$validation_model_id" ]; then
        validation_model_id="$default_model_id"
    fi

    # Merge (not overwrite) when jq is available and settings.json already exists.
    # See setup.sh for merge rules — same behavior here.
    if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ]; then
        backup_if_exists "$SETTINGS_FILE"
        local tmp="$SETTINGS_FILE.tmp.$$"
        jq \
          --argjson newModels "[${models_json}
  ]" \
          --arg defaultId "$default_model_id" \
          --arg validatorId "$validation_model_id" \
          '.customModels = $newModels
           | .sessionDefaultSettings = (
               {reasoningEffort: "high", interactionMode: "auto", autonomyLevel: "high", autonomyMode: "auto-high"}
               + (.sessionDefaultSettings // {})
               + {model: $defaultId}
             )
           | .missionModelSettings = ((.missionModelSettings // {}) + {
               workerModel: $defaultId,
               workerReasoningEffort: "high",
               validationWorkerModel: $validatorId,
               validationWorkerReasoningEffort: "none"
             })
           | .showThinkingInMainView //= true
           | .showTokenUsageIndicator //= true' \
          "$SETTINGS_FILE" > "$tmp" 2>/dev/null

        if jq empty "$tmp" 2>/dev/null; then
            mv "$tmp" "$SETTINGS_FILE"
            success "Merged settings into $SETTINGS_FILE (preserved existing keys)"
            info "Default model: ${default_model_id}"
            info "Mission worker: ${default_model_id} (reasoning: high)"
            info "Mission validator: ${validation_model_id} (reasoning: none)"
            return
        fi
        rm -f "$tmp"
        warn "jq merge produced invalid JSON; falling back to fresh-file write"
    elif ! command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS_FILE" ]; then
        warn "jq not installed — cannot merge existing settings.json, will OVERWRITE."
        warn "Install jq (apt-get install jq, yum install jq, etc.) and re-run for non-destructive merge."
    fi

    [ -f "$SETTINGS_FILE" ] && backup_if_exists "$SETTINGS_FILE"
    cat > "$SETTINGS_FILE" << SETTINGS_EOF
{
  "showThinkingInMainView": true,
  "customModels": [${models_json}
  ],
  "sessionDefaultSettings": {
    "model": "${default_model_id}",
    "reasoningEffort": "high",
    "interactionMode": "auto",
    "autonomyLevel": "high",
    "autonomyMode": "auto-high"
  },
  "missionModelSettings": {
    "workerModel": "${default_model_id}",
    "workerReasoningEffort": "high",
    "validationWorkerModel": "${validation_model_id}",
    "validationWorkerReasoningEffort": "none"
  },
  "showTokenUsageIndicator": true
}
SETTINGS_EOF

    success "Generated $SETTINGS_FILE"
    info "Default model: ${default_model_id}"
    info "Mission worker: ${default_model_id} (reasoning: high)"
    info "Mission validator: ${validation_model_id} (reasoning: none)"
}

# ── Step 5: Authentication ───────────────────────────────────────────────────

authenticate_provider() {
    local provider="$1"
    local flag
    flag=$(get_auth_flag "$provider")
    local name
    name=$(get_provider_name "$provider")

    echo ""
    printf "${BOLD}Authenticating: ${name}${RESET}\n"

    # Headless: check if the proxy supports device-code flow
    # The proxy will print a URL + code for the user to visit on another device
    info "Starting device-code authentication flow..."
    info "You will see a URL and code — open it on any browser (phone, laptop, etc.)"
    echo ""

    "$BINARY_PATH" -config "$CONFIG_FILE" "$flag"

    if [ $? -eq 0 ]; then
        success "$name authenticated"
    else
        warn "$name authentication may have failed. You can retry later with:"
        echo "  $BINARY_NAME -config $CONFIG_FILE $flag"
    fi
}

authenticate_all() {
    if $SKIP_AUTH; then
        info "Skipping authentication (--skip-auth)"
        info "Run these later to authenticate each provider:"
        for provider in "${SELECTED_PROVIDERS[@]}"; do
            local flag
            flag=$(get_auth_flag "$provider")
            echo "  $BINARY_NAME -config $CONFIG_FILE $flag"
        done
        return
    fi

    echo ""
    printf "${BOLD}═══ Authentication ═══${RESET}\n"
    info "Each provider uses device-code flow (no local browser needed)."
    info "A URL and code will be shown — open it on any device with a browser."

    for provider in "${SELECTED_PROVIDERS[@]}"; do
        authenticate_provider "$provider"
    done
}

# ── Step 6: Shell Integration ────────────────────────────────────────────────

install_shell_function() {
    local user_shell
    user_shell=$(basename "${SHELL:-/bin/bash}")
    local shell_rc=""

    case "$user_shell" in
        zsh)  shell_rc="$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                shell_rc="$HOME/.bashrc"
            else
                shell_rc="$HOME/.bash_profile"
            fi
            ;;
        *)    shell_rc="$HOME/.profile" ;;
    esac

    if $SKIP_DROID; then
        info "Skipping shell function (--skip-droid)"
        return
    fi

    if [ -f "$shell_rc" ] && grep -q 'droidc()' "$shell_rc"; then
        success "droidc() already exists in $shell_rc"
        return
    fi

    cat >> "$shell_rc" << SHELL_BLOCK

# Droid CLI via CLIProxyAPIPlus (unified proxy for all AI providers)
droidc() {
  if ! ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} " && \\
     ! (echo >/dev/tcp/127.0.0.1/${PROXY_PORT}) 2>/dev/null; then
    echo "Starting CLIProxyAPIPlus on :${PROXY_PORT}..."
    cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml &>/dev/null &
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} " || \\
       (echo >/dev/tcp/127.0.0.1/${PROXY_PORT}) 2>/dev/null; then
      echo "Proxy ready."
    else
      echo "Failed to start proxy."
      return 1
    fi
  else
    echo "Proxy already running on :${PROXY_PORT}"
  fi
  ANTHROPIC_BASE_URL=http://localhost:${PROXY_PORT} ANTHROPIC_AUTH_TOKEN=sk-dummy droid "\$@"
}
SHELL_BLOCK

    success "Added droidc() to $shell_rc"
}

# ── Step 7: Systemd Service (optional, Linux-specific) ──────────────────────

install_systemd_service() {
    # Only offer on Linux with systemd
    if [ "$(uname -s)" != "Linux" ] || ! command_exists systemctl; then
        return
    fi

    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/cli-proxy-api.service"

    if $NON_INTERACTIVE; then
        # In non-interactive mode, always install the service
        :
    else
        echo ""
        ask "Install systemd user service for auto-start? [Y/n]: "
        read -r answer
        if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
            return
        fi
    fi

    mkdir -p "$service_dir"

    cat > "$service_file" << SERVICE_EOF
[Unit]
Description=CLIProxyAPIPlus - AI Model Proxy
After=network.target

[Service]
Type=simple
ExecStart=$BINARY_PATH -config $CONFIG_FILE
Restart=on-failure
RestartSec=5
Environment=HOME=$HOME

[Install]
WantedBy=default.target
SERVICE_EOF

    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable cli-proxy-api.service 2>/dev/null
    success "Installed systemd user service: cli-proxy-api.service"
    info "Control with: systemctl --user {start|stop|status|logs} cli-proxy-api"

    # Enable lingering so service runs without login session (important for Railway/VPS)
    if command_exists loginctl; then
        loginctl enable-linger "$(whoami)" 2>/dev/null && \
            success "Enabled lingering (service persists without login session)"
    fi
}

# ── Step 8: Validation ──────────────────────────────────────────────────────

test_proxy() {
    info "Testing proxy startup..."

    # Identify port owner before killing — only stop if it's our own binary.
    # Previously this did a silent `kill` which terminated unrelated processes.
    local existing_pid existing_cmd
    existing_pid=$(pid_on_port "$PROXY_PORT")
    if [ -n "$existing_pid" ]; then
        existing_cmd=$(ps -p "$existing_pid" -o comm= 2>/dev/null | xargs -I{} basename {} 2>/dev/null)
        case "$existing_cmd" in
            "$BINARY_NAME"|"$UPSTREAM_BINARY"|cli-proxy-api*)
                info "Stopping existing proxy (PID $existing_pid, '$existing_cmd')"
                kill "$existing_pid" 2>/dev/null
                sleep 1
                ;;
            *)
                error "Port $PROXY_PORT is held by '$existing_cmd' (PID $existing_pid), not our binary."
                error "Stop that process manually or use --port <N>, then re-run."
                return 1
                ;;
        esac
    fi

    "$BINARY_PATH" -config "$CONFIG_FILE" &>/dev/null &
    PROXY_PID=$!
    sleep 3

    if port_in_use "$PROXY_PORT"; then
        success "Proxy started on port $PROXY_PORT (PID: $PROXY_PID)"

        local model_count
        model_count=$(curl -s "http://localhost:$PROXY_PORT/v1/models" 2>/dev/null | \
            grep -o '"id"' | wc -l | tr -d ' ')
        if [ "$model_count" -gt 0 ] 2>/dev/null; then
            success "Proxy serving $model_count models"
        else
            info "Proxy running but /v1/models returned no models (auth may be needed)"
        fi

        # Stop test proxy
        kill "$PROXY_PID" 2>/dev/null
        PROXY_PID=""
    else
        warn "Proxy failed to start. Check with:"
        echo "  $BINARY_NAME -config $CONFIG_FILE"
        # Check if it exited with an error
        if ! kill -0 "$PROXY_PID" 2>/dev/null; then
            warn "Process exited immediately — run the binary manually to see errors"
        fi
        PROXY_PID=""
    fi
}

# ── Step 9: Summary ─────────────────────────────────────────────────────────

print_summary() {
    echo ""
    printf "${BOLD}═══════════════════════════════════════════════════${RESET}\n"
    printf "${BOLD}  Setup Complete${RESET}\n"
    printf "${BOLD}═══════════════════════════════════════════════════${RESET}\n"
    echo ""
    printf "  ${BOLD}Configured providers:${RESET}\n"
    for p in "${SELECTED_PROVIDERS[@]}"; do
        printf "    ${GREEN}•${RESET} %s\n" "$(get_provider_name "$p")"
    done
    echo ""
    printf "  ${BOLD}Models available (${#SELECTED_MODELS[@]} total):${RESET}\n"
    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"
        printf "    ${GREEN}•${RESET} %s\n" "$dname"
    done
    echo ""
    printf "  ${BOLD}Config files:${RESET}\n"
    printf "    Proxy:  %s\n" "$CONFIG_FILE"
    if ! $SKIP_DROID; then
        printf "    Droid:  %s\n" "$SETTINGS_FILE"
    fi
    printf "    Binary: %s\n" "$BINARY_PATH"
    echo ""
    printf "  ${BOLD}Usage:${RESET}\n"
    if [ "$(uname -s)" = "Linux" ] && command_exists systemctl 2>/dev/null; then
        echo "    systemctl --user start cli-proxy-api   # start proxy"
        echo "    systemctl --user status cli-proxy-api  # check status"
        echo "    journalctl --user -u cli-proxy-api -f  # view logs"
    else
        echo "    $BINARY_NAME -config $CONFIG_FILE &    # start proxy"
    fi
    if ! $SKIP_DROID; then
        echo "    source ~/.*rc && droidc                # start proxy + Droid"
    fi
    echo ""
    if $SKIP_AUTH; then
        printf "  ${BOLD}Authentication (still needed):${RESET}\n"
        for p in "${SELECTED_PROVIDERS[@]}"; do
            local flag
            flag=$(get_auth_flag "$p")
            echo "    $BINARY_NAME -config $CONFIG_FILE $flag"
        done
        echo ""
    else
        printf "  ${BOLD}Re-authenticate a provider:${RESET}\n"
        echo "    $BINARY_NAME -config $CONFIG_FILE -claude-login"
        echo "    $BINARY_NAME -config $CONFIG_FILE -github-copilot-login"
        echo "    $BINARY_NAME -config $CONFIG_FILE -codex-login"
        echo "    $BINARY_NAME -config $CONFIG_FILE -antigravity-login"
        echo ""
    fi
      printf "  ${DIM}Claude: clients control thinking (adaptive supported). GPT/Gemini: high reasoning forced.${RESET}\n"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    show_banner

    # Prerequisites
    check_linux
    detect_arch
    check_dependencies
    echo ""

    info "Step 1/8: Installing binaries..."
    install_droid_linux
    install_proxy_binary
    ensure_path
    echo ""

    info "Step 2/8: Select providers..."
    select_providers

    info "Step 3/8: Select models..."
    for provider in "${SELECTED_PROVIDERS[@]}"; do
        select_models_for_provider "$provider"
    done

    confirm_selection

    info "Step 4/8: Generating config files..."
    generate_config_yaml
    generate_settings_json
    echo ""

    info "Step 5/8: Authentication..."
    authenticate_all
    echo ""

    info "Step 6/8: Shell integration..."
    install_shell_function
    echo ""

    info "Step 7/8: Systemd service..."
    install_systemd_service
    echo ""

    info "Step 8/8: Validation..."
    test_proxy
    echo ""

    print_summary
}

main "$@"

#!/bin/bash
# =============================================================================
# CLIProxyAPIPlus + Factory Droid CLI — Interactive Installer for macOS
# =============================================================================
# Configures a local proxy that routes AI model requests through your
# existing subscriptions (Claude Max, GitHub Copilot, OpenAI Max, Antigravity)
# to Factory Droid CLI with max reasoning enabled on all models.
# =============================================================================

set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
PROXY_PORT=8317
CONFIG_DIR="$HOME/.cli-proxy-api"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
FACTORY_DIR="$HOME/.factory"
SETTINGS_FILE="$FACTORY_DIR/settings.json"
INSTALL_DIR="$HOME/.local/bin"
BINARY_NAME="cli-proxy-api-plus"
BINARY_PATH="$INSTALL_DIR/$BINARY_NAME"
GITHUB_REPO="router-for-me/CLIProxyAPIPlus"
PROXY_PID=""

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { printf "${BLUE}→${RESET} %s\n" "$1"; }
success() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()    { printf "${YELLOW}!${RESET} %s\n" "$1"; }
error()   { printf "${RED}✗${RESET} %s\n" "$1"; }
ask()     { printf "${YELLOW}?${RESET} %s" "$1"; }

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

# ── Welcome banner ───────────────────────────────────────────────────────────
show_banner() {
    printf "\n${BOLD}"
    echo "  ╔═══════════════════════════════════════════════════╗"
    echo "  ║   CLIProxyAPIPlus + Factory Droid CLI Installer   ║"
    echo "  ║                                                   ║"
    echo "  ║   Route your AI subscriptions through a local     ║"
    echo "  ║   proxy with max reasoning on all models.         ║"
    echo "  ╚═══════════════════════════════════════════════════╝"
    printf "${RESET}\n"
    printf "  ${DIM}Supports: Claude Max • GitHub Copilot • OpenAI Max • Antigravity${RESET}\n\n"
}

# ── Step 1: Prerequisites ───────────────────────────────────────────────────
check_macos() {
    if [ "$(uname)" != "Darwin" ]; then
        error "This script only supports macOS."
        exit 1
    fi
    success "macOS detected"
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        arm64)  DOWNLOAD_ARCH="darwin_arm64" ;;
        x86_64) DOWNLOAD_ARCH="darwin_amd64" ;;
        *)      error "Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    success "Architecture: $ARCH"
}

install_homebrew() {
    if command_exists brew; then
        success "Homebrew already installed"
        return
    fi
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add to PATH for this session
    if [ "$ARCH" = "arm64" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    success "Homebrew installed"
}

install_droid() {
    if command_exists droid; then
        success "Factory Droid CLI already installed ($(droid --version 2>/dev/null || echo 'unknown'))"
        return
    fi
    info "Installing Factory Droid CLI..."
    brew install --cask droid
    success "Factory Droid CLI installed"
}

install_proxy_binary() {
    if [ -f "$BINARY_PATH" ]; then
        local version
        version=$("$BINARY_PATH" --help 2>&1 | head -1 | grep -o 'Version: [^ ,]*' | cut -d' ' -f2 || echo "unknown")
        success "CLIProxyAPIPlus already installed ($version)"
        ask "Re-download latest? [y/N]: "
        read -r answer
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            return
        fi
    fi

    info "Fetching latest CLIProxyAPIPlus release..."
    local download_url
    download_url=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | \
        grep "browser_download_url" | grep "$DOWNLOAD_ARCH" | head -1 | cut -d'"' -f4)

    if [ -z "$download_url" ]; then
        error "Could not find download URL for $DOWNLOAD_ARCH"
        exit 1
    fi

    info "Downloading from: $(basename "$download_url")"
    local tmpdir
    tmpdir=$(mktemp -d)
    curl -fsSL "$download_url" -o "$tmpdir/proxy.tar.gz"
    tar xzf "$tmpdir/proxy.tar.gz" -C "$tmpdir"

    mkdir -p "$INSTALL_DIR"
    cp "$tmpdir/$BINARY_NAME" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
    rm -rf "$tmpdir"

    local version
    version=$("$BINARY_PATH" --help 2>&1 | head -1 | grep -o 'Version: [^ ,]*' | cut -d' ' -f2 || echo "unknown")
    success "CLIProxyAPIPlus installed ($version)"
}

ensure_path() {
    if echo "$PATH" | tr ':' '\n' | grep -q "$INSTALL_DIR"; then
        return
    fi
    if [ -f "$HOME/.zshrc" ] && grep -q "$INSTALL_DIR" "$HOME/.zshrc"; then
        return
    fi
    echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$HOME/.zshrc"
    export PATH="$INSTALL_DIR:$PATH"
    success "Added $INSTALL_DIR to PATH"
}

# ── Step 2: Provider & Model Selection ───────────────────────────────────────

# Model registry: model_id|display_name|max_output_tokens|provider_type|base_url
get_models_for_provider() {
    case "$1" in
        claude)
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

# Global arrays to collect selections
SELECTED_PROVIDERS=()
SELECTED_MODELS=()

select_providers() {
    local providers=("claude" "github-copilot" "codex" "antigravity")

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
    printf "  ${DIM}Proxy port: $PROXY_PORT | Max reasoning: forced on all models (except mini for fast validation)${RESET}\n"
    echo ""
    ask "Proceed with this configuration? [Y/n]: "
    read -r answer
    if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
        error "Aborted."
        exit 0
    fi
}

# ── Step 4: Generate config files ────────────────────────────────────────────

generate_config_yaml() {
    mkdir -p "$CONFIG_DIR"
    backup_if_exists "$CONFIG_FILE"

    # Determine which override blocks are needed
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

    # Write config
    cat > "$CONFIG_FILE" << 'YAML_HEADER'
port: 8317

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

# Force max thinking/reasoning on ALL proxied requests
payload:
  override:
YAML_HEADER

    if $has_claude; then
        cat >> "$CONFIG_FILE" << 'CLAUDE_BLOCK'
    # Claude models: force extended thinking
    - models:
        - name: "claude-*"
      protocol: "claude"
      params:
        "thinking.type": "enabled"
        "thinking.budget_tokens": 30000
        "max_tokens": 128000
CLAUDE_BLOCK
    fi

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
    mkdir -p "$FACTORY_DIR"
    backup_if_exists "$SETTINGS_FILE"

    local index=0
    local models_json=""

    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"

        # Build ID from display name
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

    # Find the first claude-opus model ID for default, fallback to first model
    local default_model_id=""
    local validation_model_id=""
    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"
        local safe_name
        safe_name=$(echo "$dname" | sed 's/ /-/g; s/[^A-Za-z0-9._\[\]-]//g')
        # Find index of this model
        local midx=0
        for m2 in "${SELECTED_MODELS[@]}"; do
            IFS='|' read -r mid2 dname2 mtokens2 ptype2 burl2 <<< "$m2"
            if [ "$mid2" = "$mid" ] && [ "$dname2" = "$dname" ]; then
                break
            fi
            midx=$((midx + 1))
        done
        local this_id="custom:${safe_name}-${midx}"
        # Default model: prefer claude-opus
        if [ -z "$default_model_id" ]; then
            default_model_id="$this_id"
        fi
        case "$mid" in
            claude-opus-*) default_model_id="$this_id" ;;
        esac
        # Validation model: prefer gpt-5.4-mini
        case "$mid" in
            gpt-5.4-mini) validation_model_id="$this_id" ;;
        esac
    done
    # Fallback validation to first model if no mini found
    if [ -z "$validation_model_id" ]; then
        validation_model_id="$default_model_id"
    fi

    cat > "$SETTINGS_FILE" << SETTINGS_EOF
{
  "showThinkingInMainView": true,
  "customModels": [${models_json}
  ],
  "model": "custom-model",
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
    info "This will open your browser for OAuth login..."
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
    echo ""
    printf "${BOLD}═══ Authentication ═══${RESET}\n"
    info "Each provider will open a browser window for login."
    info "Complete the login, then the script will continue."

    for provider in "${SELECTED_PROVIDERS[@]}"; do
        authenticate_provider "$provider"
    done
}

# ── Step 6: Shell Integration ────────────────────────────────────────────────

install_zshrc_function() {
    local zshrc="$HOME/.zshrc"

    if [ -f "$zshrc" ] && grep -q 'droidc()' "$zshrc"; then
        success "droidc() already exists in ~/.zshrc"
        return
    fi

    cat >> "$zshrc" << 'ZSHRC_BLOCK'

# Droid CLI via CLIProxyAPIPlus (unified proxy for all AI providers)
droidc() {
  if ! lsof -i :8317 &>/dev/null; then
    echo "Starting CLIProxyAPIPlus on :8317..."
    cli-proxy-api-plus -config ~/.cli-proxy-api/config.yaml &>/dev/null &
    sleep 2
    if lsof -i :8317 &>/dev/null; then
      echo "Proxy ready."
    else
      echo "Failed to start proxy."
      return 1
    fi
  else
    echo "Proxy already running on :8317"
  fi
  ANTHROPIC_BASE_URL=http://localhost:8317 ANTHROPIC_AUTH_TOKEN=sk-dummy droid "$@"
}
ZSHRC_BLOCK

    success "Added droidc() to ~/.zshrc"
}

# ── Step 7: Validation ───────────────────────────────────────────────────────

test_proxy() {
    info "Testing proxy startup..."

    # Kill any existing proxy on our port
    local existing_pid
    existing_pid=$(lsof -t -i :$PROXY_PORT 2>/dev/null)
    if [ -n "$existing_pid" ]; then
        kill "$existing_pid" 2>/dev/null
        sleep 1
    fi

    "$BINARY_PATH" -config "$CONFIG_FILE" &>/dev/null &
    PROXY_PID=$!
    sleep 3

    if lsof -i :$PROXY_PORT &>/dev/null; then
        success "Proxy started on port $PROXY_PORT"

        local model_count
        model_count=$(curl -s "http://localhost:$PROXY_PORT/v1/models" 2>/dev/null | \
            grep -o '"id"' | wc -l | tr -d ' ')
        success "Proxy serving $model_count models"

        # Stop test proxy
        kill "$PROXY_PID" 2>/dev/null
        PROXY_PID=""
    else
        warn "Proxy failed to start. Check config with:"
        echo "  $BINARY_NAME -config $CONFIG_FILE"
        PROXY_PID=""
    fi
}

# ── Step 8: Summary ──────────────────────────────────────────────────────────

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
    printf "    Droid:  %s\n" "$SETTINGS_FILE"
    printf "    Binary: %s\n" "$BINARY_PATH"
    echo ""
    printf "  ${BOLD}Usage:${RESET}\n"
    echo "    source ~/.zshrc    # load the droidc function"
    echo "    droidc             # start proxy + Droid"
    echo "    /model             # select a model in Droid"
    echo ""
    printf "  ${BOLD}Re-authenticate a provider:${RESET}\n"
    echo "    $BINARY_NAME -config $CONFIG_FILE -claude-login"
    echo "    $BINARY_NAME -config $CONFIG_FILE -github-copilot-login"
    echo "    $BINARY_NAME -config $CONFIG_FILE -codex-login"
    echo "    $BINARY_NAME -config $CONFIG_FILE -antigravity-login"
    echo ""
    printf "  ${DIM}Max reasoning is forced at the proxy level for all models.${RESET}\n"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    show_banner

    # Prerequisites
    check_macos
    detect_arch
    echo ""

    info "Step 1/7: Installing dependencies..."
    install_homebrew
    install_droid
    install_proxy_binary
    ensure_path
    echo ""

    info "Step 2/7: Select providers..."
    select_providers

    info "Step 3/7: Select models..."
    for provider in "${SELECTED_PROVIDERS[@]}"; do
        select_models_for_provider "$provider"
    done

    confirm_selection

    info "Step 4/7: Generating config files..."
    generate_config_yaml
    generate_settings_json
    echo ""

    info "Step 5/7: Authentication..."
    authenticate_all
    echo ""

    info "Step 6/7: Shell integration..."
    install_zshrc_function
    echo ""

    info "Step 7/7: Validation..."
    test_proxy
    echo ""

    print_summary
}

main "$@"

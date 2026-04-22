#!/bin/bash
# =============================================================================
# CLIProxyAPIPlus + Factory Droid CLI — Interactive Installer for macOS
# =============================================================================
# Configures a local proxy that routes AI model requests through your
# existing subscriptions (Claude Max, OpenAI Max / Codex, Antigravity)
# to Factory Droid CLI with max reasoning enabled on all models.
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
LAUNCHD_LABEL="sh.claude-proxy.daemon"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
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
    printf "  ${DIM}Supports: Claude Max • OpenAI Max / Codex • Antigravity${RESET}\n\n"
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

build_from_vendor() {
    # Returns 0 on successful build, 1 if vendor/source/go unavailable or build failed.
    [ -d "$VENDOR_DIR" ] || return 1
    [ -f "$VENDOR_DIR/go.mod" ] || return 1
    command_exists go || return 1

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

    if [ ! -f "$tmpdir/$UPSTREAM_BINARY" ]; then
        error "Expected '$UPSTREAM_BINARY' inside tarball; got:"
        ls -1 "$tmpdir" | sed 's/^/  /'
        rm -rf "$tmpdir"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$tmpdir/$UPSTREAM_BINARY" "$BINARY_PATH"
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
        # Skip prompt on non-TTY so curl|bash / CI don't hang.
        if [ -t 0 ]; then
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

    # Fallback: downloaded release binary.
    if [ -d "$VENDOR_DIR" ] && ! command_exists go; then
        warn "vendor/cliproxyapi exists but Go toolchain is missing."
        warn "Install Go to build from source: brew install go"
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
            # Order = menu order in Droid. First claude-opus-* entry wins as session default
            # (see default_model_id selector below).
            echo "claude-opus-4-7|Opus 4.7 [Claude Max]|128000|anthropic|http://localhost:$PROXY_PORT"
            echo "claude-opus-4-6|Opus 4.6 1M [Claude Max]|128000|anthropic|http://localhost:$PROXY_PORT"
            echo "claude-sonnet-4-6|Sonnet 4.6 [Claude Max]|64000|anthropic|http://localhost:$PROXY_PORT"
            echo "claude-haiku-4-5|Haiku 4.5 [Claude Max]|32000|anthropic|http://localhost:$PROXY_PORT"
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
        codex)           echo "OpenAI Max / Codex" ;;
        antigravity)     echo "Antigravity" ;;
    esac
}

get_provider_desc() {
    case "$1" in
        claude)          echo "Opus 4.7, Opus 4.6, Sonnet 4.6, Haiku 4.5" ;;
        codex)           echo "GPT-5-Codex, GPT-5" ;;
        antigravity)     echo "Gemini 3 Pro, Gemini 3 Flash" ;;
    esac
}

get_auth_flag() {
    case "$1" in
        claude)          echo "-claude-login" ;;
        codex)           echo "-codex-login" ;;
        antigravity)     echo "-antigravity-login" ;;
    esac
}

# Global arrays to collect selections
SELECTED_PROVIDERS=()
SELECTED_MODELS=()

select_providers() {
    local providers=("claude" "codex" "antigravity")

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
    printf "  ${DIM}Proxy port: $PROXY_PORT | Claude: client-controlled thinking | GPT/Gemini: high reasoning forced${RESET}\n"
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
    local has_claude=false has_gpt=false has_gemini_antigravity=false

    for m in "${SELECTED_MODELS[@]}"; do
        IFS='|' read -r mid dname mtokens ptype burl <<< "$m"
        case "$mid" in
            claude-*)  has_claude=true ;;
            gpt-*)     has_gpt=true ;;
        esac
    done

    for p in "${SELECTED_PROVIDERS[@]}"; do
        case "$p" in
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

    # Pick default model: first claude-opus-* in the list (so ordering in
    # get_models_for_provider controls which Opus becomes session default).
    # Fall back to the first model overall if no claude-opus-* is selected.
    local default_model_id=""
    local default_opus_set=""     # sticky flag: first opus wins
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
        # Fallback default: first model overall
        if [ -z "$default_model_id" ]; then
            default_model_id="$this_id"
        fi
        # Preferred default: first claude-opus-* (once set, don't overwrite)
        case "$mid" in
            claude-opus-*)
                if [ -z "$default_opus_set" ]; then
                    default_model_id="$this_id"
                    default_opus_set=1
                fi
                ;;
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

    # Merge (not overwrite) when jq is available and settings.json already exists.
    # Merge rules:
    #   - customModels: REPLACE wholesale (re-runs idempotent, no orphan entries)
    #   - sessionDefaultSettings.model: REPLACE (user wants proxy-routed default)
    #   - other sessionDefaultSettings keys: PRESERVE if present, default otherwise
    #     (do NOT silently flip autonomyMode, specModeReasoningEffort, etc.)
    #   - missionModelSettings: REPLACE workerModel/validationWorkerModel; merge rest
    #   - UI flags (showThinkingInMainView, showTokenUsageIndicator): set only if absent
    #   - Every other user-owned key (hooks, commandAllowlist, commandDenylist, etc.): PRESERVE
    if command_exists jq && [ -f "$SETTINGS_FILE" ]; then
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
    elif ! command_exists jq && [ -f "$SETTINGS_FILE" ]; then
        warn "jq not installed — cannot merge existing settings.json, will OVERWRITE."
        warn "Install jq (brew install jq) and re-run for non-destructive merge."
    fi

    # Fresh-file write (first run OR jq missing OR merge failed). backup_if_exists already ran above if applicable.
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

    # Identify port owner before killing — only stop if it's our own binary.
    # Previously this did a silent `kill` which happily terminated unrelated processes.
    local existing_pid existing_cmd
    existing_pid=$(lsof -t -i :$PROXY_PORT 2>/dev/null | head -1)
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
                error "Stop that process manually or change PROXY_PORT, then re-run."
                return 1
                ;;
        esac
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

# ── Step 8: LaunchAgent (macOS auto-start / keep-alive) ─────────────────────

install_launchd_service() {
    # Prompt on TTY; skip silently on non-TTY (curl|bash).
    if [ -t 0 ]; then
        ask "Install LaunchAgent so the proxy auto-starts at login + restarts on crash? [Y/n]: "
        read -r answer
        case "$answer" in
            n|N) info "Skipped LaunchAgent install."; return ;;
        esac
    else
        info "Non-interactive mode: skipping LaunchAgent install (set up manually if wanted)."
        return
    fi

    mkdir -p "$(dirname "$LAUNCHD_PLIST")"

    # Unload any prior version before rewriting so we don't have two daemons.
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true

    cat > "$LAUNCHD_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BINARY_PATH}</string>
    <string>-config</string>
    <string>${CONFIG_FILE}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${CONFIG_DIR}/proxy.log</string>
  <key>StandardErrorPath</key><string>${CONFIG_DIR}/proxy.log</string>
  <key>WorkingDirectory</key><string>${HOME}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
  </dict>
</dict>
</plist>
PLIST

    # Hand control to launchd: kill any manual nohup instance first.
    if [ -f /tmp/claude-proxy.pid ]; then
        local manual_pid
        manual_pid=$(cat /tmp/claude-proxy.pid 2>/dev/null)
        if [ -n "$manual_pid" ] && kill -0 "$manual_pid" 2>/dev/null; then
            info "Stopping manual proxy (PID $manual_pid) — handing control to launchd"
            kill "$manual_pid" 2>/dev/null
            sleep 1
        fi
    fi
    # Also sweep any non-pid-file owners that match our binary name.
    local stragglers
    stragglers=$(lsof -t -i :"$PROXY_PORT" 2>/dev/null)
    for p in $stragglers; do
        local cmd
        cmd=$(ps -p "$p" -o comm= 2>/dev/null | xargs -I{} basename {} 2>/dev/null)
        case "$cmd" in
            "$BINARY_NAME"|"$UPSTREAM_BINARY"|cli-proxy-api*)
                kill "$p" 2>/dev/null ;;
        esac
    done
    sleep 1

    launchctl load "$LAUNCHD_PLIST"
    sleep 2

    if launchctl list 2>/dev/null | grep -q "$LAUNCHD_LABEL"; then
        success "LaunchAgent loaded → $LAUNCHD_PLIST"
        info "  start at login + restart on crash (KeepAlive=true)"
        info "  stop:    launchctl unload $LAUNCHD_PLIST"
        info "  restart: launchctl unload $LAUNCHD_PLIST && launchctl load $LAUNCHD_PLIST"
    else
        warn "LaunchAgent file written but not in launchctl list."
        warn "Check with: launchctl list | grep claude-proxy"
    fi
}

# ── Step 9: Summary ──────────────────────────────────────────────────────────

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
    echo "    $BINARY_NAME -config $CONFIG_FILE -codex-login"
    echo "    $BINARY_NAME -config $CONFIG_FILE -antigravity-login"
    echo ""
    printf "  ${DIM}Claude: clients control thinking (adaptive supported). GPT/Gemini: high reasoning forced.${RESET}\n"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    show_banner

    # Prerequisites
    check_macos
    detect_arch
    echo ""

    info "Step 1/8: Installing dependencies..."
    install_homebrew
    install_droid
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
    install_zshrc_function
    echo ""

    info "Step 7/8: Validation..."
    test_proxy
    echo ""

    info "Step 8/8: LaunchAgent (auto-start at login + restart on crash)..."
    install_launchd_service
    echo ""

    print_summary
}

main "$@"

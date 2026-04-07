#!/usr/bin/env bash
# Agent Discord Streamer — interactive setup wizard.
#
# Sets up:
#   ~/.config/agent-discord-streamer/.token   (chmod 600)
#   ~/.config/agent-discord-streamer/config
#   Optional: macOS LaunchAgent for auto-start
#   Optional: .claude/settings.json in each project directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/agent-discord-streamer"
TOKEN_FILE="$CONFIG_DIR/.token"
CONFIG_FILE="$CONFIG_DIR/config"

_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
_bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
_ask()    { printf '\033[0;36m%s\033[0m ' "$*"; }

_require() { command -v "$1" >/dev/null 2>&1 || { _red "Required: $1 not found in PATH"; exit 1; }; }

echo ""
_bold "╔══════════════════════════════════════╗"
_bold "║   Agent Discord Streamer — Setup Wizard    ║"
_bold "╚══════════════════════════════════════╝"
echo ""

_require curl
_require jq

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

# ── 1. Discord Bot Token ──────────────────────────────────────────────────────
echo ""
_bold "Step 1 — Discord Bot Token"
echo "The token is stored only in $TOKEN_FILE (mode 600)"
echo "and is never exported to AI agent processes."
echo ""
_ask "Paste your Discord bot token (input hidden):"
read -rs BOT_TOKEN; echo ""
[[ -n "$BOT_TOKEN" ]] || { _red "Token cannot be empty."; exit 1; }

# Validate token via /users/@me
_yellow "Validating token..."
ME_JSON=$(curl -sS \
  -H "Authorization: Bot $BOT_TOKEN" \
  -H "User-Agent: agent-discord-streamer/1.0" \
  "https://discord.com/api/v10/users/@me") || { _red "curl failed"; exit 1; }

BOT_USERNAME=$(echo "$ME_JSON" | jq -r '.username // empty' 2>/dev/null)
BOT_ID=$(echo "$ME_JSON" | jq -r '.id // empty' 2>/dev/null)

if [[ -z "$BOT_USERNAME" ]]; then
  _red "Token validation failed. Discord response:"
  echo "$ME_JSON"
  exit 1
fi

_green "✓ Authenticated as: $BOT_USERNAME (ID: $BOT_ID)"

printf '%s' "$BOT_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# ── 2. Channels ───────────────────────────────────────────────────────────────
echo ""
_bold "Step 2 — Channels to watch"
echo "Format: enter one channel ID per prompt, then choose the AI agent for it."
echo "Enter a blank channel ID to finish."
echo ""

CHANNELS=()
while true; do
  _ask "Channel ID (blank to finish):"
  read -r CHANNEL_ID
  [[ -z "$CHANNEL_ID" ]] && break

  # Validate channel ID is numeric (Discord snowflake)
  [[ "$CHANNEL_ID" =~ ^[0-9]+$ ]] || { _yellow "Invalid channel ID (should be numeric). Try again."; continue; }

  # Validate channel access
  _yellow "Checking access to channel $CHANNEL_ID..."
  CHAN_JSON=$(curl -sS \
    -H "Authorization: Bot $BOT_TOKEN" \
    -H "User-Agent: agent-discord-streamer/1.0" \
    "https://discord.com/api/v10/channels/$CHANNEL_ID") || { _yellow "curl failed, adding anyway..."; }

  CHAN_NAME=$(echo "$CHAN_JSON" | jq -r '.name // empty' 2>/dev/null || echo "")
  if [[ -n "$CHAN_NAME" ]]; then
    _green "  ✓ #$CHAN_NAME"
  else
    _yellow "  Could not verify — make sure the bot is in this server with View Channel + Send Messages."
  fi

  _ask "  AI agent for this channel [claude/codex] (default: claude):"
  read -r AGENT
  AGENT="${AGENT:-claude}"
  [[ "$AGENT" == "claude" || "$AGENT" == "codex" ]] || { _yellow "Unknown agent, defaulting to claude."; AGENT=claude; }

  _ask "  Project path for this channel (absolute path, blank to skip):"
  read -r PROJECT_PATH
  if [[ -n "$PROJECT_PATH" && ! -d "$PROJECT_PATH" ]]; then
    _yellow "  Warning: path does not exist yet: $PROJECT_PATH"
  fi

  # --- agent permissions ---
  CODEX_SANDBOX=""
  CODEX_TRUST=""

  if [[ "$AGENT" == "claude" && -n "$PROJECT_PATH" && -d "$PROJECT_PATH" ]]; then
    # Write .claude/settings.json with scoped tool permissions.
    CLAUDE_SETTINGS_DIR="$PROJECT_PATH/.claude"
    CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"
    mkdir -p "$CLAUDE_SETTINGS_DIR"

    echo ""
    _bold "  Permissions for Claude in $PROJECT_PATH"
    echo "  Read and Edit/Write are always allowed."
    echo "  Choose Bash access level:"
    echo "    1) Full  — Bash(*) — all shell commands"
    echo "    2) Dev   — git, npm/yarn/pnpm, make, pytest, cargo, go (recommended)"
    echo "    3) Git   — git commands only"
    echo "    4) None  — no shell commands"
    _ask "  Choice [1/2/3/4] (default: 2):"
    read -r BASH_LEVEL
    BASH_LEVEL="${BASH_LEVEL:-2}"

    case "$BASH_LEVEL" in
      1) BASH_RULES='"Bash(*)"' ;;
      3) BASH_RULES='"Bash(git *)"' ;;
      4) BASH_RULES='' ;;
      *) BASH_RULES='"Bash(git *)", "Bash(npm *)", "Bash(yarn *)", "Bash(pnpm *)", "Bash(make *)", "Bash(pytest *)", "Bash(cargo *)", "Bash(go *)"' ;;
    esac

    ALLOW_RULES='"Read(*)", "Edit(*)", "Write(*)"'
    [[ -n "$BASH_RULES" ]] && ALLOW_RULES="$ALLOW_RULES, $BASH_RULES"

    cat > "$CLAUDE_SETTINGS_FILE" <<JSON
{
  "permissions": {
    "allow": [$ALLOW_RULES],
    "deny": []
  }
}
JSON
    _green "  ✓ Wrote $CLAUDE_SETTINGS_FILE"
    _yellow "  Edit that file anytime to adjust what Claude can do in this project."
  fi

  if [[ "$AGENT" == "codex" ]]; then
    # Sandbox level prompt — kept at top level, not nested, to avoid capture bugs.
    echo ""
    _bold "  Sandbox level for Codex${PROJECT_PATH:+ in $PROJECT_PATH}"
    echo "    1) workspace-write    — read & write project files (recommended)"
    echo "    2) read-only          — read files only, no writes or commands"
    echo "    3) danger-full-access — no sandbox restrictions (dangerous)"
    _ask "  Choice [1/2/3] (default: 1):"
    read -r SANDBOX_LEVEL
    SANDBOX_LEVEL="${SANDBOX_LEVEL:-1}"
    case "$SANDBOX_LEVEL" in
      2) CODEX_SANDBOX=read-only;          CODEX_TRUST=untrusted ;;
      3) CODEX_SANDBOX=danger-full-access; CODEX_TRUST=trusted   ;;
      *) CODEX_SANDBOX=workspace-write;    CODEX_TRUST=trusted   ;;
    esac

    # Update ~/.codex/config.toml for this project path (if it exists).
    if [[ -n "$PROJECT_PATH" && -d "$PROJECT_PATH" ]]; then
      mkdir -p "$HOME/.codex"
      CODEX_CFG="$HOME/.codex/config.toml"
      CODEX_SECTION="[projects.\"$PROJECT_PATH\"]"
      [[ -f "$CODEX_CFG" ]] || touch "$CODEX_CFG"
      if grep -qF "$CODEX_SECTION" "$CODEX_CFG" 2>/dev/null; then
        awk -v sec="$CODEX_SECTION" -v trust="$CODEX_TRUST" \
          '$0==sec{in_sec=1;found=0;print;next}
           /^\[/{if(in_sec&&!found)print "trust_level = \""trust"\"";in_sec=0}
           in_sec&&/^trust_level[[:space:]]*=/{print "trust_level = \""trust"\"";found=1;next}
           {print}
           END{if(in_sec&&!found)print "trust_level = \""trust"\""}' \
          "$CODEX_CFG" > "$CODEX_CFG.tmp" && mv "$CODEX_CFG.tmp" "$CODEX_CFG"
      else
        printf '\n%s\ntrust_level = "%s"\n' "$CODEX_SECTION" "$CODEX_TRUST" >> "$CODEX_CFG"
      fi
      _green "  ✓ Set trust_level=$CODEX_TRUST for $PROJECT_PATH in ~/.codex/config.toml"
    fi
    _yellow "  Sandbox: $CODEX_SANDBOX — edit ~/.codex/config.toml anytime to adjust."
  fi

  ENTRY="${CHANNEL_ID}:${AGENT}"
  [[ -n "$PROJECT_PATH" ]] && ENTRY="${ENTRY}:${PROJECT_PATH}"
  [[ -n "$CODEX_SANDBOX" ]] && ENTRY="${ENTRY}:${CODEX_SANDBOX}"
  CHANNELS+=("$ENTRY")
  _green "  Added: $CHANNEL_ID → $AGENT${PROJECT_PATH:+ @ $PROJECT_PATH}${CODEX_SANDBOX:+ [$CODEX_SANDBOX]}"
done

[[ ${#CHANNELS[@]} -gt 0 ]] || { _red "No channels configured. Exiting."; exit 1; }

# ── 3. Settings ───────────────────────────────────────────────────────────────
echo ""
_bold "Step 3 — Settings"

_ask "Poll interval in seconds (default: 5):"
read -r POLL_INTERVAL; POLL_INTERVAL="${POLL_INTERVAL:-5}"

# ── 4. Write config ───────────────────────────────────────────────────────────
echo ""
_yellow "Writing config to $CONFIG_FILE..."

{
  echo "# Agent Discord Streamer config — generated $(date)"
  echo "BOT_ID=\"$BOT_ID\""
  echo "POLL_INTERVAL=$POLL_INTERVAL"
  echo ""
  echo "# CHANNELS: each entry is CHANNEL_ID:agent[:project_path]"
  echo "CHANNELS=("
  for ch in "${CHANNELS[@]}"; do
    echo "  \"$ch\""
  done
  echo ")"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
_green "✓ Config written."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
_bold "═══════════════════════════════════════════"
_green "Setup complete!"
echo ""
echo "Token:   $TOKEN_FILE"
echo "Config:  $CONFIG_FILE"
echo "Log:     $CONFIG_DIR/daemon.log"
echo ""
echo "Commands:"
echo "  Start daemon:   bash $SCRIPT_DIR/daemon.sh"
echo "  Process once:   bash $SCRIPT_DIR/daemon.sh --once"
echo "  Test API:       bash $SCRIPT_DIR/api.sh me"
echo ""
echo "Add a channel later by re-running this wizard or editing $CONFIG_FILE"
_bold "═══════════════════════════════════════════"
echo ""

#!/usr/bin/env bash
# Agent Discord Streamer — update wizard.
#
# Lets you update individual settings without re-running the full init wizard:
#   1) Bot token
#   2) Add channel
#   3) Remove channel
#   4) Update channel permissions
#   5) Poll interval

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

[[ -f "$CONFIG_FILE" ]] || {
  _red "Config not found: $CONFIG_FILE — run scripts/init.sh first."
  exit 1
}

# Load current config
# shellcheck source=/dev/null
source "$CONFIG_FILE"
CHANNELS=("${CHANNELS[@]:-}")
POLL_INTERVAL="${POLL_INTERVAL:-5}"
BOT_ID="${BOT_ID:-}"

# ── helpers ───────────────────────────────────────────────────────────────────

parse_channel() {
  # Sets CH_ID, CH_AGENT, CH_PATH, CH_SANDBOX
  IFS=: read -r CH_ID CH_AGENT CH_PATH CH_SANDBOX <<< "$1"
  CH_PATH="${CH_PATH:-}"
  CH_SANDBOX="${CH_SANDBOX:-}"
}

write_config() {
  {
    echo "# Agent Discord Streamer config — updated $(date)"
    echo "BOT_ID=\"$BOT_ID\""
    echo "POLL_INTERVAL=$POLL_INTERVAL"
    echo ""
    echo "# CHANNELS: each entry is CHANNEL_ID:agent[:project_path[:codex_sandbox]]"
    echo "CHANNELS=("
    for ch in "${CHANNELS[@]}"; do
      echo "  \"$ch\""
    done
    echo ")"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  _green "✓ Config saved to $CONFIG_FILE"
}

_bot_token() {
  [[ -f "$TOKEN_FILE" ]] || { echo ""; return; }
  cat "$TOKEN_FILE"
}

_validate_token() {
  local token="$1"
  local me_json
  me_json=$(curl -sS \
    -H "Authorization: Bot $token" \
    -H "User-Agent: agent-discord-streamer/1.0" \
    "https://discord.com/api/v10/users/@me") || return 1
  local username; username=$(echo "$me_json" | jq -r '.username // empty' 2>/dev/null)
  local id;       id=$(echo "$me_json" | jq -r '.id // empty' 2>/dev/null)
  [[ -n "$username" ]] || return 1
  echo "$username:$id"
}

_write_claude_permissions() {
  local project_path="$1"
  local claude_settings_dir="$project_path/.claude"
  local claude_settings_file="$claude_settings_dir/settings.json"
  mkdir -p "$claude_settings_dir"

  echo ""
  _bold "  Permissions for Claude in $project_path"
  echo "  Read and Edit/Write are always allowed."
  echo "  Choose Bash access level:"
  echo "    1) Full  — Bash(*) — all shell commands"
  echo "    2) Dev   — git, npm/yarn/pnpm, make, pytest, cargo, go (recommended)"
  echo "    3) Git   — git commands only"
  echo "    4) None  — no shell commands"
  _ask "  Choice [1/2/3/4] (default: 2):"
  read -r BASH_LEVEL
  BASH_LEVEL="${BASH_LEVEL:-2}"

  local bash_rules allow_rules
  case "$BASH_LEVEL" in
    1) bash_rules='"Bash(*)"' ;;
    3) bash_rules='"Bash(git *)"' ;;
    4) bash_rules='' ;;
    *) bash_rules='"Bash(git *)", "Bash(npm *)", "Bash(yarn *)", "Bash(pnpm *)", "Bash(make *)", "Bash(pytest *)", "Bash(cargo *)", "Bash(go *)"' ;;
  esac

  allow_rules='"Read(*)", "Edit(*)", "Write(*)"'
  [[ -n "$bash_rules" ]] && allow_rules="$allow_rules, $bash_rules"

  cat > "$claude_settings_file" <<JSON
{
  "permissions": {
    "allow": [$allow_rules],
    "deny": []
  }
}
JSON
  _green "  ✓ Wrote $claude_settings_file"
}

_write_codex_permissions() {
  local project_path="$1"
  echo ""
  _bold "  Permissions for Codex in $project_path"
  echo "  Choose sandbox level:"
  echo "    1) workspace-write    — read & write project files (recommended)"
  echo "    2) read-only          — read files only, no writes or commands"
  echo "    3) danger-full-access — no sandbox restrictions (dangerous)"
  _ask "  Choice [1/2/3] (default: 1):"
  read -r SANDBOX_LEVEL
  SANDBOX_LEVEL="${SANDBOX_LEVEL:-1}"

  local codex_sandbox codex_trust
  case "$SANDBOX_LEVEL" in
    2) codex_sandbox=read-only;         codex_trust=untrusted ;;
    3) codex_sandbox=danger-full-access; codex_trust=trusted   ;;
    *) codex_sandbox=workspace-write;   codex_trust=trusted    ;;
  esac

  mkdir -p "$HOME/.codex"
  local codex_config="$HOME/.codex/config.toml"
  local section; section="[projects.\"$project_path\"]"
  [[ -f "$codex_config" ]] || touch "$codex_config"

  if grep -qF "$section" "$codex_config" 2>/dev/null; then
    awk -v sec="$section" -v trust="$codex_trust" '
      $0 == sec       { in_sec=1; found=0; print; next }
      /^\[/           { if (in_sec && !found) print "trust_level = \"" trust "\""; in_sec=0 }
      in_sec && /^trust_level[[:space:]]*=/ { print "trust_level = \"" trust "\""; found=1; next }
      { print }
      END             { if (in_sec && !found) print "trust_level = \"" trust "\"" }
    ' "$codex_config" > "${codex_config}.tmp" && mv "${codex_config}.tmp" "$codex_config"
  else
    printf '\n%s\ntrust_level = "%s"\n' "$section" "$codex_trust" >> "$codex_config"
  fi
  _green "  ✓ Set trust_level=$codex_trust for $project_path in ~/.codex/config.toml"
  echo "$codex_sandbox"
}

# ── actions ───────────────────────────────────────────────────────────────────

do_update_token() {
  echo ""
  _bold "Update Bot Token"
  _ask "Paste new Discord bot token (input hidden):"
  read -rs NEW_TOKEN; echo ""
  [[ -n "$NEW_TOKEN" ]] || { _red "Token cannot be empty."; return; }

  _yellow "Validating token..."
  local result; result=$(_validate_token "$NEW_TOKEN") || {
    _red "Token validation failed — token not saved."
    return
  }
  local new_username="${result%%:*}"
  local new_id="${result#*:}"
  _green "✓ Authenticated as: $new_username (ID: $new_id)"

  printf '%s' "$NEW_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"

  # Update BOT_ID in config if it changed
  if [[ "$new_id" != "$BOT_ID" ]]; then
    BOT_ID="$new_id"
    write_config
  fi
  _green "✓ Token updated."
}

do_add_channel() {
  local bot_token; bot_token=$(_bot_token)
  [[ -n "$bot_token" ]] || { _red "Token not found — run init.sh first."; return; }

  echo ""
  _bold "Add Channel"
  _ask "Channel ID:"
  read -r CHANNEL_ID
  [[ -z "$CHANNEL_ID" ]] && { _yellow "Cancelled."; return; }
  [[ "$CHANNEL_ID" =~ ^[0-9]+$ ]] || { _red "Invalid channel ID (should be numeric)."; return; }

  # Check if already configured
  for existing in "${CHANNELS[@]}"; do
    parse_channel "$existing"
    if [[ "$CH_ID" == "$CHANNEL_ID" ]]; then
      _yellow "Channel $CHANNEL_ID is already configured (as $CH_AGENT). Remove it first to re-add."
      return
    fi
  done

  _yellow "Checking access to channel $CHANNEL_ID..."
  local chan_json; chan_json=$(curl -sS \
    -H "Authorization: Bot $bot_token" \
    -H "User-Agent: agent-discord-streamer/1.0" \
    "https://discord.com/api/v10/channels/$CHANNEL_ID") || true
  local chan_name; chan_name=$(echo "$chan_json" | jq -r '.name // empty' 2>/dev/null || echo "")
  if [[ -n "$chan_name" ]]; then
    _green "  ✓ #$chan_name"
  else
    _yellow "  Could not verify — make sure the bot is in this server with View Channel + Send Messages."
  fi

  _ask "  AI agent [claude/codex] (default: claude):"
  read -r AGENT; AGENT="${AGENT:-claude}"
  [[ "$AGENT" == "claude" || "$AGENT" == "codex" ]] || { _yellow "Unknown agent, defaulting to claude."; AGENT=claude; }

  _ask "  Project path (absolute path, blank to skip):"
  read -r PROJECT_PATH
  if [[ -n "$PROJECT_PATH" && ! -d "$PROJECT_PATH" ]]; then
    _yellow "  Warning: path does not exist yet: $PROJECT_PATH"
  fi

  local codex_sandbox=""
  if [[ -n "$PROJECT_PATH" && -d "$PROJECT_PATH" ]]; then
    if [[ "$AGENT" == "claude" ]]; then
      _write_claude_permissions "$PROJECT_PATH"
    elif [[ "$AGENT" == "codex" ]]; then
      codex_sandbox=$(_write_codex_permissions "$PROJECT_PATH")
    fi
  fi

  local entry="${CHANNEL_ID}:${AGENT}"
  [[ -n "$PROJECT_PATH" ]]   && entry="${entry}:${PROJECT_PATH}"
  [[ -n "$codex_sandbox" ]]  && entry="${entry}:${codex_sandbox}"
  CHANNELS+=("$entry")

  write_config
  _green "✓ Added: $CHANNEL_ID → $AGENT${PROJECT_PATH:+ @ $PROJECT_PATH}${codex_sandbox:+ [$codex_sandbox]}"
}

do_remove_channel() {
  echo ""
  _bold "Remove Channel"
  if [[ ${#CHANNELS[@]} -eq 0 ]]; then
    _yellow "No channels configured."
    return
  fi

  echo "Configured channels:"
  local i=1
  for ch in "${CHANNELS[@]}"; do
    parse_channel "$ch"
    printf "  %d) %s → %s%s%s\n" "$i" "$CH_ID" "$CH_AGENT" \
      "${CH_PATH:+ @ $CH_PATH}" "${CH_SANDBOX:+ [$CH_SANDBOX]}"
    (( i++ ))
  done

  _ask "Enter number to remove (blank to cancel):"
  read -r CHOICE
  [[ -z "$CHOICE" ]] && { _yellow "Cancelled."; return; }
  [[ "$CHOICE" =~ ^[0-9]+$ && "$CHOICE" -ge 1 && "$CHOICE" -le "${#CHANNELS[@]}" ]] || {
    _red "Invalid choice."; return
  }

  local idx=$(( CHOICE - 1 ))
  parse_channel "${CHANNELS[$idx]}"
  local removed_id="$CH_ID"

  # Rebuild array without the chosen entry
  local new_channels=()
  for (( j=0; j<${#CHANNELS[@]}; j++ )); do
    [[ "$j" -ne "$idx" ]] && new_channels+=("${CHANNELS[$j]}")
  done
  CHANNELS=("${new_channels[@]}")

  write_config
  _green "✓ Removed channel $removed_id."
}

do_update_permissions() {
  echo ""
  _bold "Update Channel Permissions"

  # Only show channels that have a project path
  local eligible=()
  for ch in "${CHANNELS[@]}"; do
    parse_channel "$ch"
    [[ -n "$CH_PATH" ]] && eligible+=("$ch")
  done

  if [[ ${#eligible[@]} -eq 0 ]]; then
    _yellow "No channels with a project path configured."
    return
  fi

  echo "Channels with project paths:"
  local i=1
  for ch in "${eligible[@]}"; do
    parse_channel "$ch"
    printf "  %d) %s → %s @ %s\n" "$i" "$CH_ID" "$CH_AGENT" "$CH_PATH"
    (( i++ ))
  done

  _ask "Enter number to update (blank to cancel):"
  read -r CHOICE
  [[ -z "$CHOICE" ]] && { _yellow "Cancelled."; return; }
  [[ "$CHOICE" =~ ^[0-9]+$ && "$CHOICE" -ge 1 && "$CHOICE" -le "${#eligible[@]}" ]] || {
    _red "Invalid choice."; return
  }

  parse_channel "${eligible[$(( CHOICE - 1 ))]}"
  local codex_sandbox="$CH_SANDBOX"

  if [[ "$CH_AGENT" == "claude" ]]; then
    _write_claude_permissions "$CH_PATH"
  elif [[ "$CH_AGENT" == "codex" ]]; then
    codex_sandbox=$(_write_codex_permissions "$CH_PATH")
    # Update sandbox value in the CHANNELS array
    local new_channels=()
    for ch in "${CHANNELS[@]}"; do
      parse_channel "$ch"
      if [[ "$CH_ID" == "${eligible[$(( CHOICE - 1 ))]%%:*}" && -n "$CH_PATH" ]]; then
        local entry="${CH_ID}:${CH_AGENT}:${CH_PATH}:${codex_sandbox}"
        new_channels+=("$entry")
      else
        new_channels+=("$ch")
      fi
    done
    CHANNELS=("${new_channels[@]}")
    write_config
  fi
}

do_update_poll_interval() {
  echo ""
  _bold "Update Poll Interval"
  echo "  Current: ${POLL_INTERVAL}s"
  _ask "New poll interval in seconds (blank to cancel):"
  read -r NEW_INTERVAL
  [[ -z "$NEW_INTERVAL" ]] && { _yellow "Cancelled."; return; }
  [[ "$NEW_INTERVAL" =~ ^[0-9]+$ && "$NEW_INTERVAL" -ge 1 ]] || {
    _red "Invalid interval — must be a positive integer."; return
  }
  POLL_INTERVAL="$NEW_INTERVAL"
  write_config
  _green "✓ Poll interval updated to ${POLL_INTERVAL}s."
}

# ── main menu ─────────────────────────────────────────────────────────────────

echo ""
_bold "╔══════════════════════════════════════╗"
_bold "║  Agent Discord Streamer — Update     ║"
_bold "╚══════════════════════════════════════╝"
echo ""
echo "Config: $CONFIG_FILE"
echo "Bot ID: ${BOT_ID:-unknown}"
echo "Channels: ${#CHANNELS[@]}"
echo ""

while true; do
  _bold "What would you like to update?"
  echo "  1) Bot token"
  echo "  2) Add channel"
  echo "  3) Remove channel"
  echo "  4) Update channel permissions"
  echo "  5) Poll interval"
  echo "  6) Exit"
  echo ""
  _ask "Choice [1-6]:"
  read -r MENU_CHOICE

  case "$MENU_CHOICE" in
    1) do_update_token ;;
    2) do_add_channel ;;
    3) do_remove_channel ;;
    4) do_update_permissions ;;
    5) do_update_poll_interval ;;
    6|"") echo ""; _green "Done."; exit 0 ;;
    *) _yellow "Invalid choice." ;;
  esac
  echo ""
done

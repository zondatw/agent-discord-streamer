#!/usr/bin/env bash
# Agent Discord Streamer daemon — polls Discord channels and routes messages to AI agents.
# Each channel maintains an independent agent session; conversation memory is held
# by the agent, not rebuilt from Discord history.
#
# Usage: daemon.sh [--config FILE] [--once]
#   --config FILE   path to config (default: ~/.config/agent-discord-streamer/config)
#   --once          process pending messages once then exit (useful for cron/hooks)

set -euo pipefail

SCRIPT_DIR="${AGENT_DISCORD_STREAMER_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONFIG_DIR="$HOME/.config/agent-discord-streamer"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_DIR="$CONFIG_DIR/state"       # last-seen message ID per channel
SESSION_DIR="$CONFIG_DIR/sessions"  # agent session ID per channel
LOG_FILE="$CONFIG_DIR/daemon.log"
ONCE=false

# --- arg parse ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --once)   ONCE=true; shift ;;
    -h|--help)
      echo "Usage: daemon.sh [--config FILE] [--once]"
      exit 0 ;;
    *) echo "error: unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || {
  echo "error: config not found: $CONFIG_FILE — run scripts/init.sh first" >&2; exit 1
}

# shellcheck source=/dev/null
source "$CONFIG_FILE"

POLL_INTERVAL="${POLL_INTERVAL:-5}"

mkdir -p "$STATE_DIR" "$SESSION_DIR"

# Unset token env so AI subprocesses never inherit it
unset DISCORD_BOT_TOKEN 2>/dev/null || true

LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"  # 5 MB default
LOG_BACKUPS="${LOG_BACKUPS:-3}"

rotate_log() {
  [[ -f "$LOG_FILE" ]] || return
  local size; size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  (( size < LOG_MAX_BYTES )) && return
  local i
  for (( i=LOG_BACKUPS-1; i>=1; i-- )); do
    [[ -f "${LOG_FILE}.${i}" ]] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i+1))"
  done
  mv "$LOG_FILE" "${LOG_FILE}.1"
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# --- state helpers ---
state_file()   { echo "$STATE_DIR/${1}.last_id"; }
session_file() { echo "$SESSION_DIR/${1}.session"; }

get_last_id() {
  local f; f=$(state_file "$1")
  [[ -f "$f" ]] && cat "$f" || echo ""
}

set_last_id() {
  local f; f=$(state_file "$1")
  echo "$2" > "$f"
}

# --- build prompt ---
# First message to a channel: include a brief system context so the agent
# knows the environment. Subsequent messages go straight through — the
# agent session already holds the conversation memory.
build_prompt() {
  local channel_id="$1" author="$2" content="$3"
  local session_f; session_f=$(session_file "$channel_id")

  if [[ ! -s "$session_f" ]]; then
    # Fresh session — set context once
    printf 'You are an AI assistant integrated into a Discord channel.\n'
    printf 'Reply concisely in plain text.\n\n'
  fi

  printf '[%s]: %s\n' "$author" "$content"
}

# --- process one message ---
process_message() {
  local channel_id="$1" msg_id="$2" author="$3" content="$4" agent="$5" project_path="${6:-}"

  log "[$channel_id] [$agent] $author: ${content:0:80}"

  local prompt_file session_f
  prompt_file=$(mktemp /tmp/agent-discord-streamer.XXXXXX)
  session_f=$(session_file "$channel_id")
  # shellcheck disable=SC2064
  trap "rm -f '$prompt_file'" RETURN

  build_prompt "$channel_id" "$author" "$content" > "$prompt_file"

  local response
  if response=$("$SCRIPT_DIR/dispatch.sh" "$agent" "$session_f" "$prompt_file" "$project_path" 2>>"$LOG_FILE"); then
    [[ -n "$response" ]] || response="(no response)"
    "$SCRIPT_DIR/api.sh" send_chunked "$channel_id" "$response" "$msg_id" >>"$LOG_FILE" 2>&1
    log "[$channel_id] reply sent (${#response} chars)"
  else
    log "[$channel_id] dispatch failed for msg $msg_id"
    "$SCRIPT_DIR/api.sh" send "$channel_id" \
      "⚠️ AI agent error — check daemon log." "$msg_id" >>"$LOG_FILE" 2>&1 || true
  fi
}

# --- poll one channel ---
poll_channel() {
  local channel_id="$1" agent="$2" project_path="${3:-}"
  local last_id; last_id=$(get_last_id "$channel_id")

  # First run: record current position — don't replay history
  if [[ -z "$last_id" ]]; then
    local newest
    newest=$("$SCRIPT_DIR/api.sh" fetch "$channel_id" "" "1" 2>/dev/null || echo "[]")
    local newest_id; newest_id=$(echo "$newest" | jq -r '.[0].id // empty' 2>/dev/null || echo "")
    set_last_id "$channel_id" "${newest_id:-0}"
    log "[$channel_id] initialized at message ${newest_id:-(empty channel)}"
    return
  fi

  # Fetch messages after last seen ID
  local msgs
  msgs=$("$SCRIPT_DIR/api.sh" fetch "$channel_id" "$last_id" "20" 2>/dev/null || echo "[]")

  # Sort ascending (oldest first), skip bot messages and empty content
  local new_msgs
  new_msgs=$(echo "$msgs" | jq -c '
    sort_by(.id) |
    .[] |
    select(.author.bot != true and (.content | length) > 0)
  ' 2>/dev/null || echo "")

  local new_last_id="$last_id"

  while IFS= read -r msg; do
    [[ -z "$msg" ]] && continue
    local msg_id author content
    msg_id=$(echo "$msg" | jq -r '.id')
    author=$(echo "$msg" | jq -r '.author.username')
    content=$(echo "$msg" | jq -r '.content')
    new_last_id="$msg_id"
    process_message "$channel_id" "$msg_id" "$author" "$content" "$agent" "$project_path"
  done <<< "$new_msgs"

  [[ "$new_last_id" != "$last_id" ]] && set_last_id "$channel_id" "$new_last_id"
}

# --- main loop ---
parse_channel() {
  # Sets CH_ID, CH_AGENT, CH_PATH from a CHANNEL_ID:AGENT[:PROJECT_PATH] entry
  IFS=: read -r CH_ID CH_AGENT CH_PATH <<< "$1"
  CH_PATH="${CH_PATH:-}"
}

log "Agent Discord Streamer daemon starting (poll=${POLL_INTERVAL}s, channels=${#CHANNELS[@]})"
for ch_entry in "${CHANNELS[@]}"; do
  parse_channel "$ch_entry"
  log "  watching #$CH_ID → $CH_AGENT${CH_PATH:+ @ $CH_PATH}"
done

if [[ "$ONCE" == true ]]; then
  for ch_entry in "${CHANNELS[@]}"; do
    parse_channel "$ch_entry"
    poll_channel "$CH_ID" "$CH_AGENT" "$CH_PATH"
  done
  exit 0
fi

trap 'log "Daemon stopped."; exit 0' SIGTERM SIGINT

while true; do
  rotate_log
  for ch_entry in "${CHANNELS[@]}"; do
    parse_channel "$ch_entry"
    poll_channel "$CH_ID" "$CH_AGENT" "$CH_PATH" || log "poll error for $ch_entry"
  done
  sleep "$POLL_INTERVAL"
done

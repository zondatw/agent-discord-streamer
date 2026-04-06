#!/usr/bin/env bash
# Dispatch a message to an AI agent with persistent session per channel.
# DISCORD_BOT_TOKEN is intentionally never exported — AI processes run clean.
#
# Usage: dispatch.sh AGENT SESSION_FILE PROMPT_FILE [PROJECT_PATH]
#
#   AGENT        : claude | codex
#   SESSION_FILE : path where the session ID is stored between calls
#                  (created on first call, reused on subsequent calls)
#   PROMPT_FILE  : file containing the message to send
#   PROJECT_PATH : working directory for the agent (optional)
#                  Claude will read/write files relative to this path

set -euo pipefail

AGENT="${1:-claude}"
SESSION_FILE="${2:-}"
PROMPT_FILE="${3:-}"
PROJECT_PATH="${4:-}"

[[ -n "$SESSION_FILE" ]] || { echo "error: SESSION_FILE required" >&2; exit 1; }
[[ -f "$PROMPT_FILE" ]]  || { echo "error: prompt file not found: $PROMPT_FILE" >&2; exit 1; }

# Strip Discord credentials before invoking AI
unset DISCORD_BOT_TOKEN AGENT_DISCORD_STREAMER_TOKEN_FILE 2>/dev/null || true

# Move into the project directory so Claude operates on the right codebase
if [[ -n "$PROJECT_PATH" ]]; then
  [[ -d "$PROJECT_PATH" ]] || { echo "error: project path not found: $PROJECT_PATH" >&2; exit 1; }
  cd "$PROJECT_PATH"
fi

PROMPT=$(< "$PROMPT_FILE")

case "$AGENT" in
  claude)
    CLAUDE_BIN=$(command -v claude 2>/dev/null) || {
      echo "error: claude CLI not found in PATH" >&2; exit 1
    }

    ARGS=(--print --output-format json)

    # Resume existing session if one is stored for this channel
    if [[ -s "$SESSION_FILE" ]]; then
      STORED_SESSION=$(< "$SESSION_FILE")
      ARGS+=(--resume "$STORED_SESSION")
    fi

    # Run claude and capture full JSON output; stderr flows to caller (daemon logs it)
    RAW=$("$CLAUDE_BIN" "${ARGS[@]}" "$PROMPT")

    # Extract human-readable response text
    RESPONSE=$(echo "$RAW" | jq -r '.result // empty' 2>/dev/null)
    # Fallback: if output-format json isn't supported, RAW is plain text
    [[ -z "$RESPONSE" ]] && RESPONSE="$RAW"

    # Persist session ID for next message in this channel
    NEW_SESSION=$(echo "$RAW" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    [[ -n "$NEW_SESSION" ]] && echo "$NEW_SESSION" > "$SESSION_FILE"

    printf '%s' "$RESPONSE"
    ;;

  codex)
    CODEX_BIN=$(command -v codex 2>/dev/null) || {
      echo "error: codex CLI not found in PATH" >&2; exit 1
    }
    # --full-auto required — interactive mode would hang the daemon
    "$CODEX_BIN" --full-auto "$PROMPT"
    ;;

  *)
    echo "error: unknown agent '$AGENT' — use 'claude' or 'codex'" >&2
    exit 1
    ;;
esac

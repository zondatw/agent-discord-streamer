#!/usr/bin/env bash
# Discord REST API wrapper.
# Token is read from ~/.config/discord-streamer/.token — never from env,
# so AI subprocesses never inherit it.

set -euo pipefail

API_BASE="${DISCORD_API_BASE:-https://discord.com/api/v10}"
TOKEN_FILE="${DISCORD_STREAMER_TOKEN_FILE:-$HOME/.config/discord-streamer/.token}"
DISCORD_MAX_LEN=1990

_fail() { echo "error: $*" >&2; exit 1; }

_token() {
  [[ -f "$TOKEN_FILE" ]] || _fail "token not found at $TOKEN_FILE — run scripts/init.sh first"
  local t; t=$(< "$TOKEN_FILE"); [[ -n "$t" ]] || _fail "token file is empty"
  printf '%s' "$t"
}

_req() {
  local method="$1" path="$2" payload="${3:-}"
  local token; token=$(_token)
  local args=(-sS -w $'\n%{http_code}'
    -X "$method"
    -H "Authorization: Bot $token"
    -H "User-Agent: discord-streamer/1.0")
  [[ -n "$payload" ]] && args+=(-H "Content-Type: application/json" --data "$payload")
  local raw; raw=$(curl "${args[@]}" "$API_BASE$path")
  local code="${raw##*$'\n'}" body="${raw%$'\n'*}"
  [[ "$code" =~ ^2 ]] || _fail "Discord API $method $path → $code: $body"
  printf '%s' "$body"
}

_json_esc() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- public commands ---

cmd_me() { _req GET "/users/@me"; }

cmd_fetch() {
  # fetch CHANNEL_ID [AFTER_ID] [LIMIT=20]
  local channel_id="$1" after="${2:-}" limit="${3:-20}"
  local q="limit=$limit"; [[ -n "$after" ]] && q="${q}&after=$after"
  _req GET "/channels/$channel_id/messages?$q"
}

cmd_send() {
  # send CHANNEL_ID CONTENT [REPLY_TO_ID]
  local channel_id="$1" content="$2" reply_to="${3:-}"
  local escaped; escaped=$(_json_esc "$content")
  local payload="{\"content\":\"$escaped\",\"allowed_mentions\":{\"parse\":[]}}"
  [[ -n "$reply_to" ]] && \
    payload="{\"content\":\"$escaped\",\"message_reference\":{\"message_id\":\"$reply_to\"},\"allowed_mentions\":{\"parse\":[]}}"
  _req POST "/channels/$channel_id/messages" "$payload"
}

cmd_send_chunked() {
  # send_chunked CHANNEL_ID CONTENT [REPLY_TO_ID]
  local channel_id="$1" content="$2" reply_to="${3:-}"
  local first=true
  while [[ ${#content} -gt 0 ]]; do
    local chunk="${content:0:$DISCORD_MAX_LEN}"
    content="${content:$DISCORD_MAX_LEN}"
    if [[ "$first" == true ]]; then
      cmd_send "$channel_id" "$chunk" "$reply_to"
      first=false
    else
      cmd_send "$channel_id" "$chunk"
    fi
  done
}

# --- dispatch ---
case "${1:-}" in
  me)           cmd_me ;;
  fetch)        cmd_fetch "$2" "${3:-}" "${4:-20}" ;;
  send)         cmd_send "$2" "${3:-}" "${4:-}" ;;
  send_chunked) cmd_send_chunked "$2" "${3:-}" "${4:-}" ;;
  *) echo "Usage: api.sh me | fetch CHANNEL [AFTER] [LIMIT] | send CHANNEL TEXT [REPLY_TO] | send_chunked CHANNEL TEXT [REPLY_TO]" >&2; exit 1 ;;
esac

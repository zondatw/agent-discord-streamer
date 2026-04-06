#!/usr/bin/env bash
# Integration test — hits the real Discord API.
#
# Prerequisites:
#   1. Run scripts/init.sh at least once (sets up token + config)
#   2. Set DISCORD_TEST_CHANNEL_ID to a channel the bot can read/write
#
# Usage:
#   DISCORD_TEST_CHANNEL_ID=123456789 bash test/test.sh
#   bash test/test.sh 123456789

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
API="$SCRIPTS_DIR/api.sh"
DISPATCH="$SCRIPTS_DIR/dispatch.sh"
DAEMON="$SCRIPTS_DIR/daemon.sh"

CHANNEL_ID="${DISCORD_TEST_CHANNEL_ID:-${1:-}}"

# ── helpers ───────────────────────────────────────────────────────────────────

PASS=0; FAIL=0
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS+1)); green "  ✓ $*"; }
fail() { FAIL=$((FAIL+1)); red   "  ✗ $*"; }

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then pass "$label"; else
    fail "$label"
    echo "    expected to contain: $needle"
    echo "    got: ${haystack:0:300}"
  fi
}

# ── preflight ─────────────────────────────────────────────────────────────────

bold "=== agent-discord-streamer integration test ==="
echo ""

TOKEN_FILE="${AGENT_DISCORD_STREAMER_TOKEN_FILE:-$HOME/.config/agent-discord-streamer/.token}"
CONFIG_FILE="$HOME/.config/agent-discord-streamer/config"

[[ -f "$TOKEN_FILE" ]] || {
  red "Token file not found: $TOKEN_FILE"
  echo "Run scripts/init.sh first."
  exit 1
}

[[ -n "$CHANNEL_ID" ]] || {
  red "DISCORD_TEST_CHANNEL_ID not set."
  echo "Usage: DISCORD_TEST_CHANNEL_ID=<id> bash test/test.sh"
  exit 1
}

yellow "Token file : $TOKEN_FILE"
yellow "Channel ID : $CHANNEL_ID"
echo ""

# ── 1. Bot identity ───────────────────────────────────────────────────────────

bold "1. Bot identity"
result=$(bash "$API" me)
assert_contains "GET /users/@me succeeds"  "$result" '"username"'
assert_contains "response has bot id"      "$result" '"id"'
BOT_NAME=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['username'])" 2>/dev/null || echo "unknown")
echo "    bot: $BOT_NAME"

# ── 2. Fetch messages ─────────────────────────────────────────────────────────

echo ""
bold "2. Fetch messages"
result=$(bash "$API" fetch "$CHANNEL_ID" "" 5)
assert_contains "fetch returns JSON array" "$result" "["
MSG_COUNT=$(echo "$result" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
pass "fetched $MSG_COUNT message(s) from channel"

# ── 3. Send message ───────────────────────────────────────────────────────────

echo ""
bold "3. Send message"
TEST_CONTENT="agent-discord-streamer test $(date '+%H:%M:%S')"
result=$(bash "$API" send "$CHANNEL_ID" "$TEST_CONTENT")
assert_contains "send returns message object" "$result" '"id"'
SENT_ID=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
[[ -n "$SENT_ID" ]] && pass "message ID: $SENT_ID" || fail "could not parse sent message ID"

# ── 4. Sent message appears in fetch ─────────────────────────────────────────

echo ""
bold "4. Sent message visible in channel"
sleep 1  # give Discord a moment
result=$(bash "$API" fetch "$CHANNEL_ID" "" 5)
assert_contains "sent message appears in fetch" "$result" "$TEST_CONTENT"

# ── 5. dispatch.sh — claude responds ─────────────────────────────────────────

echo ""
bold "5. Claude dispatch"
if command -v claude >/dev/null 2>&1; then
  PROMPT_FILE=$(mktemp /tmp/agent-discord-streamer-test.XXXXXX)
  SESSION_FILE=$(mktemp /tmp/agent-discord-streamer-test-session.XXXXXX)
  echo "Reply with exactly the word: PONG" > "$PROMPT_FILE"
  response=$(bash "$DISPATCH" claude "$SESSION_FILE" "$PROMPT_FILE" 2>/dev/null || echo "")
  rm -f "$PROMPT_FILE" "$SESSION_FILE"
  if [[ -n "$response" ]]; then
    pass "claude returned a response"
    echo "    preview: ${response:0:120}"
  else
    fail "claude returned empty response"
  fi
else
  yellow "  claude not in PATH — skipped"
fi

# ── 6. daemon --once processes the channel ────────────────────────────────────

echo ""
bold "6. Daemon --once (one poll cycle)"
if [[ -f "$CONFIG_FILE" ]]; then
  # Check if test channel is in config; if not, run with a temp config
  if grep -q "$CHANNEL_ID" "$CONFIG_FILE" 2>/dev/null; then
    bash "$DAEMON" --once 2>&1 | tail -5
    pass "daemon --once completed without error"
  else
    TEMP_CONFIG=$(mktemp /tmp/agent-discord-streamer-test-config.XXXXXX)
    cat > "$TEMP_CONFIG" <<EOF
BOT_ID="$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")"
POLL_INTERVAL=5
HISTORY_LIMIT=10
CHANNELS=(
  "${CHANNEL_ID}:claude"
)
EOF
    bash "$DAEMON" --config "$TEMP_CONFIG" --once 2>&1 | tail -5
    pass "daemon --once completed without error"
    rm -f "$TEMP_CONFIG"
  fi
else
  yellow "  config not found ($CONFIG_FILE) — skipped. Run scripts/init.sh first."
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $FAIL -eq 0 ]]; then
  green "PASSED  ($PASS tests)"
else
  red "FAILED  ($PASS passed, $FAIL failed)"
fi
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $FAIL -eq 0 ]]

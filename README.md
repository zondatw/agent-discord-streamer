# agent-discord-streamer

A polling daemon that bridges Discord channels with AI agents (Claude & Codex).
Users send messages in a Discord channel; the bot replies with AI-generated responses.
Each channel maintains its own persistent agent session — conversation memory is held by the agent, not rebuilt from Discord history.

Built with `bash`, `curl`, and `jq` — no extra installs required beyond the AI CLIs.

## Features

- Chat with **Claude** or **Codex** directly from any Discord channel
- Each channel gets its own isolated agent session with persistent conversation memory
- Different channels can use different agents or point at different project directories
- Discord bot token is stored securely and **never exposed to AI agent processes**
- Replies are chunked automatically to fit Discord's 2000-character limit
- Log rotation built in (configurable size and backup count)
- Optional macOS LaunchAgent for automatic startup at login
- Single-shot mode for use with cron or Claude Code hooks

## Requirements

- macOS or Linux
- `bash`, `curl`, `jq`
- [`claude` CLI](https://github.com/anthropics/claude-code) — for Claude agent
- [`codex` CLI](https://github.com/openai/codex) — for Codex agent
- A Discord bot token with the following permissions:
  - View Channel
  - Read Message History
  - Send Messages

## Install

### 1. Clone or copy the skill

```bash
git clone <this-repo> ~/path/to/agent-discord-streamer
```

### 2. Run the setup wizard

```bash
bash scripts/init.sh
```

The wizard will:

1. Ask for your Discord bot token and store it at `~/.config/agent-discord-streamer/.token` (mode 600)
2. Validate the token against the Discord API and show your bot's username
3. Let you add channels and assign `claude` or `codex` to each
4. Optionally set a project directory per channel (Claude will `cd` there and can read/write files)
5. Generate a `.claude/settings.json` in each project directory with scoped tool permissions
6. Set the poll interval and write the config
7. Optionally install a macOS LaunchAgent so the daemon starts at login

### 3. Start the daemon

```bash
bash scripts/daemon.sh
```

The daemon runs in the foreground and logs to `~/.config/agent-discord-streamer/daemon.log`.
To run it in the background:

```bash
nohup bash scripts/daemon.sh &
```

## Discord Bot Setup

If you don't have a bot yet:

1. Go to [discord.com/developers/applications](https://discord.com/developers/applications) and create a new application
2. Under **Bot**, click **Add Bot** and copy the token
3. Under **OAuth2 → URL Generator**, select scopes `bot` and permissions:
   - Read Messages / View Channels
   - Read Message History
   - Send Messages
4. Open the generated URL in your browser and invite the bot to your server

## Usage

Once the daemon is running, send a message in any watched channel:

```
you: How do I reverse a string in Python?
```

The bot replies directly, threading back to your message. Conversation memory is maintained across messages — the agent session picks up where it left off.

### Single-shot mode (cron / hooks)

Process pending messages once and exit — useful for scheduled jobs or Claude Code hooks:

```bash
bash scripts/daemon.sh --once
```

### Test the API without starting the daemon

```bash
# Verify your token works
bash scripts/api.sh me

# Read the last 5 messages from a channel
bash scripts/api.sh fetch CHANNEL_ID "" 5

# Send a test message
bash scripts/api.sh send CHANNEL_ID "hello from the terminal"
```

## Configuration

Config lives at `~/.config/agent-discord-streamer/config` (sourced as bash, mode 600):

```bash
BOT_ID="123456789012345678"
POLL_INTERVAL=5       # seconds between polls

# Each entry: CHANNEL_ID:agent[:project_path]
CHANNELS=(
  "111222333444555666:claude"                        # Claude, no project
  "777888999000111222:codex"                         # Codex, no project
  "999111222333444555:claude:/path/to/my-project"   # Claude with project dir
)
```

To add a channel, append an entry to `CHANNELS` and restart the daemon.
To remove one, delete the entry and restart.

### Reset a channel's conversation position

To reprocess messages from now (clearing the "last seen" pointer):

```bash
rm ~/.config/agent-discord-streamer/state/CHANNEL_ID.last_id
```

To start a fresh agent session for a channel:

```bash
rm ~/.config/agent-discord-streamer/sessions/CHANNEL_ID.session
```

### Per-project Claude permissions

When you assign a project path to a Claude channel, `init.sh` writes
`.claude/settings.json` into that directory with explicit tool permissions:

```json
{
  "permissions": {
    "allow": ["Read(*)", "Edit(*)", "Write(*)", "Bash(git *)"],
    "deny": []
  }
}
```

Edit this file anytime to adjust what Claude can do in that project.

### Log rotation

The daemon rotates `daemon.log` when it exceeds a size threshold.
Override via config:

```bash
LOG_MAX_BYTES=5242880   # 5 MB (default)
LOG_BACKUPS=3           # number of rotated files to keep (default)
```

## How It Works

```
Discord channel
      │  (user message)
      ▼
  daemon.sh  ──poll every N seconds──▶  api.sh (fetch new messages)
      │
      │  (for each new message)
      ▼
  dispatch.sh
      ├── claude: claude --print --output-format json [--resume SESSION_ID]
      │           saves session_id → sessions/CHANNEL_ID.session
      │
      └── codex:  codex exec [resume SESSION_ID] --full-auto --json \
                      --output-last-message /tmp/...
                  saves session_id → sessions/CHANNEL_ID.session
      │
      ▼
  api.sh send_chunked  (reply, split at 2000 chars if needed)
```

Each channel's session ID is persisted between polls so the agent remembers the conversation.

## File Layout

```
agent-discord-streamer/
├── scripts/
│   ├── init.sh           Interactive setup wizard
│   ├── daemon.sh         Polling daemon (main entry point)
│   ├── api.sh            Discord REST API wrapper
│   └── dispatch.sh       Routes prompts to claude or codex
├── test/
│   ├── test.sh           Integration test (real Discord API, no mocks)
│   └── README.md         Test documentation
└── .gitignore
```

Runtime files (all in `~/.config/agent-discord-streamer/`, not in this repo):

```
~/.config/agent-discord-streamer/
├── .token                   Bot token (chmod 600)
├── config                   Channel and settings config (chmod 600)
├── daemon.log               Daemon output (rotated automatically)
├── state/
│   └── <channel_id>.last_id     Last processed message ID per channel
└── sessions/
    └── <channel_id>.session     Agent session ID per channel
```

## Security

- The bot token lives at `~/.config/agent-discord-streamer/.token` with mode `600`
- `daemon.sh` reads the token into a local variable and immediately `unset`s it before any AI subprocess runs
- `dispatch.sh` also explicitly unsets `DISCORD_BOT_TOKEN` and `AGENT_DISCORD_STREAMER_TOKEN_FILE`, so Claude and Codex processes start with a clean environment
- Config is `600`; the config directory is `700`

## Testing

```bash
DISCORD_TEST_CHANNEL_ID=123456789 bash test/test.sh
```

See [test/README.md](test/README.md) for details.

## Stop the Daemon

```bash
# Foreground: Ctrl+C

# Background:
pkill -f "daemon.sh"

# LaunchAgent:
launchctl unload ~/Library/LaunchAgents/com.agent-discord-streamer.plist
```

# agent-discord-streamer

A polling daemon that bridges Discord channels with AI agents (Claude & Codex).
Users send messages in a Discord channel; the bot replies with AI-generated responses.
Each channel maintains its own conversation context, and different channels can use different agents.

Built with `bash`, `curl`, and `jq` — no extra installs required.

## Features

- Chat with **Claude** or **Codex** directly from any Discord channel
- Each channel gets its own isolated AI context (built from the channel's message history)
- Discord bot token is stored securely and **never exposed to AI agent processes**
- Replies are chunked automatically to fit Discord's 2000-character limit
- Optional macOS LaunchAgent for automatic startup at login
- Single-shot mode for use with cron or Claude Code hooks

## Requirements

- macOS or Linux
- `bash`, `curl`, `jq`
- [`claude` CLI](https://github.com/anthropics/claude-code) for Claude agent
- [`codex` CLI](https://github.com/openai/codex) for Codex agent
- A Discord bot token with the following permissions:
  - View Channel
  - Read Message History
  - Send Messages

## Install

### 1. Clone or copy the skill

```bash
git clone <this-repo> ~/path/to/agent-discord-streamer
# or copy the folder anywhere you like
```

### 2. Run the setup wizard

```bash
bash scripts/init.sh
```

The wizard will:

1. Ask for your Discord bot token and store it at `~/.config/agent-discord-streamer/.token` (mode 600)
2. Validate the token against the Discord API and show your bot's username
3. Let you add channels and assign `claude` or `codex` to each
4. Set poll interval and conversation history depth
5. Optionally install a macOS LaunchAgent so the daemon starts at login
6. Link `skill.md` into `~/.claude/commands/` so `/agent-discord-streamer` works inside Claude Code

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
   - Read Messages/View Channels
   - Read Message History
   - Send Messages
4. Open the generated URL in your browser and invite the bot to your server

## Usage

Once the daemon is running, just send a message in any watched channel:

```
@you: How do I reverse a string in Python?
```

The bot replies directly, threading back to your message.

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

Config lives at `~/.config/agent-discord-streamer/config` and is sourced as bash:

```bash
BOT_ID="123456789012345678"
POLL_INTERVAL=5       # seconds between polls per channel
HISTORY_LIMIT=10      # messages included as conversation context

CHANNELS=(
  "111222333444555666:claude"   # this channel uses Claude
  "777888999000111222:codex"    # this channel uses Codex
)
```

### Add a channel

Append an entry to `CHANNELS` in the config file, then restart the daemon.

### Remove a channel

Delete the entry from `CHANNELS` and restart the daemon.

### Reset a channel's position

To reprocess messages from now (clearing the "last seen" pointer):

```bash
rm ~/.config/agent-discord-streamer/state/CHANNEL_ID.last_id
```

## File Layout

```
agent-discord-streamer/
├── skill.md              Claude Code skill (/agent-discord-streamer command)
├── scripts/
│   ├── init.sh           Interactive setup wizard
│   ├── daemon.sh         Polling daemon (main entry point)
│   ├── api.sh            Discord REST API wrapper
│   └── dispatch.sh       Dispatches prompts to claude or codex
└── .gitignore
```

Runtime files (all in `~/.config/agent-discord-streamer/`, not in this repo):

```
~/.config/agent-discord-streamer/
├── .token          Bot token (chmod 600)
├── config          Channel and settings config (chmod 600)
├── daemon.log      Daemon output
└── state/
    └── <channel_id>.last_id    Last processed message ID per channel
```

## Security

- The bot token is stored at `~/.config/agent-discord-streamer/.token` with permissions `600`
- `daemon.sh` reads the token into a local (non-exported) variable — it is never in the environment
- `dispatch.sh` explicitly unsets `DISCORD_BOT_TOKEN` before invoking AI, so Claude and Codex processes run without it
- Config is also `600`; the state directory is `700`

## Stop the Daemon

```bash
# Foreground: Ctrl+C

# Background:
pkill -f "daemon.sh"

# LaunchAgent:
launchctl unload ~/Library/LaunchAgents/com.agent-discord-streamer.plist
```

## Using as a Claude Code Skill

After init, `/agent-discord-streamer` is available inside Claude Code sessions:

```
/agent-discord-streamer
```

Claude will read `skill.md` and can help you manage channels, check status, debug issues, or restart the daemon.
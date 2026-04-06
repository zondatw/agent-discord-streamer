# Testing

Integration test that runs against a real Discord bot token and channel. No mocks.

## Prerequisites

1. Run `scripts/init.sh` to set up the token and config
2. Have a Discord channel the bot can read and write

## Run

```bash
DISCORD_TEST_CHANNEL_ID=123456789 bash test/test.sh
```

Or pass the channel ID as a positional argument:

```bash
bash test/test.sh 123456789
```

## What it tests

| # | What |
|---|------|
| 1 | Bot identity — `GET /users/@me` returns valid bot info |
| 2 | Fetch messages from the channel |
| 3 | Send a timestamped test message |
| 4 | Sent message appears in a subsequent fetch |
| 5 | `dispatch.sh` — claude receives a prompt and returns a response |
| 6 | `daemon.sh --once` completes one poll cycle without error |

Test 5 is skipped if `claude` is not in PATH.
Test 6 uses the existing config if the test channel is already in it, otherwise runs with a temporary single-channel config.

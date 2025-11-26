# Poor Man's Statusline

Lightweight custom statusline for Claude Code showing usage limits, model availability, and context window.

## Features

- Real-time API usage (5h and 7d limits)
- Per-model availability (Opus and Sonnet)
- Context window monitoring with auto-compact warning
- 1-minute smart caching
- Color-coded indicators (green/yellow/red)

## Example Output

```
[claude-sonnet-4-5-20250929] alex@hostname:project (main)
  Opus: 18% | Sonnet: 13%
  5h: 32% | 7d: 18%
  CTX: 98.8K 49%
```

## Prerequisites

- Claude Code (installed and authenticated)
- `jq` - JSON processor
- `curl` - HTTP client

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq
```

## Installation

```bash
# 1. Clone and copy script
git clone https://github.com/alexfazio/cc-poor-mans-statusline.git
cd cc-poor-mans-statusline
cp statusline.sh ~/.claude/
chmod +x ~/.claude/statusline.sh

# 2. Configure Claude Code to use ~/.claude/statusline.sh

# 3. Done! Your credentials at ~/.claude/.credentials.json are used automatically
```

## Customization

Edit `~/.claude/statusline.sh`:

```bash
CACHE_TTL=60  # API cache duration in seconds
CONTEXT_WINDOW=200000  # Model context window size
AUTO_COMPACT_THRESHOLD=160000  # Warning threshold (80%)
```

## Troubleshooting

**No usage data showing?**
- Verify credentials exist: `ls ~/.claude/.credentials.json`
- Test API manually: `curl -s -H "Authorization: Bearer $(jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)" -H "anthropic-beta: oauth-2025-04-20" "https://api.anthropic.com/api/oauth/usage" | jq .`

**Script running slowly?**
- Increase cache TTL: `CACHE_TTL=300`

**Context not showing?**
- Context only appears during active conversations

## Security

Never commit:
- `~/.claude/.credentials.json` (your OAuth token)
- `/tmp/claude-usage-cache.json` (usage data)
- Screenshots with personal info

The included `.gitignore` prevents accidental leaks.

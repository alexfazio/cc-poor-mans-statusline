# Poor Man's Statusline

Lightweight custom statusline for Claude Code showing usage limits, model availability, and context window.

## Features

- Real-time API usage (5-hour limit, 7-day limit for higher tiers)
- Per-model availability (Opus and Sonnet) - only shown when available
- Context window monitoring with auto-compact warning
- 1-minute smart caching
- Color-coded indicators (green/yellow/red)
- Automatically adapts to your Claude Pro tier (basic or higher)

## Example Output

**Claude Pro (higher tiers with 7-day limits):**
```
[claude-sonnet-4-5-20250929] alex@hostname:project (main)
  Opus: 18% | Sonnet: 13%
  5h: 32% | 7d: 18%
  CTX: 98.8K 49%
```

**Claude Pro (basic tier):**
```
[claude-sonnet-4-5-20250929] alex@hostname:project (main)
  5h: 44%
  CTX: 23.8K 11%
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
# 1. Clone the repository
git clone https://github.com/alexfazio/cc-poor-mans-statusline.git
cd cc-poor-mans-statusline

# 2. Make the script executable
chmod +x statusline.sh

# 3. Configure Claude Code
# Run the /statusline command in Claude Code and tell it to use this script:
# Example: "Use the statusline.sh script in /path/to/cc-poor-mans-statusline/"

# 4. Done! Your credentials at ~/.claude/.credentials.json are used automatically
```

## Customization

Edit `statusline.sh`:

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

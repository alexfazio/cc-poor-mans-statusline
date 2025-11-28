# Poor Man's Statusline

Lightweight custom statusline for Claude Code with Powerline-style segments, usage limits, reset timers, and context monitoring.

## Features

- **Powerline-style segments** with colored backgrounds and smooth arrow transitions
- **Reset timers** showing countdown AND absolute time until limits reset (e.g., "2h11m @ 10pm")
- Real-time API usage (5-hour and 7-day limits)
- Per-model availability (Opus and Sonnet with distinct colors)
- Context window monitoring with auto-compact warning
- 1-minute smart caching
- Automatically adapts to your Claude Pro tier (basic or higher)

## Example Output

**Claude Pro (higher tiers with 7-day limits):**
```
 opus-4-5  project  main
 5h 27%  2h11m @ 10pm   7d 34%  4d2h @ Dec 2
 Opus 34%  Sonnet 20%
```

**Claude Pro (basic tier):**
```
 sonnet-4-5  project  main
 5h 45%  3h30m @ 2pm
```

**Color scheme:**
- Magenta: Model name, Opus limit
- Yellow: Project directory
- Green: Git branch
- Cyan: Usage percentages
- Blue: Reset countdowns, Sonnet limit
- Gray: Context info

## Prerequisites

- Claude Code (installed and authenticated)
- `jq` - JSON processor
- `curl` - HTTP client
- Terminal with 256-color support

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
```

### 3. Configure Claude Code

Add the statusline to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/cc-poor-mans-statusline/statusline.sh"
  }
}
```

Replace `/path/to/` with the actual location where you cloned the repo. For example:
- `~/Documents/GitHub/cc-poor-mans-statusline/statusline.sh`
- `~/projects/cc-poor-mans-statusline/statusline.sh`

> **Tip:** You can also use `~` for your home directory in the path.

Your credentials at `~/.claude/.credentials.json` are used automatically.

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

**Powerline arrows not rendering?**
- Ensure your terminal supports Unicode (U+E0B0)
- Most modern terminals work out of the box

## Security

Never commit:
- `~/.claude/.credentials.json` (your OAuth token)
- `/tmp/claude-usage-cache.json` (usage data)
- Screenshots with personal info

The included `.gitignore` prevents accidental leaks.

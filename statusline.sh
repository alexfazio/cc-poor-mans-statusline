#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract model information
model_name=$(echo "$input" | jq -r '.model.id // "unknown"')

# Extract directory information
cwd=$(echo "$input" | jq -r '.workspace.current_dir')

# Get git branch if in a git repo (using -C to avoid cd)
branch=$(git -C "$cwd" branch --show-current 2>/dev/null)

# Get basename of directory
dir_name=$(basename "$cwd")

# ============================================
# HELPER FUNCTIONS
# ============================================

# Function to calculate visible length (strip ANSI codes)
visible_length() {
    local string="$1"
    # Remove ANSI escape sequences (both \033 and \x1b formats) and count characters
    local clean
    clean=$(printf "%b" "$string" | sed $'s/\033\[[0-9;]*m//g')
    echo "${#clean}"
}

# Powerline arrow character (U+E0B0)
PL_ARROW=""

# Powerline segment: bg color, fg color, text, next segment's bg color
# Uses 256-color ANSI codes
pl_segment() {
    local bg=$1 fg=$2 text=$3 next_bg=$4
    # Background + foreground for text, then transition arrow
    printf "\033[48;5;%dm\033[38;5;%dm %s \033[48;5;%dm\033[38;5;%dm%s" \
        "$bg" "$fg" "$text" "$next_bg" "$bg" "$PL_ARROW"
}

# Final powerline segment (no arrow, just reset)
pl_segment_end() {
    local bg=$1 fg=$2 text=$3
    printf "\033[48;5;%dm\033[38;5;%dm %s \033[0m\033[38;5;%dm%s\033[0m" \
        "$bg" "$fg" "$text" "$bg" "$PL_ARROW"
}

# ============================================
# TIME FORMATTING FUNCTIONS
# ============================================

# Format countdown from ISO timestamp (e.g., "4h23m" or "2d5h")
# Args: $1 = ISO timestamp, $2 = type ("5h" or "7d")
format_countdown() {
    local iso_ts=$1
    local type=$2

    if [ -z "$iso_ts" ] || [ "$iso_ts" = "null" ]; then
        echo ""
        return
    fi

    # Strip timezone suffix and milliseconds for macOS date parsing
    local ts_clean
    ts_clean=$(echo "$iso_ts" | sed 's/+00:00$//' | sed 's/Z$//' | sed 's/\.[0-9]*//')

    # Parse ISO timestamp to epoch (macOS format) - use TZ=UTC since API returns UTC times
    local reset_epoch
    reset_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" "+%s" 2>/dev/null)

    if [ -z "$reset_epoch" ]; then
        echo ""
        return
    fi

    local now_epoch
    now_epoch=$(date +%s)
    local diff=$((reset_epoch - now_epoch))

    # If already past, show 0
    if [ "$diff" -le 0 ]; then
        echo "0m"
        return
    fi

    # Format based on type
    if [ "$type" = "5h" ]; then
        # Short format: hours and minutes
        local hours=$((diff / 3600))
        local mins=$(((diff % 3600) / 60))
        if [ "$hours" -gt 0 ]; then
            echo "${hours}h${mins}m"
        else
            echo "${mins}m"
        fi
    else
        # Long format: days and hours
        local days=$((diff / 86400))
        local hours=$(((diff % 86400) / 3600))
        if [ "$days" -gt 0 ]; then
            echo "${days}d${hours}h"
        else
            echo "${hours}h"
        fi
    fi
}

# Format absolute time from ISO timestamp (e.g., "6PM" or "Dec 5")
# Args: $1 = ISO timestamp, $2 = type ("5h" or "7d")
format_absolute_time() {
    local iso_ts=$1
    local type=$2

    if [ -z "$iso_ts" ] || [ "$iso_ts" = "null" ]; then
        echo ""
        return
    fi

    # Strip timezone suffix and milliseconds for macOS date parsing
    local ts_clean
    ts_clean=$(echo "$iso_ts" | sed 's/+00:00$//' | sed 's/Z$//' | sed 's/\.[0-9]*//')

    # Parse as UTC to get correct epoch, then format in local time
    local epoch
    epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" "+%s" 2>/dev/null)

    if [ -z "$epoch" ]; then
        echo ""
        return
    fi

    # Format the epoch in local time
    if [ "$type" = "5h" ]; then
        # Short-term: show time like "6pm" or "6:30pm"
        local mins
        mins=$(date -r "$epoch" "+%M" 2>/dev/null)
        local result
        if [ "$mins" = "00" ]; then
            result=$(date -r "$epoch" "+%-I%p" 2>/dev/null)
        else
            result=$(date -r "$epoch" "+%-I:%M%p" 2>/dev/null)
        fi
        # Convert to lowercase and remove periods (AM/PM → am/pm)
        echo "$result" | tr '[:upper:]' '[:lower:]' | sed 's/\.//g'
    else
        # Long-term: show date like "Dec 5"
        date -r "$epoch" "+%b %-d" 2>/dev/null
    fi
}

# ============================================
# USAGE LIMITS FUNCTIONS
# ============================================

CACHE_FILE="/tmp/claude-usage-cache.json"
CACHE_TTL=60  # 1 minute in seconds
CREDENTIALS_FILE="$HOME/.claude/.credentials.json"

# Function to check if cache is valid
is_cache_valid() {
    if [ ! -f "$CACHE_FILE" ]; then
        return 1
    fi

    local cache_time
    cache_time=$(jq -r '.timestamp // 0' "$CACHE_FILE" 2>/dev/null)
    local current_time
    current_time=$(date +%s)
    local age=$((current_time - cache_time))

    if [ "$age" -lt "$CACHE_TTL" ]; then
        return 0
    else
        return 1
    fi
}

# Function to fetch usage from API
fetch_usage() {
    # Check if credentials file exists
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        return 1
    fi

    # Extract access token
    local token
    token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$token" ]; then
        return 1
    fi

    # Make API request with 2 second timeout
    local response
    response=$(curl -s --max-time 2 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

    if ! [ -n "$response" ]; then
        return 1
    fi

    # Parse response - utilization values
    local five_hour
    five_hour=$(echo "$response" | jq -r '.five_hour.utilization // null' 2>/dev/null)
    local seven_day
    seven_day=$(echo "$response" | jq -r '.seven_day.utilization // null' 2>/dev/null)
    local seven_day_opus
    seven_day_opus=$(echo "$response" | jq -r '.seven_day_opus.utilization // null' 2>/dev/null)
    local seven_day_sonnet
    seven_day_sonnet=$(echo "$response" | jq -r '.seven_day_sonnet.utilization // null' 2>/dev/null)

    # Parse response - reset timestamps
    local five_hour_resets
    five_hour_resets=$(echo "$response" | jq -r '.five_hour.resets_at // null' 2>/dev/null)
    local seven_day_resets
    seven_day_resets=$(echo "$response" | jq -r '.seven_day.resets_at // null' 2>/dev/null)

    # At least five_hour is required
    if [ "$five_hour" = "null" ]; then
        return 1
    fi

    # Write to cache with model-specific data and reset timestamps
    local current_time
    current_time=$(date +%s)
    jq -n \
        --argjson ts "$current_time" \
        --argjson fh "$five_hour" \
        --arg fhr "$five_hour_resets" \
        --argjson sd "$seven_day" \
        --arg sdr "$seven_day_resets" \
        --argjson sdo "${seven_day_opus:-null}" \
        --argjson sds "${seven_day_sonnet:-null}" \
        '{timestamp: $ts, five_hour: $fh, five_hour_resets: $fhr, seven_day: $sd, seven_day_resets: $sdr, seven_day_opus: $sdo, seven_day_sonnet: $sds}' \
        > "$CACHE_FILE"

    # Output space-separated values (includes reset timestamps)
    echo "$five_hour $seven_day $seven_day_opus $seven_day_sonnet $five_hour_resets $seven_day_resets"
    return 0
}

# Function to get usage (from cache or API)
get_usage() {
    if is_cache_valid; then
        # Read from cache
        local five_hour
        five_hour=$(jq -r '.five_hour' "$CACHE_FILE" 2>/dev/null)
        local seven_day
        seven_day=$(jq -r '.seven_day' "$CACHE_FILE" 2>/dev/null)
        local seven_day_opus
        seven_day_opus=$(jq -r '.seven_day_opus // "null"' "$CACHE_FILE" 2>/dev/null)
        local seven_day_sonnet
        seven_day_sonnet=$(jq -r '.seven_day_sonnet // "null"' "$CACHE_FILE" 2>/dev/null)
        local five_hour_resets
        five_hour_resets=$(jq -r '.five_hour_resets // "null"' "$CACHE_FILE" 2>/dev/null)
        local seven_day_resets
        seven_day_resets=$(jq -r '.seven_day_resets // "null"' "$CACHE_FILE" 2>/dev/null)
        echo "$five_hour $seven_day $seven_day_opus $seven_day_sonnet $five_hour_resets $seven_day_resets"
    else
        # Fetch from API
        fetch_usage
    fi
}

# Function to format percentage with color coding
format_percentage() {
    local percentage=$1

    # Convert percentage to integer
    local pct_int=${percentage%.*}

    # Choose color based on percentage
    local color
    if [ "$pct_int" -le 50 ]; then
        color="\033[1;32m"  # Green
    elif [ "$pct_int" -le 80 ]; then
        color="\033[1;33m"  # Yellow
    else
        color="\033[1;31m"  # Red
    fi

    # Return colored percentage only (no bar)
    printf "${color}%d%%\033[0m" "$pct_int"
}

# Function to format a model's usage percentage
# Args: $1 = model name (e.g., "Opus"), $2 = percentage (or "null")
format_model_usage() {
    local model_name=$1
    local percentage=$2

    # Natural formatting without fixed width
    local formatted_name="${model_name}:"

    # Handle null values
    if [ "$percentage" = "null" ] || [ -z "$percentage" ]; then
        # Gray color for null/unavailable
        printf "%s \033[1;30m--\033[0m" "$formatted_name"
    else
        # Normal color-coded percentage
        local pct_formatted
        pct_formatted=$(format_percentage "$percentage")
        printf "%s %s" "$formatted_name" "$pct_formatted"
    fi
}

# Function to get usage data as associative-style output
# Returns: five_hour seven_day seven_day_opus seven_day_sonnet five_hour_resets seven_day_resets
get_usage_data() {
    local usage_data
    usage_data=$(get_usage)

    if [ -z "$usage_data" ]; then
        return 1
    fi

    echo "$usage_data"
}

# ============================================
# CONTEXT USAGE FUNCTIONS
# ============================================

CONTEXT_WINDOW=200000  # Claude Sonnet 4.5 context window
AUTO_COMPACT_THRESHOLD=160000  # 80% of context window

# Function to format token count (e.g., 35234 → "35.2K")
format_token_count() {
    local tokens=$1

    if [ -z "$tokens" ] || [ "$tokens" -eq 0 ]; then
        echo "0"
        return
    fi

    # Convert to K format if >= 1000
    if [ "$tokens" -ge 1000 ]; then
        # Calculate with one decimal place
        local k_value
        k_value=$(echo "scale=1; $tokens / 1000" | bc 2>/dev/null)
        echo "${k_value}K"
    else
        echo "$tokens"
    fi
}

# Function to calculate context tokens from transcript
calculate_context_tokens() {
    local transcript_path="$1"

    # Check if transcript exists
    if [ ! -f "$transcript_path" ]; then
        return 1
    fi

    # Read last 100 lines in reverse, find first valid usage
    local context_tokens=0
    while IFS= read -r line; do
        # Skip sidechain and error messages
        if echo "$line" | grep -q '"isSidechain":true'; then
            continue
        fi
        if echo "$line" | grep -q '"isApiErrorMessage":true'; then
            continue
        fi

        # Check if line has usage object
        if echo "$line" | grep -q '"usage":{'; then
            # Extract tokens
            local input_tokens
            input_tokens=$(echo "$line" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null)
            local cache_read
            cache_read=$(echo "$line" | jq -r '.message.usage.cache_read_input_tokens // 0' 2>/dev/null)
            local cache_create
            cache_create=$(echo "$line" | jq -r '.message.usage.cache_creation_input_tokens // 0' 2>/dev/null)

            # Calculate context (input side only)
            context_tokens=$((input_tokens + cache_read + cache_create))
            break  # Found most recent, stop
        fi
    done < <(tail -n 100 "$transcript_path" 2>/dev/null | tail -r 2>/dev/null || tail -n 100 "$transcript_path" 2>/dev/null | awk '{lines[NR]=$0} END {for(i=NR;i>0;i--) print lines[i]}')

    echo "$context_tokens"
}

# Function to format context display (returns string)
format_context() {
    # Extract transcript path from input
    local transcript_path
    transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')

    if [ -z "$transcript_path" ]; then
        echo ""  # Return empty string if no transcript
        return
    fi

    # Calculate context tokens
    local context_tokens
    context_tokens=$(calculate_context_tokens "$transcript_path")

    if [ -z "$context_tokens" ] || [ "$context_tokens" -eq 0 ]; then
        echo ""  # Return empty string if no context data
        return
    fi

    # Calculate percentage
    local percentage
    percentage=$((context_tokens * 100 / CONTEXT_WINDOW))

    # Format token count
    local formatted_tokens
    formatted_tokens=$(format_token_count "$context_tokens")

    # Check if approaching auto-compact threshold (> 80%)
    local warning=""
    if [ "$context_tokens" -gt "$AUTO_COMPACT_THRESHOLD" ]; then
        warning=" ⚠️"
    fi

    # Build and return context string
    local ctx_pct
    ctx_pct=$(format_percentage "$percentage")
    printf "CTX: %s %s%s" "$formatted_tokens" "$ctx_pct" "$warning"
}

# ============================================
# BUILD THE POWERLINE STATUS LINE
# ============================================

# Color definitions (256-color palette)
C_MAGENTA=5    # Model, Opus
C_YELLOW=3     # Project
C_GREEN=2      # Branch
C_CYAN=6       # Usage limits
C_BLUE=4       # Reset times, Sonnet
C_GRAY=8       # Context
C_WHITE=15     # Light text
C_BLACK=0      # Dark text

# Shorten model name (e.g., "claude-sonnet-4-5-20250929" → "sonnet-4-5")
short_model=$(echo "$model_name" | sed 's/^claude-//' | sed 's/-[0-9]\{8\}$//')

# ============================================
# ROW 1: Model → Project → Branch
# ============================================
row1=""
if [ -n "$branch" ]; then
    row1=$(pl_segment $C_MAGENTA $C_WHITE "$short_model" $C_YELLOW)
    row1="${row1}$(pl_segment $C_YELLOW $C_BLACK "$dir_name" $C_GREEN)"
    row1="${row1}$(pl_segment_end $C_GREEN $C_BLACK "$branch")"
else
    row1=$(pl_segment $C_MAGENTA $C_WHITE "$short_model" $C_YELLOW)
    row1="${row1}$(pl_segment_end $C_YELLOW $C_BLACK "$dir_name")"
fi
printf "%b\n" "$row1"

# ============================================
# ROW 2: Usage Limits with Reset Times
# ============================================
usage_data=$(get_usage_data)
if [ -n "$usage_data" ]; then
    read -r five_hour seven_day seven_day_opus seven_day_sonnet five_hour_resets seven_day_resets <<< "$usage_data"

    if [ -n "$five_hour" ] && [ "$five_hour" != "null" ]; then
        # Format 5h percentage
        five_h_int=${five_hour%.*}

        # Build 5h reset info
        five_h_countdown=$(format_countdown "$five_hour_resets" "5h")
        five_h_absolute=$(format_absolute_time "$five_hour_resets" "5h")

        row2=""
        if [ "$seven_day" != "null" ] && [ -n "$seven_day" ]; then
            # Full display: 5h and 7d
            seven_d_int=${seven_day%.*}
            seven_d_countdown=$(format_countdown "$seven_day_resets" "7d")
            seven_d_absolute=$(format_absolute_time "$seven_day_resets" "7d")

            # Build 5h segment
            if [ -n "$five_h_countdown" ] && [ -n "$five_h_absolute" ]; then
                row2=$(pl_segment $C_CYAN $C_BLACK "5h ${five_h_int}%" $C_BLUE)
                row2="${row2}$(pl_segment $C_BLUE $C_WHITE "${five_h_countdown} @ ${five_h_absolute}" $C_CYAN)"
            else
                row2=$(pl_segment $C_CYAN $C_BLACK "5h ${five_h_int}%" $C_CYAN)
            fi

            # Build 7d segment
            if [ -n "$seven_d_countdown" ] && [ -n "$seven_d_absolute" ]; then
                row2="${row2}$(pl_segment $C_CYAN $C_BLACK "7d ${seven_d_int}%" $C_BLUE)"
                row2="${row2}$(pl_segment_end $C_BLUE $C_WHITE "${seven_d_countdown} @ ${seven_d_absolute}")"
            else
                row2="${row2}$(pl_segment_end $C_CYAN $C_BLACK "7d ${seven_d_int}%")"
            fi
        else
            # Basic tier: only 5h
            if [ -n "$five_h_countdown" ] && [ -n "$five_h_absolute" ]; then
                row2=$(pl_segment $C_CYAN $C_BLACK "5h ${five_h_int}%" $C_BLUE)
                row2="${row2}$(pl_segment_end $C_BLUE $C_WHITE "${five_h_countdown} @ ${five_h_absolute}")"
            else
                row2=$(pl_segment_end $C_CYAN $C_BLACK "5h ${five_h_int}%")
            fi
        fi

        printf "%b\n" "$row2"
    fi
fi

# ============================================
# ROW 3: Model Limits + Context
# ============================================
row3=""
has_row3=false

# Model-specific limits (only if 7d data exists)
if [ -n "$usage_data" ]; then
    read -r five_hour seven_day seven_day_opus seven_day_sonnet five_hour_resets seven_day_resets <<< "$usage_data"

    if [ "$seven_day" != "null" ] && [ -n "$seven_day" ]; then
        has_row3=true
        # Opus uses overall 7d
        opus_int=${seven_day%.*}

        # Sonnet: use dedicated limit if available
        if [ "$seven_day_sonnet" != "null" ] && [ -n "$seven_day_sonnet" ]; then
            sonnet_int=${seven_day_sonnet%.*}
        else
            sonnet_int=${seven_day%.*}
        fi

        row3=$(pl_segment $C_MAGENTA $C_WHITE "Opus ${opus_int}%" $C_BLUE)
        # Check if context will follow (peek ahead)
        ctx_check=$(format_context)
        if [ -n "$ctx_check" ]; then
            row3="${row3}$(pl_segment $C_BLUE $C_WHITE "Sonnet ${sonnet_int}%" $C_GRAY)"
        else
            row3="${row3}$(pl_segment_end $C_BLUE $C_WHITE "Sonnet ${sonnet_int}%")"
        fi
    fi
fi

# Context usage
context_result=$(format_context)
if [ -n "$context_result" ]; then
    # Extract just the values from the formatted context
    ctx_tokens=$(echo "$context_result" | sed 's/CTX: //' | awk '{print $1}')
    ctx_pct=$(echo "$context_result" | grep -oE '[0-9]+%')
    ctx_warning=""
    if echo "$context_result" | grep -q "⚠️"; then
        ctx_warning=" ⚠️"
    fi

    if [ "$has_row3" = true ]; then
        row3="${row3}$(pl_segment_end $C_GRAY $C_WHITE "CTX ${ctx_tokens} ${ctx_pct}${ctx_warning}")"
    else
        has_row3=true
        row3=$(pl_segment_end $C_GRAY $C_WHITE "CTX ${ctx_tokens} ${ctx_pct}${ctx_warning}")
    fi
fi

if [ "$has_row3" = true ]; then
    printf "%b\n" "$row3"
fi

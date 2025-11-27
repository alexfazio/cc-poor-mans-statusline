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

    # Parse response
    local five_hour
    five_hour=$(echo "$response" | jq -r '.five_hour.utilization // null' 2>/dev/null)
    local seven_day
    seven_day=$(echo "$response" | jq -r '.seven_day.utilization // null' 2>/dev/null)
    local seven_day_opus
    seven_day_opus=$(echo "$response" | jq -r '.seven_day_opus.utilization // null' 2>/dev/null)
    local seven_day_sonnet
    seven_day_sonnet=$(echo "$response" | jq -r '.seven_day_sonnet.utilization // null' 2>/dev/null)

    # At least five_hour is required
    if [ "$five_hour" = "null" ]; then
        return 1
    fi

    # Write to cache with model-specific data
    local current_time
    current_time=$(date +%s)
    jq -n \
        --argjson ts "$current_time" \
        --argjson fh "$five_hour" \
        --argjson sd "$seven_day" \
        --argjson sdo "${seven_day_opus:-null}" \
        --argjson sds "${seven_day_sonnet:-null}" \
        '{timestamp: $ts, five_hour: $fh, seven_day: $sd, seven_day_opus: $sdo, seven_day_sonnet: $sds}' \
        > "$CACHE_FILE"

    # Output space-separated values (for backward compatibility)
    echo "$five_hour $seven_day $seven_day_opus $seven_day_sonnet"
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
        echo "$five_hour $seven_day $seven_day_opus $seven_day_sonnet"
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

# Function to format usage display (returns TWO lines if model data exists)
format_usage() {
    local usage_data
    usage_data=$(get_usage)

    if [ -z "$usage_data" ]; then
        echo ""
        return
    fi

    read -r five_hour seven_day seven_day_opus seven_day_sonnet <<< "$usage_data"

    if [ -z "$five_hour" ]; then
        echo ""
        return
    fi

    # Build LINE 1: Overall limits (5h and 7d)
    local five_h_pct
    five_h_pct=$(format_percentage "$five_hour")

    local line1
    if [ "$seven_day" = "null" ] || [ -z "$seven_day" ]; then
        # Only show 5h if 7d is not available
        line1=$(printf "5h: %s" "$five_h_pct")
    else
        local seven_d_pct
        seven_d_pct=$(format_percentage "$seven_day")
        line1=$(printf "5h: %s \033[1;36m|\033[0m 7d: %s" "$five_h_pct" "$seven_d_pct")
    fi

    # Build LINE 2: Model-specific limits (only if data is available)
    local line2=""

    # Only show model-specific limits if we have 7-day data
    if [ "$seven_day" != "null" ] && [ -n "$seven_day" ]; then
        # Opus uses overall 7d, Sonnet uses its dedicated limit
        local opus_formatted
        opus_formatted=$(format_model_usage "Opus" "$seven_day")  # Use overall, not seven_day_opus
        local sonnet_formatted

        # Sonnet: use dedicated limit if available, otherwise fall back to overall
        if [ "$seven_day_sonnet" = "null" ] || [ -z "$seven_day_sonnet" ]; then
            sonnet_formatted=$(format_model_usage "Sonnet" "$seven_day")
        else
            sonnet_formatted=$(format_model_usage "Sonnet" "$seven_day_sonnet")
        fi

        # No indent - left-aligned
        line2=$(printf "%s \033[1;36m|\033[0m %s" "$opus_formatted" "$sonnet_formatted")
    fi

    # Return with delimiter
    echo "${line1}|||${line2}"
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
# BUILD THE STATUS LINE
# ============================================

# Build base statusline
base_output=$(printf "\033[1;35m[%s]\033[0m " "$model_name")
base_output="${base_output}$(printf "\033[1;36m%s@%s\033[0m:" "$(whoami)" "$(hostname -s)")"
base_output="${base_output}$(printf "\033[1;33m%s\033[0m" "$dir_name")"

if [ -n "$branch" ]; then
    base_output="${base_output} $(printf "\033[1;32m(%s)\033[0m" "$branch")"
fi

# Output base statusline (line 1)
printf "%b\n" "$base_output"

# Build and output metrics (lines 2, 3, and potentially 4)
context_result=$(format_context)
usage_result=$(format_usage)

# Parse usage result (may contain two lines separated by |||)
usage_line1=""
usage_line2=""
if [ -n "$usage_result" ]; then
    if echo "$usage_result" | grep -q '|||'; then
        usage_line1="${usage_result%|||*}"
        usage_line2="${usage_result#*|||}"
    else
        usage_line1="$usage_result"
        usage_line2=""
    fi
fi

# Output line 2: Model-specific limits (if exists)
if [ -n "$usage_line2" ]; then
    printf "  %b\n" "$usage_line2"
fi

# Output line 3: Usage limits (if present)
if [ -n "$usage_line1" ]; then
    printf "  %b\n" "$usage_line1"
fi

# Output line 4: Context (if present)
if [ -n "$context_result" ]; then
    printf "  %b\n" "$context_result"
fi

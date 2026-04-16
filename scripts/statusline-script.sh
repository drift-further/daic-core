#!/bin/bash

# Claude Code StatusLine Script (Enhanced)
# Provides comprehensive session information with Powerline styling
# Features: Context usage, session cost/duration, git branch, tasks

# Read JSON input from stdin
input=$(cat)

# Extract basic info using Python
cwd=$(echo "$input" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('workspace', {}).get('current_dir') or data.get('cwd', ''))")
model_name=$(echo "$input" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('model', {}).get('display_name', 'Claude'))")

# Powerline characters
PL_ARROW=""        # \ue0b0
PL_ARROW_LEFT=""   # \ue0b2
PL_BRANCH=""       # \ue0a0

# Ayu Dark color palette (ANSI 256)
GREEN="\033[38;5;114m"      # AAD94C - success/low usage
ORANGE="\033[38;5;215m"     # FFB454 - warning/medium
RED="\033[38;5;203m"        # F26D78 - danger/high
CYAN="\033[38;5;111m"       # 59C2FF - info/entity
PURPLE="\033[38;5;183m"     # D2A6FF - constants
GRAY="\033[38;5;242m"       # dim
TEXT="\033[38;5;250m"       # BFBDB6 - main text
YELLOW="\033[38;5;221m"     # E6B450 - accent

# Background versions for Powerline
BG_GREEN="\033[48;5;114m"
BG_ORANGE="\033[48;5;215m"
BG_RED="\033[48;5;203m"
BG_CYAN="\033[48;5;111m"
BG_PURPLE="\033[48;5;183m"
BG_GRAY="\033[48;5;236m"
BG_DARK="\033[48;5;234m"
FG_BLACK="\033[38;5;234m"
FG_GRAY="\033[38;5;236m"

RESET="\033[0m"
BOLD="\033[1m"

# Function to get context info (using Claude Code's direct data)
get_context_info() {
    # Try to get direct context_window data first (preferred)
    # Apply 80% usable limit rule (auto-compact triggers before theoretical max)
    context_data=$(echo "$input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cw = data.get('context_window', {})
    current = cw.get('current_usage', {}) or {}
    input_tokens = current.get('input_tokens', 0) + current.get('cache_read_input_tokens', 0) + current.get('cache_creation_input_tokens', 0)
    theoretical_size = cw.get('context_window_size', 200000)

    # Apply 80% usable limit (auto-compact triggers before max)
    # 200k theoretical -> 160k usable, 1M theoretical -> 800k usable
    usable_size = int(theoretical_size * 0.8)

    # Calculate percentage against usable limit
    if input_tokens > 0:
        pct = (input_tokens / usable_size) * 100
        # Cap at 100% for display
        pct = min(pct, 100.0)
        print(f'{pct:.1f}|{input_tokens}|{usable_size}')
    else:
        print('0|0|{}'.format(usable_size))
except:
    print('0|0|160000')
" 2>/dev/null)

    IFS='|' read -r pct tokens limit <<< "$context_data"

    # Format tokens
    tokens_k=$((tokens / 1000))
    limit_k=$((limit / 1000))

    # Determine color based on percentage
    pct_int=${pct%.*}
    if [[ $pct_int -lt 50 ]]; then
        bar_color="$GREEN"
        bg_color="$BG_GREEN"
    elif [[ $pct_int -lt 80 ]]; then
        bar_color="$ORANGE"
        bg_color="$BG_ORANGE"
    else
        bar_color="$RED"
        bg_color="$BG_RED"
    fi

    # Build progress bar (10 blocks)
    filled=$((pct_int / 10))
    [[ $filled -gt 10 ]] && filled=10
    empty=$((10 - filled))

    bar="${bar_color}"
    for ((i=0; i<filled; i++)); do bar+="█"; done
    bar+="${GRAY}"
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="${RESET}"

    # Write context percentage to state file for hooks to read (statusline bridge)
    local state_dir="$cwd/.claude/state"
    if [[ -d "$state_dir" ]]; then
        echo "{\"used_percentage\": $pct, \"tokens\": $tokens, \"limit\": $limit, \"updated\": $(date +%s)}" > "$state_dir/context-usage.json" 2>/dev/null
    fi

    echo -e "${bar} ${TEXT}${pct}% (${tokens_k}k/${limit_k}k)${RESET}"
}

# Function to get session duration
get_session_info() {
    duration=$(echo "$input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    duration_ms = data.get('cost', {}).get('total_duration_ms', 0)

    if duration_ms > 0:
        seconds = duration_ms / 1000
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        if hours > 0:
            print(f'{hours}h{minutes}m')
        else:
            print(f'{minutes}m')
    else:
        print('0m')
except:
    print('0m')
" 2>/dev/null)

    echo -e "${TEXT}${duration}${RESET}"
}

# Function to get block timer (5-hour billing window)
get_block_timer() {
    block_file="$cwd/.claude/state/block-info.json"
    if [[ ! -f "$block_file" ]]; then
        echo ""
        return
    fi

    block_data=$(python3 -c "
import sys, json
from datetime import datetime, timezone

try:
    with open('$block_file', 'r') as f:
        data = json.load(f)

    if not data.get('isActive', False):
        print('')
        sys.exit(0)

    # Parse block end time
    block_end_str = data.get('blockEnd', '')
    if not block_end_str:
        print('')
        sys.exit(0)

    # Parse ISO timestamp
    if block_end_str.endswith('Z'):
        block_end_str = block_end_str[:-1] + '+00:00'
    block_end = datetime.fromisoformat(block_end_str)

    block_start_str = data.get('blockStart', '')
    if block_start_str.endswith('Z'):
        block_start_str = block_start_str[:-1] + '+00:00'
    block_start = datetime.fromisoformat(block_start_str)

    now = datetime.now(timezone.utc)

    # Calculate elapsed and remaining
    elapsed_seconds = (now - block_start).total_seconds()
    remaining_seconds = max(0, (block_end - now).total_seconds())
    total_seconds = 5 * 60 * 60  # 5 hours

    # Check if still active (within block window)
    if remaining_seconds <= 0:
        print('')
        sys.exit(0)

    # Format times
    elapsed_h = int(elapsed_seconds // 3600)
    elapsed_m = int((elapsed_seconds % 3600) // 60)
    remaining_h = int(remaining_seconds // 3600)
    remaining_m = int((remaining_seconds % 3600) // 60)

    if elapsed_h > 0:
        elapsed_str = f'{elapsed_h}h{elapsed_m}m'
    else:
        elapsed_str = f'{elapsed_m}m'

    if remaining_h > 0:
        remaining_str = f'{remaining_h}h{remaining_m}m'
    else:
        remaining_str = f'{remaining_m}m'

    # Percentage of block used
    pct = min(100, (elapsed_seconds / total_seconds) * 100)

    print(f'{pct:.0f}|{elapsed_str}|{remaining_str}')
except Exception as e:
    print('')
" 2>/dev/null)

    if [[ -z "$block_data" ]]; then
        echo ""
        return
    fi

    IFS='|' read -r pct elapsed remaining <<< "$block_data"

    if [[ -z "$pct" ]] || [[ -z "$elapsed" ]] || [[ -z "$remaining" ]]; then
        echo ""
        return
    fi

    # Determine color based on percentage (inverted - more time used = more warning)
    pct_int=${pct%.*}
    if [[ $pct_int -lt 60 ]]; then
        bar_color="$GREEN"
    elif [[ $pct_int -lt 85 ]]; then
        bar_color="$ORANGE"
    else
        bar_color="$RED"
    fi

    # Build progress bar (10 blocks) - shows time USED
    filled=$((pct_int / 10))
    [[ $filled -gt 10 ]] && filled=10
    empty=$((10 - filled))

    bar="${bar_color}"
    for ((i=0; i<filled; i++)); do bar+="█"; done
    bar+="${GRAY}"
    for ((i=0; i<empty; i++)); do bar+="░"; done
    bar+="${RESET}"

    echo -e "${bar} ${TEXT}${elapsed}${GRAY}/${RESET}${bar_color}${remaining}${RESET}"
}

# Function to get project name and git branch
get_git_branch() {
    if [[ -d "$cwd/.git" ]]; then
        branch=$(cd "$cwd" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [[ -n "$branch" ]]; then
            # Get project name from directory
            project_name=$(basename "$cwd")
            echo -e "${PURPLE}${PL_BRANCH} ${project_name}/${branch}${RESET}"
        fi
    fi
}

# Function to get current task
get_current_task() {
    if [[ -f "$cwd/.claude/state/current_task.json" ]]; then
        task_name=$(python3 -c "
import sys, json
try:
    with open('$cwd/.claude/state/current_task.json', 'r') as f:
        data = json.load(f)
        print(data.get('task', 'None'))
except:
    print('None')
" 2>/dev/null)
        echo -e "${CYAN}Task: ${task_name}${RESET}"
    else
        echo -e "${CYAN}Task: None${RESET}"
    fi
}

# Function to count edited files
get_edited_files() {
    if [[ -d "$cwd/.git" ]]; then
        cd "$cwd"
        modified_count=$(git status --porcelain 2>/dev/null | grep -E '^[AM]|^.[AM]' | wc -l || echo "0")
        echo -e "${ORANGE}✎ ${modified_count}${RESET}"
    else
        echo -e "${ORANGE}✎ 0${RESET}"
    fi
}

# Function to count open tasks
get_open_tasks() {
    tasks_dir="$cwd/sessions/tasks"
    if [[ -d "$tasks_dir" ]]; then
        open_count=0
        for task_file in "$tasks_dir"/*.md; do
            if [[ -f "$task_file" ]]; then
                if ! grep -q -E "Status:\s*(done|completed)" "$task_file" 2>/dev/null; then
                    ((open_count++))
                fi
            fi
        done
        echo -e "${CYAN}[${open_count}]${RESET}"
    else
        echo -e "${CYAN}[0]${RESET}"
    fi
}

# Build the complete statusline
context_info=$(get_context_info)
session_info=$(get_session_info)
block_timer=$(get_block_timer)
git_branch=$(get_git_branch)
task_info=$(get_current_task)
files_info=$(get_edited_files)
tasks_info=$(get_open_tasks)

# Output: Two-line Powerline-styled statusline
# Line 1: Context bar | Session cost/duration | Block timer | Git branch
# Line 2: Task | Files edited | Open tasks

line1="$context_info ${GRAY}│${RESET} $session_info"
[[ -n "$block_timer" ]] && line1="$line1 ${GRAY}│${RESET} $block_timer"
[[ -n "$git_branch" ]] && line1="$line1 ${GRAY}│${RESET} $git_branch"

line2="$task_info ${GRAY}│${RESET} $files_info $tasks_info ${GRAY}│${RESET} ${CYAN}${model_name}${RESET}"

echo -e "$line1"
echo -e "$line2"

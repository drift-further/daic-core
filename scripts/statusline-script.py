#!/usr/bin/env python3
"""Claude Code StatusLine Script - Single-process Python implementation.

Provides comprehensive session information with Powerline styling.
Features: Context usage, session cost/duration, git branch, tasks, block timer.
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Read JSON input from stdin
try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    sys.exit(0)

cwd = (data.get("workspace", {}) or {}).get("current_dir") or data.get("cwd", "")
model_name = (data.get("model", {}) or {}).get("display_name", "Claude")

# Powerline characters
PL_ARROW = "\ue0b0"
PL_BRANCH = "\ue0a0"

# Ayu Dark color palette (ANSI 256)
GREEN = "\033[38;5;114m"
ORANGE = "\033[38;5;215m"
RED = "\033[38;5;203m"
CYAN = "\033[38;5;111m"
PURPLE = "\033[38;5;183m"
GRAY = "\033[38;5;242m"
TEXT = "\033[38;5;250m"

BG_GREEN = "\033[48;5;114m"
BG_PURPLE = "\033[48;5;183m"
FG_BLACK = "\033[38;5;234m"

RESET = "\033[0m"
BOLD = "\033[1m"


def build_progress_bar(pct_int, bar_color):
    filled = min(max(pct_int // 10, 0), 10)
    empty = 10 - filled
    return f"{bar_color}{'█' * filled}{GRAY}{'░' * empty}{RESET}"


def get_context_info():
    """Get context usage from Claude Code's direct data."""
    try:
        cw = data.get("context_window", {}) or {}
        current = cw.get("current_usage", {}) or {}
        input_tokens = (
            current.get("input_tokens", 0)
            + current.get("cache_read_input_tokens", 0)
            + current.get("cache_creation_input_tokens", 0)
        )
        theoretical_size = cw.get("context_window_size", 200000)
        usable_size = int(theoretical_size * 0.8)

        if input_tokens > 0:
            pct = min((input_tokens / usable_size) * 100, 100.0)
        else:
            pct = 0.0

        tokens_k = input_tokens // 1000
        limit_k = usable_size // 1000
        pct_int = int(pct)

        if pct_int < 50:
            bar_color = GREEN
        elif pct_int < 80:
            bar_color = ORANGE
        else:
            bar_color = RED

        bar = build_progress_bar(pct_int, bar_color)

        # Write context + session info to state file for hooks/Assist to read
        state_dir = os.path.join(cwd, ".claude", "state")
        if os.path.isdir(state_dir):
            try:
                cost_data = data.get("cost", {}) or {}
                state_file = os.path.join(state_dir, "context-usage.json")
                with open(state_file, "w") as f:
                    json.dump(
                        {
                            "used_percentage": pct,
                            "tokens": input_tokens,
                            "limit": usable_size,
                            "duration_ms": cost_data.get("total_duration_ms", 0),
                            "cost_usd": cost_data.get("total_cost_usd", 0),
                            "model": model_name,
                            "updated": int(time.time()),
                        },
                        f,
                    )
            except OSError:
                pass

        return f"{bar} {TEXT}{pct:.1f}% ({tokens_k}k/{limit_k}k){RESET}"
    except Exception:
        return f"{GRAY}{'░' * 10}{RESET} {TEXT}0% (0k/0k){RESET}"


def get_session_info():
    """Get session duration."""
    try:
        duration_ms = (data.get("cost", {}) or {}).get("total_duration_ms", 0)
        if duration_ms > 0:
            seconds = duration_ms / 1000
            hours = int(seconds // 3600)
            minutes = int((seconds % 3600) // 60)
            duration = f"{hours}h{minutes}m" if hours > 0 else f"{minutes}m"
        else:
            duration = "0m"
    except Exception:
        duration = "0m"
    return f"{TEXT}{duration}{RESET}"


def get_block_timer():
    """Get 5-hour billing block timer."""
    block_file = os.path.join(cwd, ".claude", "state", "block-info.json")
    if not os.path.isfile(block_file):
        return ""

    try:
        with open(block_file, "r") as f:
            block_data = json.load(f)

        if not block_data.get("isActive", False):
            return ""

        block_end_str = block_data.get("blockEnd", "")
        block_start_str = block_data.get("blockStart", "")
        if not block_end_str or not block_start_str:
            return ""

        # Parse ISO timestamps
        for s in [block_end_str, block_start_str]:
            pass
        if block_end_str.endswith("Z"):
            block_end_str = block_end_str[:-1] + "+00:00"
        if block_start_str.endswith("Z"):
            block_start_str = block_start_str[:-1] + "+00:00"

        block_end = datetime.fromisoformat(block_end_str)
        block_start = datetime.fromisoformat(block_start_str)
        now = datetime.now(timezone.utc)

        elapsed_seconds = (now - block_start).total_seconds()
        remaining_seconds = max(0, (block_end - now).total_seconds())
        total_seconds = 5 * 60 * 60

        if remaining_seconds <= 0:
            return ""

        elapsed_h = int(elapsed_seconds // 3600)
        elapsed_m = int((elapsed_seconds % 3600) // 60)
        remaining_h = int(remaining_seconds // 3600)
        remaining_m = int((remaining_seconds % 3600) // 60)

        elapsed_str = f"{elapsed_h}h{elapsed_m}m" if elapsed_h > 0 else f"{elapsed_m}m"
        remaining_str = (
            f"{remaining_h}h{remaining_m}m" if remaining_h > 0 else f"{remaining_m}m"
        )

        pct = min(100, int((elapsed_seconds / total_seconds) * 100))
        if pct < 60:
            bar_color = GREEN
        elif pct < 85:
            bar_color = ORANGE
        else:
            bar_color = RED

        bar = build_progress_bar(pct, bar_color)
        return (
            f"{bar} {TEXT}{elapsed_str}{GRAY}/{RESET}{bar_color}{remaining_str}{RESET}"
        )
    except Exception:
        return ""


def get_git_branch():
    """Get project name and git branch."""
    if not os.path.isdir(os.path.join(cwd, ".git")):
        return ""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=2,
        )
        branch = result.stdout.strip()
        if branch:
            project_name = os.path.basename(cwd)
            return f"{PURPLE}{PL_BRANCH} {project_name}/{branch}{RESET}"
    except Exception:
        pass
    return ""


def get_current_task():
    """Get current task name."""
    task_name = "None"
    task_file = os.path.join(cwd, ".claude", "state", "current_task.json")
    if os.path.isfile(task_file):
        try:
            with open(task_file, "r") as f:
                task_name = json.load(f).get("task", "None") or "None"
        except Exception:
            pass
    return f"{CYAN}Task: {task_name}{RESET}"


def get_edited_files():
    """Count edited files via git."""
    if not os.path.isdir(os.path.join(cwd, ".git")):
        return f"{ORANGE}✎ 0{RESET}"
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=2,
        )
        count = sum(
            1
            for line in result.stdout.splitlines()
            if line and (line[0] in "AM" or (len(line) > 1 and line[1] in "AM"))
        )
        return f"{ORANGE}✎ {count}{RESET}"
    except Exception:
        return f"{ORANGE}✎ 0{RESET}"


def get_open_tasks():
    """Count open task files."""
    tasks_dir = os.path.join(cwd, "sessions", "tasks")
    if not os.path.isdir(tasks_dir):
        return f"{CYAN}[0]{RESET}"
    try:
        count = 0
        for f in os.listdir(tasks_dir):
            if f.endswith(".md") and f != "TEMPLATE.md":
                fpath = os.path.join(tasks_dir, f)
                try:
                    with open(fpath, "r") as fh:
                        content = fh.read(500)
                        if (
                            "status: done" not in content.lower()
                            and "status: completed" not in content.lower()
                        ):
                            count += 1
                except OSError:
                    pass
        return f"{CYAN}[{count}]{RESET}"
    except Exception:
        return f"{CYAN}[0]{RESET}"


# Build output
context_info = get_context_info()
session_info = get_session_info()
block_timer = get_block_timer()
git_branch = get_git_branch()
task_info = get_current_task()
files_info = get_edited_files()
tasks_info = get_open_tasks()

# Line 1: Context bar | Session duration | Block timer | Git branch
line1 = f"{context_info} {GRAY}│{RESET} {session_info}"
if block_timer:
    line1 += f" {GRAY}│{RESET} {block_timer}"
if git_branch:
    line1 += f" {GRAY}│{RESET} {git_branch}"

# Line 2: Task | Files edited | Open tasks | Model
line2 = f"{task_info} {GRAY}│{RESET} {files_info} {tasks_info}"
line2 += f" {GRAY}│{RESET} {CYAN}{model_name}{RESET}"

print(line1)
print(line2)

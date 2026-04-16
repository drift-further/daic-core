#!/usr/bin/env python3
"""Pre-compact hook to save session state before context compaction.

Saves important context that should be preserved across compaction.
"""
import json
import sys
from datetime import datetime
from pathlib import Path

# Handle imports for both direct execution and symlinked scenarios
script_dir = Path(__file__).resolve().parent
if str(script_dir) not in sys.path:
    sys.path.insert(0, str(script_dir))

from shared_state import (
    get_project_root, get_task_state,
    save_session_checkpoint, ensure_state_dir, run_project_extension
)

# Load input
try:
    input_data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f"Error: Invalid JSON input: {e}", file=sys.stderr)
    sys.exit(1)

trigger = input_data.get("trigger", "unknown")  # "manual" or "auto"
custom_instructions = input_data.get("custom_instructions", "")

project_root = get_project_root()
context_additions = []

# Gather current state for checkpoint
checkpoint_data = {
    "trigger": trigger,
    "timestamp": datetime.now().isoformat(),
    "task_state": get_task_state(),
    "custom_instructions": custom_instructions,
}

# Check for modified files
import subprocess
try:
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=str(project_root),
        capture_output=True,
        text=True,
        timeout=5
    )
    modified_files = [line.strip() for line in result.stdout.strip().split('\n') if line.strip()]
    checkpoint_data["modified_files"] = modified_files

    if modified_files:
        context_additions.append(f"[Pre-Compact] {len(modified_files)} modified files detected")
except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
    checkpoint_data["modified_files"] = []

# Get recent git log for context
try:
    result = subprocess.run(
        ["git", "log", "--oneline", "-5"],
        cwd=str(project_root),
        capture_output=True,
        text=True,
        timeout=5
    )
    checkpoint_data["recent_commits"] = result.stdout.strip().split('\n')[:5]
except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
    checkpoint_data["recent_commits"] = []

# Save checkpoint
if save_session_checkpoint(checkpoint_data):
    context_additions.append("[Pre-Compact] Session checkpoint saved to .claude/state/session-checkpoint.json")

# Clear context warning flags since we're compacting
try:
    state_dir = project_root / '.claude' / 'state'
    for flag_file in state_dir.glob('context-warning-*.flag'):
        try:
            flag_file.unlink()
        except OSError:
            pass
except Exception:
    pass

# Run project-specific pre-compact extension
try:
    ext_result = run_project_extension("pre-compact", input_data)
    if ext_result and ext_result.get("additionalContext"):
        context_additions.append(ext_result["additionalContext"])
except Exception:
    pass  # Never fail pre-compact due to extension issues

# Output context
if context_additions:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreCompact",
            "additionalContext": "\n".join(context_additions)
        }
    }
    print(json.dumps(output))

sys.exit(0)

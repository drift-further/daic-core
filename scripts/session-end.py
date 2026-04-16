#!/usr/bin/env python3
"""Session end hook to clean up and persist state.

Saves final session state for potential recovery.
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
    save_session_checkpoint, ensure_state_dir
)

# Load input
try:
    input_data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f"Error: Invalid JSON input: {e}", file=sys.stderr)
    sys.exit(1)

reason = input_data.get("reason", "unknown")
session_id = input_data.get("session_id", "")

project_root = get_project_root()

# Save final session state
checkpoint_data = {
    "event": "session_end",
    "reason": reason,
    "session_id": session_id,
    "timestamp": datetime.now().isoformat(),
    "task_state": get_task_state(),
}

# Get modified files count
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
    checkpoint_data["modified_files_count"] = len(modified_files)
except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
    checkpoint_data["modified_files_count"] = 0

# Save the checkpoint
save_session_checkpoint(checkpoint_data)

# Clean up temporary flags
try:
    subagent_flag = project_root / '.claude' / 'state' / 'in_subagent_context.flag'
    if subagent_flag.exists():
        subagent_flag.unlink()
except OSError:
    pass

# SessionEnd hooks can't block termination, just log
sys.exit(0)

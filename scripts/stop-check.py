#!/usr/bin/env python3
"""Stop hook to validate task completion before Claude stops.

Checks if there are incomplete tasks or unfinished work that should be addressed.
Uses stop_hook_active to prevent infinite loops.
"""
import json
import sys
from pathlib import Path

# Handle imports for both direct execution and symlinked scenarios
script_dir = Path(__file__).resolve().parent
if str(script_dir) not in sys.path:
    sys.path.insert(0, str(script_dir))

try:
    from shared_state import get_project_root, get_task_state
except ImportError:
    # If shared_state import fails, allow stop without checks
    sys.exit(0)

# Load input
try:
    input_data = json.load(sys.stdin)
except (json.JSONDecodeError, Exception):
    # If we can't read input, allow stop
    sys.exit(0)

# Wrap everything in try/except to ensure we never crash
try:
    # CRITICAL: Check if we're already in a stop hook to prevent infinite loops
    stop_hook_active = input_data.get("stop_hook_active", False)
    if stop_hook_active:
        # Already tried to stop once, allow it this time
        sys.exit(0)

    project_root = get_project_root()
    if not project_root:
        sys.exit(0)

    reasons_to_continue = []

    # Check 1: Is there an active task that needs attention?
    try:
        task_state = get_task_state()
        if task_state.get("task"):
            task_name = task_state["task"]
            task_file = project_root / "sessions" / "tasks" / f"{task_name}.md"

            if task_file.exists():
                try:
                    content = task_file.read_text()
                    # Check if task is marked as in-progress
                    if "status: in-progress" in content or "status: in_progress" in content:
                        # Don't block, just remind
                        pass  # Task reminder handled elsewhere
                except OSError:
                    pass
    except Exception:
        pass

    # Check 3: Are there context warning flags that suggest we should wrap up?
    try:
        state_dir = project_root / '.claude' / 'state'
        # Check for critical-zone flags (700k+)
        critical_flags = ['context-warning-700k.flag', 'context-warning-750k.flag',
                          'context-warning-775k.flag', 'context-warning-800k.flag']
        if any((state_dir / f).exists() for f in critical_flags):
            reasons_to_continue.append(
                "Context is at 87%+ capacity (700k+ tokens). Consider using /compact or completing "
                "current work before context auto-compaction occurs."
            )
    except Exception:
        pass

    # Decide whether to block stopping
    if reasons_to_continue:
        output = {
            "decision": "block",
            "reason": " ".join(reasons_to_continue)
        }
        print(json.dumps(output))

except Exception:
    # Any unexpected error - allow stop without blocking
    pass

# Always allow stop (exit 0)
sys.exit(0)

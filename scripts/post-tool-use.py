#!/usr/bin/env python3
"""Post-tool-use hook for contextual feedback and auto-formatting.

Uses JSON output for non-blocking feedback instead of exit code 2.
"""

import json
import subprocess
import sys
from pathlib import Path

# Handle imports for both direct execution and symlinked scenarios
script_dir = Path(__file__).resolve().parent
if str(script_dir) not in sys.path:
    sys.path.insert(0, str(script_dir))

from shared_state import get_project_root, run_project_extension

# Load input
try:
    input_data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f"Error: Invalid JSON input: {e}", file=sys.stderr)
    sys.exit(1)

tool_name = input_data.get("tool_name", "")
tool_input = input_data.get("tool_input", {})
cwd = input_data.get("cwd", "")

# Collect context additions
additional_context = []

# Check for cd command in Bash operations
if tool_name == "Bash":
    command = tool_input.get("command", "")
    if command and "cd " in command:
        additional_context.append(f"[CWD: {cwd}]")

# Auto-format Python files with Black after edits
if tool_name in ("Write", "Edit", "MultiEdit"):
    file_path = tool_input.get("file_path", "")
    if file_path and file_path.endswith(".py"):
        project_root = get_project_root()
        black_bin = project_root / ".venv" / "bin" / "black"
        if black_bin.exists() and Path(file_path).exists():
            try:
                subprocess.run(
                    [str(black_bin), "--quiet", file_path],
                    timeout=10,
                    capture_output=True,
                )
            except (subprocess.TimeoutExpired, OSError):
                pass  # Non-critical, skip silently

# Run project-specific post-tool-use extension
try:
    ext_result = run_project_extension("post-tool-use", input_data)
    if ext_result and ext_result.get("additionalContext"):
        additional_context.append(ext_result["additionalContext"])
except Exception:
    pass  # Never fail post-tool-use due to extension issues

# Output using proper JSON format (exit code 0)
if additional_context:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": "\n".join(additional_context),
        }
    }
    print(json.dumps(output))

sys.exit(0)

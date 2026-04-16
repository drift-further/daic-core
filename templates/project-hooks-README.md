# Project Hook Extensions

This directory contains **project-specific** hook extensions that run alongside
the DAIC core hooks. Files here are never modified by `install.sh`.

## How It Works

Each file is named to match the core hook it extends. The core hook runs first,
then calls the matching extension and merges its output.

| File | Hook Event | Receives on stdin |
|------|------------|-------------------|
| `session-start.py` | SessionStart | _(none)_ |
| `post-tool-use.py` | PostToolUse | `{"tool_name", "tool_input", "cwd"}` |
| `sessions-enforce.py` | PreToolUse | `{"tool_name", "tool_input"}` |
| `user-messages.py` | UserPromptSubmit | `{"prompt", "transcript_path"}` |
| `pre-compact.py` | PreCompact | `{"trigger", "custom_instructions"}` |

## Output Format

Print JSON to stdout with context to inject into the session:

```json
{"additionalContext": "Text appended to the hook's context output"}
```

For PreToolUse (`sessions-enforce.py`) extensions only: exit with code 2 and
print reason to stderr to **block** the tool.

## Rules

- Extensions are **fail-safe**: crashes and timeouts are caught silently
- Timeout: 10 seconds
- Exit 0 for success (or no output if nothing to add)
- Only `sessions-enforce.py` extensions can block (exit code 2)
- Keep extensions fast — they run on every hook invocation

## Example: Session Start Environment Checks

```python
#!/usr/bin/env python3
"""Check project environment on session start."""
import json, subprocess

warnings = []

# Check python venv
result = subprocess.run(['which', 'python3'], capture_output=True, text=True)
if '/venv/' not in result.stdout:
    warnings.append("python3 not in venv: " + result.stdout.strip())

# Check a required import
result = subprocess.run(['python3', '-c', 'import psycopg'], capture_output=True, text=True)
if result.returncode != 0:
    warnings.append("psycopg not importable — wrong venv?")

if warnings:
    ctx = "\n== ENVIRONMENT WARNINGS ==\n"
    for w in warnings:
        ctx += f"- {w}\n"
    ctx += "== End ENVIRONMENT WARNINGS ==\n"
    print(json.dumps({"additionalContext": ctx}))
```

## Example: PostToolUse SQL Reminder

```python
#!/usr/bin/env python3
"""Remind to test after SQL changes."""
import json, sys

input_data = json.load(sys.stdin)
tool_name = input_data.get("tool_name", "")
file_path = input_data.get("tool_input", {}).get("file_path", "")

if file_path.endswith('.sql') and tool_name in ('Write', 'Edit', 'MultiEdit'):
    print(json.dumps({
        "additionalContext": "SQL file modified — remember to verify and run tests before claiming done."
    }))
```

#!/usr/bin/env python3
"""Session start hook to initialize Claude Code Sessions context."""
import json
import os
import sys
import subprocess
from pathlib import Path

# Handle imports for both direct execution and symlinked scenarios
script_dir = Path(__file__).resolve().parent
if str(script_dir) not in sys.path:
    sys.path.insert(0, str(script_dir))

from shared_state import get_project_root, ensure_state_dir, get_task_state, run_project_extension

# Get project root
PROJECT_ROOT = get_project_root()


def load_active_context() -> str:
    """Load docs/ACTIVE_CONTEXT.md if it exists, with graceful fallback.

    This supports the Tiered Documentation System:
    - HOT tier: ACTIVE_CONTEXT.md (max 200 lines, always loaded)
    - WARM tier: catalogs, architecture docs (loaded on-demand)
    - COLD tier: archives (rarely accessed)

    Returns context string to append, or info/warning message if file missing.
    """
    try:
        active_context_file = PROJECT_ROOT / 'docs' / 'ACTIVE_CONTEXT.md'
        if active_context_file.exists():
            content = active_context_file.read_text()
            line_count = len(content.splitlines())

            # Build the context block
            result = f"""
== ACTIVE PROJECT CONTEXT (docs/ACTIVE_CONTEXT.md, {line_count} lines) ==
{content}
"""
            # Warn if exceeds HOT tier limit
            if line_count > 200:
                result += f"""
[WARNING] ACTIVE_CONTEXT.md is {line_count} lines - exceeds 200-line HOT tier limit.
Consider moving detailed content to WARM tier docs and keeping only current focus here.
"""
            result += "== End ACTIVE CONTEXT ==\n\n"
            return result
        else:
            # File doesn't exist - provide helpful guidance (non-blocking)
            return """
[INFO] No docs/ACTIVE_CONTEXT.md found.

This project could benefit from a Tiered Documentation System:
- Run `/init-context` to auto-generate from repo analysis
- Or manually create docs/ACTIVE_CONTEXT.md (max 200 lines)
- See: TIERED_DOCUMENTATION_GUIDE.md in the DAIC plugin docs

This is optional - the session will continue normally without it.

"""
    except Exception as e:
        # Never fail the session start due to ACTIVE_CONTEXT issues
        return f"[WARNING] Could not load docs/ACTIVE_CONTEXT.md: {e}\n\n"

# Get developer name from config
try:
    CONFIG_FILE = PROJECT_ROOT / 'sessions' / 'sessions-config.json'
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
            developer_name = config.get('developer_name', 'the developer')
    else:
        developer_name = 'the developer'
except Exception:
    developer_name = 'the developer'

# Initialize context
context = f"""You are beginning a new context window with {developer_name}.

"""

# Ensure state directory exists
ensure_state_dir()

# Clear context warning flags for new session
state_dir = PROJECT_ROOT / '.claude' / 'state'
for flag_file in state_dir.glob('context-warning-*.flag'):
    try:
        flag_file.unlink()
    except OSError:
        pass

# 5. Calculate and cache block timing info for statusline
try:
    block_timer_script = script_dir / 'block-timer.py'
    if block_timer_script.exists():
        result = subprocess.run(
            [sys.executable, str(block_timer_script)],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            block_info = json.loads(result.stdout.strip())
            block_state_file = PROJECT_ROOT / '.claude' / 'state' / 'block-info.json'
            with open(block_state_file, 'w') as f:
                json.dump(block_info, f, indent=2)
except Exception:
    pass  # Non-critical - statusline will work without it

# 5. Check if sessions directory exists
sessions_dir = PROJECT_ROOT / 'sessions'
if sessions_dir.exists():
    # Check for active task
    task_state = get_task_state()
    if task_state.get("task"):
        task_file = sessions_dir / 'tasks' / f"{task_state['task']}.md"
        if task_file.exists():
            # Check if task status is pending and update to in-progress
            task_content = task_file.read_text()
            task_updated = False
            
            # Parse task frontmatter to check status
            if task_content.startswith('---'):
                lines = task_content.split('\n')
                for i, line in enumerate(lines[1:], 1):
                    if line.startswith('---'):
                        break
                    if line.startswith('status: pending'):
                        lines[i] = 'status: in-progress'
                        task_updated = True
                        # Write back the updated content
                        task_file.write_text('\n'.join(lines))
                        task_content = '\n'.join(lines)
                        break
            
            # Output the full task state
            context += f"""Current task state:
```json
{json.dumps(task_state, indent=2)}
```

Loading task file: {task_state['task']}.md
{"=" * 60}
{task_content}
{"=" * 60}
"""
            
            if task_updated:
                context += """
[Note: Task status updated from 'pending' to 'in-progress']
Follow the task-startup protocol to create branches and set up the work environment.
"""
            else:
                context += """
Review the Work Log at the end of the task file above.
Continue from where you left off, updating the work log as you progress.
"""
    else:
        # No active task - list available tasks
        tasks_dir = sessions_dir / 'tasks'
        task_files = []
        if tasks_dir.exists():
            task_files = sorted([f for f in tasks_dir.glob('*.md') if f.name != 'TEMPLATE.md'])
        
        if task_files:
            context += """No active task set. Available tasks:

"""
            for task_file in task_files:
                # Read first few lines to get task info
                with open(task_file, 'r') as f:
                    lines = f.readlines()[:10]
                    task_name = task_file.stem
                    status = 'unknown'
                    for line in lines:
                        if line.startswith('status:'):
                            status = line.split(':')[1].strip()
                            break
                    context += f"  • {task_name} ({status})\n"
            
            context += """
To select a task:
1. Update .claude/state/current_task.json with the task name
2. Or create a new task following sessions/protocols/task-creation.md
"""
        else:
            context += """No tasks found. 

To create your first task:
1. Copy the template: cp sessions/tasks/TEMPLATE.md sessions/tasks/[priority]-[task-name].md
   Priority prefixes: h- (high), m- (medium), l- (low), ?- (investigate)
2. Fill in the task details
3. Update .claude/state/current_task.json
4. Follow sessions/protocols/task-startup.md
"""
else:
    # Sessions directory doesn't exist - likely first run
    context += """Sessions system is not yet initialized.

Run the install script to set up the sessions framework:
.claude/sessions-setup.sh

Or follow the manual setup in the documentation.
"""

# Load ACTIVE_CONTEXT.md (Tiered Documentation System - HOT tier)
# This is loaded regardless of sessions setup - it's project documentation
context += load_active_context()

# Run project-specific session start extension
try:
    ext_result = run_project_extension("session-start")
    if ext_result and ext_result.get("additionalContext"):
        context += ext_result["additionalContext"]
except Exception:
    pass  # Never fail session start due to extension issues

output = {
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": context
    }
}
print(json.dumps(output))
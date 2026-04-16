#!/usr/bin/env python3
"""Shared state management for workflow plugin.

Provides secure state management with proper error handling and path validation.
This module is designed to work both as a plugin and as project-local hooks.
"""
import json
import os
from pathlib import Path
from datetime import datetime
from typing import Optional, Dict, List, Any

# Security: Sensitive paths that should never be modified
SENSITIVE_PATH_PREFIXES = [
    '/etc/',
    '/root/',
    '/var/log/',
    '/usr/bin/',
    '/usr/sbin/',
    '/bin/',
    '/sbin/',
]

SENSITIVE_FILE_PATTERNS = [
    '.env',
    '.env.local',
    '.env.production',
    'credentials',
    'secrets',
    '.pem',
    '.key',
    'id_rsa',
    'id_ed25519',
    '.npmrc',
    '.pypirc',
]


def validate_file_path(file_path: str) -> tuple[bool, Optional[str]]:
    """Validate file path for security.

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not file_path:
        return False, "Empty file path"

    # Check for path traversal
    if '..' in file_path:
        return False, "Path traversal detected (..)"

    # Normalize and resolve the path
    try:
        normalized = Path(file_path).resolve()
        normalized_str = str(normalized)
    except (OSError, ValueError) as e:
        return False, f"Invalid path: {e}"

    # Check sensitive path prefixes
    for prefix in SENSITIVE_PATH_PREFIXES:
        if normalized_str.startswith(prefix):
            return False, f"Sensitive path prefix: {prefix}"

    # Check sensitive file patterns
    filename = normalized.name.lower()
    for pattern in SENSITIVE_FILE_PATTERNS:
        if pattern.lower() in filename:
            return False, f"Sensitive file pattern: {pattern}"

    return True, None


def get_project_root() -> Path:
    """Find project root by looking for .claude directory.

    Uses CLAUDE_PROJECT_DIR if available, otherwise walks up from cwd.
    """
    # Prefer environment variable (set by Claude Code)
    env_root = os.environ.get('CLAUDE_PROJECT_DIR')
    if env_root:
        env_path = Path(env_root)
        if env_path.is_dir() and (env_path / ".claude").exists():
            return env_path

    # Walk up from current directory
    current = Path.cwd()
    while current.parent != current:
        if (current / ".claude").exists():
            return current
        current = current.parent

    # Fallback to current directory
    return Path.cwd()


# Cached project root
_PROJECT_ROOT: Optional[Path] = None


def get_cached_project_root() -> Path:
    """Get cached project root for performance."""
    global _PROJECT_ROOT
    if _PROJECT_ROOT is None:
        _PROJECT_ROOT = get_project_root()
    return _PROJECT_ROOT


def get_state_dir() -> Path:
    """Get the state directory path."""
    return get_cached_project_root() / ".claude" / "state"


def get_task_state_file() -> Path:
    """Get the task state file path."""
    return get_state_dir() / "current_task.json"


def ensure_state_dir() -> None:
    """Ensure the state directory exists."""
    try:
        get_state_dir().mkdir(parents=True, exist_ok=True)
    except OSError as e:
        import sys
        print(f"Warning: Could not create state directory: {e}", file=sys.stderr)


def get_task_state() -> Dict[str, Any]:
    """Get current task state including branch and affected services."""
    try:
        with open(get_task_state_file(), 'r') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {"task": None, "branch": None, "services": [], "updated": None}


def set_task_state(task: str, branch: str, services: List[str]) -> Dict[str, Any]:
    """Set current task state."""
    state = {
        "task": task,
        "branch": branch,
        "services": services,
        "updated": datetime.now().strftime("%Y-%m-%d")
    }
    ensure_state_dir()
    try:
        with open(get_task_state_file(), 'w') as f:
            json.dump(state, f, indent=2)
    except OSError as e:
        import sys
        print(f"Warning: Could not save task state: {e}", file=sys.stderr)
    return state


def clear_task_state() -> None:
    """Clear the current task state."""
    state = {"task": None, "branch": None, "services": [], "updated": None}
    ensure_state_dir()
    try:
        with open(get_task_state_file(), 'w') as f:
            json.dump(state, f, indent=2)
    except OSError as e:
        import sys
        print(f"Warning: Could not clear task state: {e}", file=sys.stderr)


def save_session_checkpoint(checkpoint_data: Dict[str, Any]) -> bool:
    """Save session checkpoint data for recovery."""
    checkpoint_file = get_state_dir() / "session-checkpoint.json"
    ensure_state_dir()
    try:
        checkpoint_data["saved_at"] = datetime.now().isoformat()
        with open(checkpoint_file, 'w') as f:
            json.dump(checkpoint_data, f, indent=2)
        return True
    except OSError as e:
        import sys
        print(f"Warning: Could not save checkpoint: {e}", file=sys.stderr)
        return False


def load_session_checkpoint() -> Optional[Dict[str, Any]]:
    """Load session checkpoint data."""
    checkpoint_file = get_state_dir() / "session-checkpoint.json"
    try:
        with open(checkpoint_file, 'r') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def run_project_extension(hook_name: str, input_data: Optional[Dict] = None) -> Optional[Dict]:
    """Run a project-specific hook extension if it exists.

    Looks for .claude/hooks/project/<hook_name>.py in the project root
    and runs it as a subprocess. Extensions receive the same stdin JSON
    as the core hook and return JSON with optional additionalContext.

    For PreToolUse extensions, exit code 2 means "block the tool" (reason on stderr).

    Returns parsed JSON output dict, or None if no extension or error.
    Extensions are fail-safe: errors are logged to stderr, never crash the core hook.
    """
    import subprocess
    import sys

    try:
        project_root = get_cached_project_root()
        extension_script = project_root / ".claude" / "hooks" / "project" / f"{hook_name}.py"

        if not extension_script.exists():
            return None

        stdin_data = json.dumps(input_data) if input_data else ""
        env = {**os.environ, 'CLAUDE_PROJECT_DIR': str(project_root)}

        result = subprocess.run(
            [sys.executable, str(extension_script)],
            input=stdin_data,
            capture_output=True,
            text=True,
            timeout=10,
            cwd=str(project_root),
            env=env,
        )

        # Exit code 2 = block request (PreToolUse extensions only)
        if result.returncode == 2:
            return {"decision": "block", "reason": result.stderr.strip()}

        if result.stdout.strip():
            try:
                return json.loads(result.stdout.strip())
            except json.JSONDecodeError:
                # Non-JSON stdout treated as plain additionalContext
                return {"additionalContext": result.stdout.strip()}

        return None

    except Exception as e:
        print(f"Warning: Project extension '{hook_name}' error: {e}", file=sys.stderr)
        return None

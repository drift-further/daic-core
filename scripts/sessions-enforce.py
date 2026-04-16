#!/usr/bin/env python3
"""Pre-tool-use hook to enforce security policies.

Features:
- Security validation (path traversal, sensitive files)
- Read-only bash command detection
- Fail-open on transient errors (subagent resilience)
"""
import json
import sys
import re
from pathlib import Path

# Handle imports for both direct execution and symlinked scenarios
script_dir = Path(__file__).resolve().parent
if str(script_dir) not in sys.path:
    sys.path.insert(0, str(script_dir))

try:
    from shared_state import (
        get_project_root, run_project_extension,
        validate_file_path, SENSITIVE_PATH_PREFIXES, SENSITIVE_FILE_PATTERNS
    )
except ImportError as e:
    # Fail-open: if shared_state can't be imported, allow the tool
    print(f"Warning: Could not import shared_state: {e}", file=sys.stderr)
    sys.exit(0)

# Load input
try:
    input_data = json.load(sys.stdin)
except (json.JSONDecodeError, Exception) as e:
    # Fail-open: bad input or read error → allow rather than block
    print(f"Warning: Could not read hook input: {e}", file=sys.stderr)
    sys.exit(0)

tool_name = input_data.get("tool_name", "")
tool_input = input_data.get("tool_input", {})


# ============================================================================
# CONFIGURATION
# ============================================================================

# Default configuration (used if config file doesn't exist)
DEFAULT_CONFIG = {
    "security": {
        "enabled": True,
        "block_sensitive_paths": True,
        "block_path_traversal": True
    },
    "read_only_bash_commands": [
        "ls", "ll", "pwd", "cd", "echo", "cat", "head", "tail", "less", "more",
        "grep", "rg", "find", "which", "whereis", "type", "file", "stat",
        "du", "df", "tree", "basename", "dirname", "realpath", "readlink",
        "whoami", "env", "printenv", "date", "cal", "uptime", "ps", "top",
        "wc", "cut", "sort", "uniq", "comm", "diff", "cmp", "md5sum", "sha256sum",
        "git status", "git log", "git diff", "git show", "git branch",
        "git remote", "git fetch", "git describe", "git rev-parse", "git blame",
        "docker ps", "docker images", "docker logs", "npm list", "npm ls",
        "pip list", "pip show", "yarn list", "curl", "wget", "jq", "awk",
        "sed -n", "tar -t", "unzip -l",
        "python scripts/test", "python scripts/playtest",
        "python -c",
        # Windows equivalents
        "dir", "where", "findstr", "fc", "comp", "certutil -hashfile",
        "Get-ChildItem", "Get-Location", "Get-Content", "Select-String",
        "Get-Command", "Get-Process", "Get-Date", "Get-Item"
    ]
}


def load_config(config_file):
    """Load configuration from file or use defaults."""
    if config_file.exists():
        try:
            with open(config_file, 'r') as f:
                config = json.load(f)
                # Merge with defaults for missing keys
                for key, value in DEFAULT_CONFIG.items():
                    if key not in config:
                        config[key] = value
                return config
        except (json.JSONDecodeError, OSError) as e:
            print(f"Warning: Could not load config: {e}", file=sys.stderr)
    return DEFAULT_CONFIG


def check_bash_security(command: str) -> tuple[bool, str]:
    """Check bash command for security issues.

    Returns:
        Tuple of (is_blocked, reason)
    """
    dangerous_patterns = [
        (r'\brm\s+-rf\s+/', "Dangerous: rm -rf on root path"),
        (r'\brm\s+-rf\s+~', "Dangerous: rm -rf on home directory"),
        (r'\bchmod\s+777', "Dangerous: chmod 777 is insecure"),
        (r'\bcurl\s+.*\|\s*(ba)?sh', "Dangerous: piping curl to shell"),
        (r'\bwget\s+.*\|\s*(ba)?sh', "Dangerous: piping wget to shell"),
        (r'>\s*/etc/', "Dangerous: writing to /etc/"),
        (r'>\s*/usr/', "Dangerous: writing to /usr/"),
        (r'\bsudo\s+rm', "Dangerous: sudo rm"),
        (r'\bdd\s+.*of=/dev/', "Dangerous: dd to device"),
        (r'\bmkfs\.', "Dangerous: filesystem formatting"),
    ]

    for pattern, reason in dangerous_patterns:
        if re.search(pattern, command, re.IGNORECASE):
            return True, reason

    return False, ""


# ============================================================================
# MAIN ENFORCEMENT LOGIC — wrapped in try/except for fail-open resilience.
# Security-critical blocks (dangerous bash, sensitive paths) use sys.exit(2)
# inside the try and will still block. Transient errors (file access, git
# timeouts, import issues) default to allowing the tool.
# ============================================================================
try:
    PROJECT_ROOT = get_project_root()
    CONFIG_FILE = PROJECT_ROOT / "sessions" / "sessions-config.json"
    config = load_config(CONFIG_FILE)
    security_config = config.get("security", DEFAULT_CONFIG["security"])

    # ========================================================================
    # SECURITY CHECKS (for file operations)
    # ========================================================================
    if security_config.get("enabled", True) and tool_name in ["Write", "Edit", "MultiEdit"]:
        file_path = tool_input.get("file_path", "")

        if file_path:
            if security_config.get("block_path_traversal", True):
                is_valid, error = validate_file_path(file_path)
                if not is_valid:
                    print(f"[Security Block] {error}", file=sys.stderr)
                    print(f"File path: {file_path}", file=sys.stderr)
                    sys.exit(2)

    # ========================================================================
    # BASH COMMAND HANDLING
    # ========================================================================
    if tool_name == "Bash":
        command = tool_input.get("command", "").strip()

        # Security check for bash commands
        if security_config.get("enabled", True):
            is_blocked, reason = check_bash_security(command)
            if is_blocked:
                print(f"[Security Block] {reason}", file=sys.stderr)
                print(f"Command: {command}", file=sys.stderr)
                sys.exit(2)

        # Check for write patterns
        write_patterns = [
            r'>\s*[^>]',  # Output redirection
            r'>>',        # Append redirection
            r'\btee\b',   # tee command
            r'\bmv\b',    # move/rename
            r'\bcp\b',    # copy
            r'\brm\b',    # remove
            r'\bmkdir\b', # make directory
            r'\btouch\b', # create/update file
            r'\bsed\s+(?!-n)',  # sed without -n flag
            r'\bnpm\s+install',  # npm install
            r'\bpip\s+install',  # pip install
            r'\bapt\s+install',  # apt install
            r'\byum\s+install',  # yum install
            r'\bbrew\s+install', # brew install
        ]

        has_write_pattern = any(re.search(pattern, command) for pattern in write_patterns)

        if not has_write_pattern:
            # Check if ALL commands in chain are read-only
            command_parts = re.split(r'(?:&&|\|\||;|\|)', command)
            all_read_only = True

            for part in command_parts:
                part = part.strip()
                if not part:
                    continue

                is_part_read_only = any(
                    part.startswith(prefix)
                    for prefix in config.get("read_only_bash_commands", DEFAULT_CONFIG["read_only_bash_commands"])
                )

                if not is_part_read_only:
                    all_read_only = False
                    break

            if all_read_only:
                sys.exit(0)


except SystemExit:
    raise
except Exception as e:
    # Fail-open: unexpected errors allow the tool rather than blocking work.
    # Intentional denials (sys.exit(2)) already fired above.
    print(f"Warning: sessions-enforce error (allowing tool): {e}", file=sys.stderr)
    sys.exit(0)

# Run project-specific PreToolUse extension
try:
    ext_result = run_project_extension("sessions-enforce", input_data)
    if ext_result:
        if ext_result.get("decision") == "block":
            print(ext_result.get("reason", "Blocked by project extension"), file=sys.stderr)
            sys.exit(2)
        if ext_result.get("additionalContext"):
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "additionalContext": ext_result["additionalContext"],
                }
            }
            print(json.dumps(output))
except SystemExit:
    raise
except Exception:
    pass  # Fail-open: extension errors never block tools

# Allow tool to proceed
sys.exit(0)

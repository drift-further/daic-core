#!/bin/bash
# DAIC Workflow Plugin Installer (Symlink Mode)
# Installs the DAIC workflow hooks into a Claude Code project using symlinks
# for live updates from the source repository.
#
# Features:
# - Symlinks scripts for live updates (no reinstall needed)
# - Merges hooks into existing settings.json (preserves statusLine, etc.)
# - Creates backup before modifying settings
# - Sets safe default permissions (read-only git/system, /tmp/, python, gh)
# - Optionally sets up Python venv (--venv flag)
#
# Usage:
#   ./install.sh [project-path] [--venv]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="daic-workflow"

# Parse arguments
PROJECT_PATH=""
SETUP_VENV=false

for arg in "$@"; do
    case "$arg" in
        --venv)
            SETUP_VENV=true
            ;;
        *)
            PROJECT_PATH="$arg"
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}DAIC Workflow Plugin Installer${NC}"
echo "================================"
echo -e "${BLUE}Source: $SCRIPT_DIR${NC}"

# Find project root (look for .claude directory, but stop at git boundary)
find_project_root() {
    local dir="$1"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.claude" ]]; then
            echo "$dir"
            return 0
        fi
        # Stop at git root - don't search beyond the repo boundary
        if [[ -d "$dir/.git" ]]; then
            return 1
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Determine installation target
if [[ -n "$PROJECT_PATH" ]]; then
    PROJECT_ROOT="$PROJECT_PATH"
    # Create .claude if it doesn't exist
    mkdir -p "$PROJECT_ROOT/.claude"
else
    PROJECT_ROOT=$(find_project_root "$(pwd)") || {
        echo -e "${RED}Error: Could not find project root (.claude directory)${NC}"
        echo "Usage: $0 [project-path]"
        exit 1
    }
fi

echo "Project root: $PROJECT_ROOT"

# Sanity check - don't install into self
if [[ "$PROJECT_ROOT" == "$SCRIPT_DIR" ]]; then
    echo -e "${RED}Error: Cannot install plugin into itself${NC}"
    exit 1
fi

# Create required directories
echo -e "\n${YELLOW}Creating directories...${NC}"
mkdir -p "$PROJECT_ROOT/.claude/state"
mkdir -p "$PROJECT_ROOT/.claude/hooks"
mkdir -p "$PROJECT_ROOT/sessions/tasks"

# Create 3-doc pattern directories (Tiered Documentation System)
echo -e "${YELLOW}Setting up Tiered Documentation (3-doc pattern)...${NC}"
mkdir -p "$PROJECT_ROOT/docs/architecture"
mkdir -p "$PROJECT_ROOT/docs/patterns"
mkdir -p "$PROJECT_ROOT/docs/backlog/archive"

# Copy ACTIVE_CONTEXT template if not present (HOT tier)
if [[ ! -f "$PROJECT_ROOT/docs/ACTIVE_CONTEXT.md" ]]; then
    if [[ -f "$SCRIPT_DIR/templates/ACTIVE_CONTEXT.template.md" ]]; then
        cp "$SCRIPT_DIR/templates/ACTIVE_CONTEXT.template.md" "$PROJECT_ROOT/docs/ACTIVE_CONTEXT.md"
        echo -e "  ${GREEN}✓${NC} Created docs/ACTIVE_CONTEXT.md (HOT tier - edit with current context)"
    fi
else
    echo -e "  ${GREEN}✓${NC} docs/ACTIVE_CONTEXT.md already exists"
fi

# Copy Tiered Documentation Guide if not present
if [[ ! -f "$PROJECT_ROOT/docs/TIERED_DOCUMENTATION_GUIDE.md" ]]; then
    if [[ -f "$SCRIPT_DIR/docs/TIERED_DOCUMENTATION_GUIDE.md" ]]; then
        cp "$SCRIPT_DIR/docs/TIERED_DOCUMENTATION_GUIDE.md" "$PROJECT_ROOT/docs/TIERED_DOCUMENTATION_GUIDE.md"
        echo -e "  ${GREEN}✓${NC} Created docs/TIERED_DOCUMENTATION_GUIDE.md"
    fi
else
    echo -e "  ${GREEN}✓${NC} docs/TIERED_DOCUMENTATION_GUIDE.md already exists"
fi

echo -e "  ${BLUE}3-doc pattern: HOT (docs/ACTIVE_CONTEXT.md) | WARM (docs/architecture/, docs/patterns/) | COLD (docs/backlog/archive/)${NC}"

# Deploy local-permissions template and docs if not present
if [[ ! -f "$PROJECT_ROOT/.claude/local-permissions.json" ]]; then
    if [[ -f "$SCRIPT_DIR/templates/local-permissions.json" ]]; then
        cp "$SCRIPT_DIR/templates/local-permissions.json" "$PROJECT_ROOT/.claude/local-permissions.json"
        echo -e "  ${GREEN}✓${NC} Created .claude/local-permissions.json (add project-specific tool rules here)"
    fi
else
    echo -e "  ${GREEN}✓${NC} local-permissions.json already exists"
fi
if [[ ! -f "$PROJECT_ROOT/.claude/local-permissions.md" ]]; then
    if [[ -f "$SCRIPT_DIR/templates/local-permissions.md" ]]; then
        cp "$SCRIPT_DIR/templates/local-permissions.md" "$PROJECT_ROOT/.claude/local-permissions.md"
        echo -e "  ${GREEN}✓${NC} Created .claude/local-permissions.md (usage guide)"
    fi
fi

# Symlink hook scripts (instead of copying)
# Skip dead scripts that are no longer hooked
SKIP_SCRIPTS="stop-check.py session-end.py task-transcript-link.py"

echo -e "${YELLOW}Symlinking hook scripts...${NC}"
for script in "$SCRIPT_DIR/scripts/"*.py; do
    script_name=$(basename "$script")

    # Skip deprecated/unused scripts
    if echo "$SKIP_SCRIPTS" | grep -qw "$script_name"; then
        continue
    fi

    target="$PROJECT_ROOT/.claude/hooks/$script_name"

    # Remove existing file/symlink
    if [[ -e "$target" ]] || [[ -L "$target" ]]; then
        rm -f "$target"
    fi

    ln -s "$script" "$target"
    echo -e "  ${GREEN}✓${NC} $script_name -> $script"
done

# Clean up stale symlinks from previously-installed dead scripts
for stale in $SKIP_SCRIPTS; do
    stale_target="$PROJECT_ROOT/.claude/hooks/$stale"
    if [[ -e "$stale_target" ]] || [[ -L "$stale_target" ]]; then
        rm -f "$stale_target"
        echo -e "  ${YELLOW}✗${NC} Removed stale $stale"
    fi
done

# Clean up old percentage-based context warning flags (replaced by token-based thresholds)
OLD_FLAGS="context-warning-65.flag context-warning-75.flag context-warning-90.flag"
for old_flag in $OLD_FLAGS; do
    old_flag_path="$PROJECT_ROOT/.claude/state/$old_flag"
    if [[ -e "$old_flag_path" ]]; then
        rm -f "$old_flag_path"
        echo -e "  ${YELLOW}✗${NC} Removed old $old_flag (replaced by token-based warnings)"
    fi
done

# Make scripts executable (in case they aren't)
chmod +x "$SCRIPT_DIR/scripts/"*.py
chmod +x "$SCRIPT_DIR/scripts/"*.sh 2>/dev/null || true

# Create project hooks extension directory (never modified by install)
echo -e "${YELLOW}Setting up project hook extensions...${NC}"
mkdir -p "$PROJECT_ROOT/.claude/hooks/project"
if [[ ! -f "$PROJECT_ROOT/.claude/hooks/project/README.md" ]]; then
    if [[ -f "$SCRIPT_DIR/templates/project-hooks-README.md" ]]; then
        cp "$SCRIPT_DIR/templates/project-hooks-README.md" "$PROJECT_ROOT/.claude/hooks/project/README.md"
        echo -e "  ${GREEN}✓${NC} Created .claude/hooks/project/README.md"
    fi
else
    echo -e "  ${GREEN}✓${NC} Project hooks directory already exists"
fi
echo -e "  ${BLUE}Project-specific hook extensions go in .claude/hooks/project/${NC}"

# Symlink statusline script
echo -e "${YELLOW}Installing statusline...${NC}"
STATUSLINE_SRC="$SCRIPT_DIR/scripts/statusline-script.py"
STATUSLINE_TARGET="$PROJECT_ROOT/.claude/statusline-script.py"
if [[ -f "$STATUSLINE_SRC" ]]; then
    # Remove old .sh symlink if present
    OLD_TARGET="$PROJECT_ROOT/.claude/statusline-script.sh"
    if [[ -e "$OLD_TARGET" ]] || [[ -L "$OLD_TARGET" ]]; then
        rm -f "$OLD_TARGET"
    fi
    if [[ -e "$STATUSLINE_TARGET" ]] || [[ -L "$STATUSLINE_TARGET" ]]; then
        rm -f "$STATUSLINE_TARGET"
    fi
    ln -s "$STATUSLINE_SRC" "$STATUSLINE_TARGET"
    echo -e "  ${GREEN}✓${NC} statusline-script.py -> $STATUSLINE_SRC"
else
    echo -e "  ${YELLOW}⚠${NC} statusline-script.py not found in source"
fi

# Define the hooks we want to install
DAIC_HOOKS=$(cat << 'HOOKS_JSON'
{
  "UserPromptSubmit": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/user-messages.py",
          "timeout": 30
        }
      ]
    }
  ],
  "PreToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit|Task|Bash",
      "hooks": [
        {
          "type": "command",
          "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/sessions-enforce.py",
          "timeout": 10
        }
      ]
    }
  ],
  "PostToolUse": [
    {
      "matcher": "Write|Edit|MultiEdit|NotebookEdit|Bash",
      "hooks": [
        {
          "type": "command",
          "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/post-tool-use.py",
          "timeout": 10
        }
      ]
    }
  ],
  "SessionStart": [
    {
      "matcher": "startup|clear",
      "hooks": [
        {
          "type": "command",
          "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.py",
          "timeout": 30
        }
      ]
    }
  ],
  "PreCompact": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/pre-compact.py",
          "timeout": 30
        }
      ]
    }
  ]
}
HOOKS_JSON
)

# Merge or create settings.json
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"

if [[ -f "$SETTINGS_FILE" ]]; then
    echo -e "${YELLOW}Merging hooks into existing settings.json...${NC}"
    cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup.$(date +%Y%m%d%H%M%S)"

    # Use Python to merge (preserves other settings, adds statusLine if missing)
    python3 << MERGE_SCRIPT
import json
import sys

# Read existing settings
with open('$SETTINGS_FILE', 'r') as f:
    settings = json.load(f)

# Parse DAIC hooks
daic_hooks = json.loads('''$DAIC_HOOKS''')

# Merge hooks (DAIC hooks replace any existing hooks of the same type)
if 'hooks' not in settings:
    settings['hooks'] = {}

for hook_type, hook_config in daic_hooks.items():
    settings['hooks'][hook_type] = hook_config

# Remove deprecated hooks
for removed in ['Stop', 'SessionEnd']:
    if removed in settings['hooks']:
        del settings['hooks'][removed]
        print(f"  Removed deprecated {removed} hook")

# Set statusLine config (always update to latest)
settings['statusLine'] = {
    "type": "command",
    "command": "\$CLAUDE_PROJECT_DIR/.claude/statusline-script.py",
    "padding": 0
}
print("  Updated statusLine config")

# Enable agent teams (multi-agent research groups)
if 'env' not in settings:
    settings['env'] = {}
if 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' not in settings.get('env', {}):
    settings['env']['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1'
    print("  Enabled agent teams (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)")
else:
    print("  Agent teams already configured")

# Merge default permissions (additive - never removes existing allow rules)
DAIC_DEFAULT_PERMISSIONS = [
    # /tmp/ access (temp files, test outputs, script scratch space)
    "Read(//tmp/**)",
    "Edit(//tmp/**)",
    "Write(//tmp/**)",
    # Web search and fetch (read-only, no risk)
    "WebSearch",
    "WebFetch",
    # Local dev servers (kept for specificity)
    "WebFetch(domain:localhost)",
    "WebFetch(domain:127.0.0.1)",
    # Git read-only commands
    "Bash(git status)",
    "Bash(git status *)",
    "Bash(git diff *)",
    "Bash(git log *)",
    "Bash(git branch *)",
    "Bash(git show *)",
    "Bash(git blame *)",
    "Bash(git remote -v)",
    "Bash(git remote -v *)",
    # System info (read-only)
    "Bash(ls *)",
    "Bash(pwd)",
    "Bash(which *)",
    "Bash(wc *)",
    "Bash(file *)",
    "Bash(tree *)",
    "Bash(uname *)",
    "Bash(whoami)",
    # Version and help (informational)
    "Bash(* --version)",
    "Bash(* --help)",
    "Bash(* --help *)",
    # File creation (non-destructive)
    "Bash(mkdir *)",
    "Bash(touch *)",
    "Bash(echo *)",
    # Python (DAIC hooks use python3)
    "Bash(python *)",
    "Bash(python3 *)",
    # Data inspection tools
    "Bash(cat *)",
    "Bash(head *)",
    "Bash(tail *)",
    "Bash(diff *)",
    "Bash(sort *)",
    "Bash(jq *)",
    # Search tools
    "Bash(find *)",
    "Bash(grep *)",
    "Bash(rg *)",
    # GitHub CLI
    "Bash(gh *)",
    # File operations (non-destructive)
    "Bash(cp *)",
    "Bash(mv *)",
    "Bash(ln *)",
    "Bash(chmod *)",
    "Bash(sed *)",
    "Bash(awk *)",
    "Bash(tee *)",
    "Bash(xargs *)",
    # Path/date utilities
    "Bash(date *)",
    "Bash(basename *)",
    "Bash(dirname *)",
    "Bash(realpath *)",
    "Bash(stat *)",
    "Bash(env *)",
    # Unrestricted web fetch (read-only, public data)
    "WebFetch",
    # Playwright MCP tools (browser automation)
    "mcp__plugin_playwright_playwright__browser_close",
    "mcp__plugin_playwright_playwright__browser_resize",
    "mcp__plugin_playwright_playwright__browser_console_messages",
    "mcp__plugin_playwright_playwright__browser_handle_dialog",
    "mcp__plugin_playwright_playwright__browser_evaluate",
    "mcp__plugin_playwright_playwright__browser_file_upload",
    "mcp__plugin_playwright_playwright__browser_fill_form",
    "mcp__plugin_playwright_playwright__browser_install",
    "mcp__plugin_playwright_playwright__browser_press_key",
    "mcp__plugin_playwright_playwright__browser_type",
    "mcp__plugin_playwright_playwright__browser_navigate",
    "mcp__plugin_playwright_playwright__browser_navigate_back",
    "mcp__plugin_playwright_playwright__browser_network_requests",
    "mcp__plugin_playwright_playwright__browser_run_code",
    "mcp__plugin_playwright_playwright__browser_take_screenshot",
    "mcp__plugin_playwright_playwright__browser_snapshot",
    "mcp__plugin_playwright_playwright__browser_click",
    "mcp__plugin_playwright_playwright__browser_drag",
    "mcp__plugin_playwright_playwright__browser_hover",
    "mcp__plugin_playwright_playwright__browser_select_option",
    "mcp__plugin_playwright_playwright__browser_tabs",
    "mcp__plugin_playwright_playwright__browser_wait_for",
]

if 'permissions' not in settings:
    settings['permissions'] = {}
if 'allow' not in settings['permissions']:
    settings['permissions']['allow'] = []

existing = set(settings['permissions']['allow'])
added = 0
for rule in DAIC_DEFAULT_PERMISSIONS:
    if rule not in existing:
        settings['permissions']['allow'].append(rule)
        added += 1
print(f"  Added {added} default permission rules ({len(existing)} already existed)")

# Add /tmp/ and parent directories to additionalDirectories
if 'additionalDirectories' not in settings:
    settings['additionalDirectories'] = []
if '/tmp/' not in settings['additionalDirectories']:
    settings['additionalDirectories'].append('/tmp/')
    print("  Added /tmp/ to additionalDirectories")

# Add ../ and ../../ (resolved to absolute paths) for cross-project reads
import os
project_root = os.path.realpath('$PROJECT_ROOT')
parent_dir = os.path.dirname(project_root)
grandparent_dir = os.path.dirname(parent_dir)

# Helper: build Read permission rule with correct // prefix for absolute paths
# Claude Code uses Read(//path/**) where // means root, so /abs/path becomes //abs/path
def read_rule_for(path, suffix='**'):
    # path is absolute (starts with /), so // + path would triple-slash
    # Correct form: Read(/ + /abs/path + /suffix) = Read(//abs/path/suffix)
    return f"Read(/{path}/{suffix})"

for label, d in [("parent (../)", parent_dir), ("grandparent (../../)", grandparent_dir)]:
    # Add to additionalDirectories
    if d not in settings['additionalDirectories']:
        settings['additionalDirectories'].append(d)
        print(f"  Added {d} to additionalDirectories ({label})")
    # Add Read permission rule
    rule = read_rule_for(d)
    if rule not in existing:
        settings['permissions']['allow'].append(rule)
        print(f"  Added Read permission for {d} ({label})")

# Explicitly allow .claude dirs (dotfiles can be skipped by some tools)
for label, d in [("parent", parent_dir), ("grandparent", grandparent_dir)]:
    claude_rule = read_rule_for(d, '**/.claude/**')
    if claude_rule not in existing:
        settings['permissions']['allow'].append(claude_rule)
        print(f"  Added .claude/ read permission for {label} projects")

# Global ~/.claude/ directory (memory, teams, tasks)
home_claude = os.path.expanduser('~/.claude')
if home_claude not in settings['additionalDirectories']:
    settings['additionalDirectories'].append(home_claude)
    print(f"  Added {home_claude} to additionalDirectories (global config)")
home_claude_rule = read_rule_for(home_claude)
if home_claude_rule not in existing:
    settings['permissions']['allow'].append(home_claude_rule)
    print(f"  Added Read permission for {home_claude} (global config)")

# Write/Edit permissions for project directory (core dev workflow)
# Hooks still protect sensitive files (.env, .key, credentials, etc.)
def write_rule_for(path, suffix='**'):
    return f"Write(/{path}/{suffix})"
def edit_rule_for(path, suffix='**'):
    return f"Edit(/{path}/{suffix})"

for label, d in [("project", project_root), ("~/.claude", home_claude)]:
    for rule_fn, rule_name in [(write_rule_for, "Write"), (edit_rule_for, "Edit")]:
        rule = rule_fn(d)
        if rule not in existing:
            settings['permissions']['allow'].append(rule)
            print(f"  Added {rule_name} permission for {d} ({label})")

# DAIC plugin source directory (canonical hook scripts)
daic_source = os.path.realpath('$SCRIPT_DIR')
if daic_source not in settings['additionalDirectories']:
    settings['additionalDirectories'].append(daic_source)
    print(f"  Added {daic_source} to additionalDirectories (DAIC source)")
daic_rule = read_rule_for(daic_source)
if daic_rule not in existing:
    settings['permissions']['allow'].append(daic_rule)
    print(f"  Added Read permission for {daic_source} (DAIC source)")

# Merge project-local permissions (.claude/local-permissions.json)
local_perms_path = os.path.join('$PROJECT_ROOT', '.claude', 'local-permissions.json')
if os.path.exists(local_perms_path):
    with open(local_perms_path, 'r') as f:
        local_perms = json.load(f)
    local_allow = local_perms.get('allow', [])
    current = set(settings['permissions']['allow'])
    added_local = 0
    for rule in local_allow:
        if rule not in current:
            settings['permissions']['allow'].append(rule)
            added_local += 1
    print(f"  Merged {added_local} project-local permission rules from .claude/local-permissions.json")

# Write merged settings
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)

print("  Merged DAIC hooks")
MERGE_SCRIPT

    echo -e "  ${GREEN}✓${NC} Settings merged successfully"
else
    echo -e "${YELLOW}Creating new settings.json...${NC}"
    # Create settings with hooks, statusLine, and default permissions
    python3 << CREATE_SCRIPT
import json

daic_hooks = json.loads('''$DAIC_HOOKS''')

settings = {
    "hooks": daic_hooks,
    "statusLine": {
        "type": "command",
        "command": "\$CLAUDE_PROJECT_DIR/.claude/statusline-script.py",
        "padding": 0
    },
    "env": {
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
    },
    "permissions": {
        "allow": [
            # /tmp/ access (temp files, test outputs, script scratch space)
            "Read(//tmp/**)",
            "Edit(//tmp/**)",
            "Write(//tmp/**)",
            # Web search (read-only, no risk)
            "WebSearch",
            # Local dev servers
            "WebFetch(domain:localhost)",
            "WebFetch(domain:127.0.0.1)",
            # Git read-only commands
            "Bash(git status)",
            "Bash(git status *)",
            "Bash(git diff *)",
            "Bash(git log *)",
            "Bash(git branch *)",
            "Bash(git show *)",
            "Bash(git blame *)",
            "Bash(git remote -v)",
            "Bash(git remote -v *)",
            # System info (read-only)
            "Bash(ls *)",
            "Bash(pwd)",
            "Bash(which *)",
            "Bash(wc *)",
            "Bash(file *)",
            "Bash(tree *)",
            "Bash(uname *)",
            "Bash(whoami)",
            # Version and help (informational)
            "Bash(* --version)",
            "Bash(* --help)",
            "Bash(* --help *)",
            # File creation (non-destructive)
            "Bash(mkdir *)",
            "Bash(touch *)",
            "Bash(echo *)",
            # Python (DAIC hooks use python3)
            "Bash(python *)",
            "Bash(python3 *)",
            # Data inspection tools
            "Bash(cat *)",
            "Bash(head *)",
            "Bash(tail *)",
            "Bash(diff *)",
            "Bash(sort *)",
            "Bash(jq *)",
            # GitHub CLI
            "Bash(gh *)",
            # File operations (non-destructive)
            "Bash(cp *)",
            "Bash(mv *)",
            "Bash(ln *)",
            "Bash(chmod *)",
            "Bash(sed *)",
            "Bash(awk *)",
            "Bash(tee *)",
            "Bash(xargs *)",
            # Path/date utilities
            "Bash(date *)",
            "Bash(basename *)",
            "Bash(dirname *)",
            "Bash(realpath *)",
            "Bash(stat *)",
            "Bash(env *)",
            # Unrestricted web fetch (read-only, public data)
            "WebFetch",
            # Playwright MCP tools (browser automation)
            "mcp__plugin_playwright_playwright__browser_close",
            "mcp__plugin_playwright_playwright__browser_resize",
            "mcp__plugin_playwright_playwright__browser_console_messages",
            "mcp__plugin_playwright_playwright__browser_handle_dialog",
            "mcp__plugin_playwright_playwright__browser_evaluate",
            "mcp__plugin_playwright_playwright__browser_file_upload",
            "mcp__plugin_playwright_playwright__browser_fill_form",
            "mcp__plugin_playwright_playwright__browser_install",
            "mcp__plugin_playwright_playwright__browser_press_key",
            "mcp__plugin_playwright_playwright__browser_type",
            "mcp__plugin_playwright_playwright__browser_navigate",
            "mcp__plugin_playwright_playwright__browser_navigate_back",
            "mcp__plugin_playwright_playwright__browser_network_requests",
            "mcp__plugin_playwright_playwright__browser_run_code",
            "mcp__plugin_playwright_playwright__browser_take_screenshot",
            "mcp__plugin_playwright_playwright__browser_snapshot",
            "mcp__plugin_playwright_playwright__browser_click",
            "mcp__plugin_playwright_playwright__browser_drag",
            "mcp__plugin_playwright_playwright__browser_hover",
            "mcp__plugin_playwright_playwright__browser_select_option",
            "mcp__plugin_playwright_playwright__browser_tabs",
            "mcp__plugin_playwright_playwright__browser_wait_for",
        ]
    },
    "additionalDirectories": ["/tmp/"]
}

# Add ../ and ../../ (resolved to absolute paths) for cross-project reads
import os
project_root = os.path.realpath('$PROJECT_ROOT')
parent_dir = os.path.dirname(project_root)
grandparent_dir = os.path.dirname(parent_dir)

# Helper: build Read permission rule with correct // prefix for absolute paths
def read_rule_for(path, suffix='**'):
    return f"Read(/{path}/{suffix})"

for d in [parent_dir, grandparent_dir]:
    if d not in settings['additionalDirectories']:
        settings['additionalDirectories'].append(d)
    rule = read_rule_for(d)
    if rule not in settings['permissions']['allow']:
        settings['permissions']['allow'].append(rule)
    # Explicit .claude dir coverage
    claude_rule = read_rule_for(d, '**/.claude/**')
    if claude_rule not in settings['permissions']['allow']:
        settings['permissions']['allow'].append(claude_rule)

# Global ~/.claude/ directory (memory, teams, tasks)
home_claude = os.path.expanduser('~/.claude')
if home_claude not in settings['additionalDirectories']:
    settings['additionalDirectories'].append(home_claude)
home_claude_rule = read_rule_for(home_claude)
if home_claude_rule not in settings['permissions']['allow']:
    settings['permissions']['allow'].append(home_claude_rule)

# Write/Edit permissions for project directory and ~/.claude/
def write_rule_for(path, suffix='**'):
    return f"Write(/{path}/{suffix})"
def edit_rule_for(path, suffix='**'):
    return f"Edit(/{path}/{suffix})"

for d in [project_root, home_claude]:
    for rule_fn in [write_rule_for, edit_rule_for]:
        rule = rule_fn(d)
        if rule not in settings['permissions']['allow']:
            settings['permissions']['allow'].append(rule)

# DAIC plugin source directory (canonical hook scripts)
daic_source = os.path.realpath('$SCRIPT_DIR')
if daic_source not in settings['additionalDirectories']:
    settings['additionalDirectories'].append(daic_source)
daic_rule = read_rule_for(daic_source)
if daic_rule not in settings['permissions']['allow']:
    settings['permissions']['allow'].append(daic_rule)

# Merge project-local permissions (.claude/local-permissions.json)
local_perms_path = os.path.join('$PROJECT_ROOT', '.claude', 'local-permissions.json')
if os.path.exists(local_perms_path):
    with open(local_perms_path, 'r') as f:
        local_perms = json.load(f)
    local_allow = local_perms.get('allow', [])
    current = set(settings['permissions']['allow'])
    added_local = 0
    for rule in local_allow:
        if rule not in current:
            settings['permissions']['allow'].append(rule)
            added_local += 1
    print(f"  Merged {added_local} project-local permission rules from .claude/local-permissions.json")

with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
CREATE_SCRIPT
    echo -e "  ${GREEN}✓${NC} Settings created with hooks and statusLine"
fi

# Create default sessions config if it doesn't exist
SESSIONS_CONFIG="$PROJECT_ROOT/sessions/sessions-config.json"
if [[ ! -f "$SESSIONS_CONFIG" ]]; then
    echo -e "${YELLOW}Creating default sessions-config.json...${NC}"
    cp "$SCRIPT_DIR/templates/sessions-config.json" "$SESSIONS_CONFIG"
fi

# Store source location for reference
echo "$SCRIPT_DIR" > "$PROJECT_ROOT/.claude/state/daic-plugin-source.txt"

# Set up Python venv if requested
if [[ "$SETUP_VENV" == true ]]; then
    echo -e "\n${YELLOW}Setting up Python virtual environment...${NC}"
    VENV_DIR=""
    if [[ -d "$PROJECT_ROOT/.venv" ]]; then
        VENV_DIR="$PROJECT_ROOT/.venv"
        echo -e "  ${GREEN}✓${NC} .venv already exists"
    elif [[ -d "$PROJECT_ROOT/venv" ]]; then
        VENV_DIR="$PROJECT_ROOT/venv"
        echo -e "  ${GREEN}✓${NC} venv already exists"
    else
        # Create .venv
        if command -v python3 &> /dev/null; then
            python3 -m venv "$PROJECT_ROOT/.venv"
            VENV_DIR="$PROJECT_ROOT/.venv"
            echo -e "  ${GREEN}✓${NC} Created .venv with $(python3 --version)"
        else
            echo -e "  ${RED}✗${NC} python3 not found - cannot create venv"
        fi
    fi

    if [[ -n "$VENV_DIR" ]]; then
        # Activate and upgrade pip
        source "$VENV_DIR/bin/activate"
        pip install --upgrade pip --quiet 2>/dev/null
        echo -e "  ${GREEN}✓${NC} Activated $VENV_DIR (pip upgraded)"

        # Install common dev tools if not present
        if [[ ! -f "$VENV_DIR/bin/black" ]]; then
            pip install black --quiet 2>/dev/null && \
                echo -e "  ${GREEN}✓${NC} Installed black (auto-formatter)" || true
        fi

        echo -e "  ${BLUE}Activate manually: source $VENV_DIR/bin/activate${NC}"
    fi
fi

echo -e "\n${GREEN}Installation complete!${NC}"
echo ""
echo -e "${BLUE}Plugin source: $SCRIPT_DIR${NC}"
echo -e "${BLUE}Hooks are symlinked - updates to source will take effect immediately${NC}"
echo ""
echo "Next steps:"
echo "  1. Edit docs/ACTIVE_CONTEXT.md with your current project context"
echo "  2. Start Claude Code - the hooks will load automatically"
echo ""
echo "Features enabled:"
echo "  - Default permissions: /tmp/ access, read-only git/system, python, gh, Playwright MCP"
echo "  - Write/Edit: project directory, ~/.claude/ (hooks protect .env/.key/credentials)"
echo "  - Read access: parent/grandparent dirs, their .claude/ dirs, ~/.claude/, DAIC source"
echo "  - File ops: cp, mv, ln, chmod, sed, awk, tee, xargs (no rm — stays manual)"
echo "  - Context monitoring: 100k/120k/140k/150k/155k/160k token warnings with handoff prompts"
echo "  - Security enforcement: path traversal, dangerous commands blocked"
echo "  - 3-doc pattern: HOT/WARM/COLD tiered documentation in docs/"
echo "  - Agent teams: multi-agent research groups enabled"
echo "  - Project hook extensions: .claude/hooks/project/ (see README.md inside)"
if [[ -f "$PROJECT_ROOT/.claude/local-permissions.json" ]]; then
echo "  - Local permissions: merged from .claude/local-permissions.json"
else
echo "  - Local permissions: create .claude/local-permissions.json to add project-specific tool rules"
fi
if [[ "$SETUP_VENV" == true ]] && [[ -n "$VENV_DIR" ]]; then
echo "  - Python venv: $VENV_DIR (with black auto-formatter)"
fi

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

# ---------------------------------------------------------------------------
# Permission profiles
# ---------------------------------------------------------------------------
# Each profile is a bash array. Task 10 selects the right one at install time.

PERMISSIONS_STRICT=(
    "Read(//tmp/**)"
    "Edit(//tmp/**)"
    "Write(//tmp/**)"
    "WebSearch"
    "Bash(git status)"
    "Bash(git status *)"
    "Bash(git diff *)"
    "Bash(git log *)"
    "Bash(git branch *)"
    "Bash(git show *)"
    "Bash(git blame *)"
    "Bash(python *)"
    "Bash(python3 *)"
    "Bash(gh *)"
)

PERMISSIONS_STANDARD=(
    "Read(//tmp/**)"
    "Edit(//tmp/**)"
    "Write(//tmp/**)"
    "WebSearch"
    "WebFetch"
    "WebFetch(domain:localhost)"
    "WebFetch(domain:127.0.0.1)"
    "Bash(git status)"
    "Bash(git status *)"
    "Bash(git diff *)"
    "Bash(git log *)"
    "Bash(git branch *)"
    "Bash(git show *)"
    "Bash(git blame *)"
    "Bash(git remote -v)"
    "Bash(git remote -v *)"
    "Bash(ls *)"
    "Bash(pwd)"
    "Bash(which *)"
    "Bash(wc *)"
    "Bash(file *)"
    "Bash(tree *)"
    "Bash(uname *)"
    "Bash(whoami)"
    "Bash(* --version)"
    "Bash(* --help)"
    "Bash(* --help *)"
    "Bash(mkdir *)"
    "Bash(touch *)"
    "Bash(echo *)"
    "Bash(python *)"
    "Bash(python3 *)"
    "Bash(cat *)"
    "Bash(head *)"
    "Bash(tail *)"
    "Bash(diff *)"
    "Bash(sort *)"
    "Bash(jq *)"
    "Bash(find *)"
    "Bash(grep *)"
    "Bash(rg *)"
    "Bash(gh *)"
    "Bash(cp *)"
    "Bash(mv *)"
    "Bash(ln *)"
    "Bash(chmod *)"
    "Bash(sed *)"
    "Bash(awk *)"
    "Bash(tee *)"
    "Bash(xargs *)"
    "Bash(date *)"
    "Bash(basename *)"
    "Bash(dirname *)"
    "Bash(realpath *)"
    "Bash(stat *)"
    "Bash(env *)"
    "mcp__plugin_playwright_playwright__browser_close"
    "mcp__plugin_playwright_playwright__browser_resize"
    "mcp__plugin_playwright_playwright__browser_console_messages"
    "mcp__plugin_playwright_playwright__browser_handle_dialog"
    "mcp__plugin_playwright_playwright__browser_evaluate"
    "mcp__plugin_playwright_playwright__browser_file_upload"
    "mcp__plugin_playwright_playwright__browser_fill_form"
    "mcp__plugin_playwright_playwright__browser_install"
    "mcp__plugin_playwright_playwright__browser_press_key"
    "mcp__plugin_playwright_playwright__browser_type"
    "mcp__plugin_playwright_playwright__browser_navigate"
    "mcp__plugin_playwright_playwright__browser_navigate_back"
    "mcp__plugin_playwright_playwright__browser_network_requests"
    "mcp__plugin_playwright_playwright__browser_run_code"
    "mcp__plugin_playwright_playwright__browser_take_screenshot"
    "mcp__plugin_playwright_playwright__browser_snapshot"
    "mcp__plugin_playwright_playwright__browser_click"
    "mcp__plugin_playwright_playwright__browser_drag"
    "mcp__plugin_playwright_playwright__browser_hover"
    "mcp__plugin_playwright_playwright__browser_select_option"
    "mcp__plugin_playwright_playwright__browser_tabs"
    "mcp__plugin_playwright_playwright__browser_wait_for"
)

PERMISSIONS_PERMISSIVE=(
    "${PERMISSIONS_STANDARD[@]}"
    "Bash(rm *)"
    "Bash(curl *)"
    "Bash(wget *)"
    "Bash(docker *)"
    "Bash(npm *)"
    "Bash(pnpm *)"
    "Bash(yarn *)"
)

# Parse arguments
PROJECT_PATH=""
SETUP_VENV=false
PROFILE=""
ASSUME_YES=false
NON_INTERACTIVE=false
FLAG_NO_TIER_SCAFFOLDING=false
FLAG_NO_STATUSLINE=false
FLAG_PERMISSIONS=""
FLAG_NO_PRE_COMPACT=false
FLAG_NO_AGENT_TEAMS=false
FLAG_NO_PROJECT_HOOKS=false
FLAG_NO_LOCAL_PERMISSIONS=false
INSTALL_GLOBAL_STATUSLINE=false

for arg in "$@"; do
    case "$arg" in
        --venv)
            SETUP_VENV=true
            ;;
        --profile=*)
            PROFILE="${arg#--profile=}"
            ;;
        --minimal)
            PROFILE="minimal"
            ;;
        --full)
            PROFILE="full"
            ;;
        --no-tier-scaffolding)
            FLAG_NO_TIER_SCAFFOLDING=true
            ;;
        --no-statusline)
            FLAG_NO_STATUSLINE=true
            ;;
        --permissions=*)
            FLAG_PERMISSIONS="${arg#--permissions=}"
            ;;
        --no-pre-compact)
            FLAG_NO_PRE_COMPACT=true
            ;;
        --no-agent-teams)
            FLAG_NO_AGENT_TEAMS=true
            ;;
        --no-project-hooks)
            FLAG_NO_PROJECT_HOOKS=true
            ;;
        --no-local-permissions)
            FLAG_NO_LOCAL_PERMISSIONS=true
            ;;
        --yes|-y)
            ASSUME_YES=true
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            ;;
        --global)
            INSTALL_GLOBAL_STATUSLINE=true
            ;;
        *)
            PROJECT_PATH="$arg"
            ;;
    esac
done

# TTY detection
INTERACTIVE=true
if [[ "$NON_INTERACTIVE" == true ]] || [[ "$ASSUME_YES" == true ]] || [[ ! -t 0 ]]; then
    INTERACTIVE=false
fi

# ---------------------------------------------------------------------------
# Phase 2: Resolve config — flags > state file > profile defaults > hardcoded
# ---------------------------------------------------------------------------

# Read saved state if it exists (populated by a prior install run)
SAVED_STATE_FILE=""  # will be set after PROJECT_ROOT is determined; re-read later

# Profile defaults
_apply_profile_defaults() {
    local p="$1"
    case "$p" in
        minimal)
            INSTALL_TIER_DOCS=false
            INSTALL_STATUSLINE=false
            PERMISSION_PROFILE=strict
            INSTALL_PRE_COMPACT=true
            INSTALL_AGENT_TEAMS=false
            INSTALL_PROJECT_HOOKS=false
            INSTALL_LOCAL_PERMISSIONS=false
            INSTALL_VENV=false
            ;;
        full)
            INSTALL_TIER_DOCS=true
            INSTALL_STATUSLINE=true
            PERMISSION_PROFILE=permissive
            INSTALL_PRE_COMPACT=true
            INSTALL_AGENT_TEAMS=true
            INSTALL_PROJECT_HOOKS=true
            INSTALL_LOCAL_PERMISSIONS=true
            INSTALL_VENV=true
            ;;
        standard|*)
            INSTALL_TIER_DOCS=true
            INSTALL_STATUSLINE=true
            PERMISSION_PROFILE=standard
            INSTALL_PRE_COMPACT=true
            INSTALL_AGENT_TEAMS=true
            INSTALL_PROJECT_HOOKS=true
            INSTALL_LOCAL_PERMISSIONS=true
            INSTALL_VENV=false
            ;;
    esac
}

# Start from profile (default: standard)
_apply_profile_defaults "${PROFILE:-standard}"

# Re-read saved state from prior install (provides defaults on reinstall)
# Called after PROJECT_ROOT is determined (see below marker).
_apply_saved_state() {
    local state_file="$PROJECT_ROOT/.claude/state/daic-install.json"
    if [[ ! -f "$state_file" ]]; then
        return
    fi
    export _DAIC_SAVED_STATE="$state_file"
    python3 - <<'READ_STATE'
import json, os, sys
try:
    with open(os.environ['_DAIC_SAVED_STATE']) as f:
        s = json.load(f)
    print('profile=' + s.get('profile', 'standard'))
    print('tier_docs=' + str(s.get('install_tier_docs', True)).lower())
    print('statusline=' + str(s.get('install_statusline', True)).lower())
    print('perm=' + s.get('permission_profile', 'standard'))
    print('pre_compact=' + str(s.get('install_pre_compact', True)).lower())
    print('agent_teams=' + str(s.get('install_agent_teams', True)).lower())
    print('project_hooks=' + str(s.get('install_project_hooks', True)).lower())
    print('local_perms=' + str(s.get('install_local_permissions', True)).lower())
except Exception:
    pass
READ_STATE
}

# Override with explicit flags
[[ "$FLAG_NO_TIER_SCAFFOLDING" == true ]] && INSTALL_TIER_DOCS=false
[[ "$FLAG_NO_STATUSLINE" == true ]]       && INSTALL_STATUSLINE=false
[[ -n "$FLAG_PERMISSIONS" ]]              && PERMISSION_PROFILE="$FLAG_PERMISSIONS"
[[ "$FLAG_NO_PRE_COMPACT" == true ]]      && INSTALL_PRE_COMPACT=false
[[ "$FLAG_NO_AGENT_TEAMS" == true ]]      && INSTALL_AGENT_TEAMS=false
[[ "$FLAG_NO_PROJECT_HOOKS" == true ]]    && INSTALL_PROJECT_HOOKS=false
[[ "$FLAG_NO_LOCAL_PERMISSIONS" == true ]] && INSTALL_LOCAL_PERMISSIONS=false
[[ "$SETUP_VENV" == true ]]               && INSTALL_VENV=true

# ---------------------------------------------------------------------------
# Phase 3: Interactive prompts (only when INTERACTIVE=true and no profile set)
# ---------------------------------------------------------------------------

_prompt_yes_no() {
    # Usage: _prompt_yes_no "Question" "Y" → returns 0=yes, 1=no
    local question="$1" default="$2"
    local prompt
    if [[ "$default" == "Y" ]]; then
        prompt="[Y]/n"
    else
        prompt="y/[N]"
    fi
    read -r -p "  $question $prompt " answer
    answer="${answer:-$default}"
    [[ "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" == "y" ]]
}

if [[ "$INTERACTIVE" == true ]]; then
    echo ""
    echo "DAIC Workflow Installer"
    read -r -p "  Profile [S]tandard / minimal / full / custom? " _profile_input
    _profile_input="${_profile_input:-S}"
    case "$(echo "$_profile_input" | tr '[:upper:]' '[:lower:]')" in
        m|minimal)
            PROFILE=minimal
            _apply_profile_defaults minimal
            ;;
        f|full)
            PROFILE=full
            _apply_profile_defaults full
            ;;
        c|custom)
            PROFILE=custom
            echo ""
            if _prompt_yes_no "─ Tiered docs + scaffold READMEs + tier reminder?" "Y"; then
                INSTALL_TIER_DOCS=true
            else
                INSTALL_TIER_DOCS=false
            fi
            if _prompt_yes_no "─ DAIC statusline?" "Y"; then
                INSTALL_STATUSLINE=true
            else
                INSTALL_STATUSLINE=false
            fi
            read -r -p "  ─ Permissions [S]tandard / strict / permissive?     [S] " _perm_input
            _perm_input="${_perm_input:-S}"
            case "$(echo "$_perm_input" | tr '[:upper:]' '[:lower:]')" in
                strict)   PERMISSION_PROFILE=strict ;;
                p|permissive) PERMISSION_PROFILE=permissive ;;
                *)        PERMISSION_PROFILE=standard ;;
            esac
            if _prompt_yes_no "─ Optional hooks (pre-compact, agent-teams, project-hooks, local-permissions)?" "Y"; then
                INSTALL_PRE_COMPACT=true
                INSTALL_AGENT_TEAMS=true
                INSTALL_PROJECT_HOOKS=true
                INSTALL_LOCAL_PERMISSIONS=true
            else
                INSTALL_PRE_COMPACT=false
                INSTALL_AGENT_TEAMS=false
                INSTALL_PROJECT_HOOKS=false
                INSTALL_LOCAL_PERMISSIONS=false
            fi
            if _prompt_yes_no "─ Python venv?" "N"; then
                INSTALL_VENV=true
            else
                INSTALL_VENV=false
            fi
            echo ""
            if ! _prompt_yes_no "  Proceed?" "Y"; then
                echo "Aborted."
                exit 0
            fi
            ;;
        *)
            # Default: standard
            PROFILE=standard
            _apply_profile_defaults standard
            ;;
    esac
    if _prompt_yes_no "Install statusline globally (~/.claude) for all projects?" "N"; then
        INSTALL_GLOBAL_STATUSLINE=true
    fi
fi

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
    if [[ "$INSTALL_GLOBAL_STATUSLINE" == true && -z "$PROJECT_PATH" ]]; then
        # Global-only mode: no project install needed
        PROJECT_ROOT=""
    else
        PROJECT_ROOT=$(find_project_root "$(pwd)") || {
            echo -e "${RED}Error: Could not find project root (.claude directory)${NC}"
            echo "Usage: $0 [project-path]"
            exit 1
        }
    fi
fi

if [[ -n "$PROJECT_ROOT" ]]; then
echo "Project root: $PROJECT_ROOT"

# Apply saved install state as defaults (called here so PROJECT_ROOT is known)
if [[ -z "$PROFILE" ]]; then
    while IFS='=' read -r key val; do
        case "$key" in
            profile)      [[ -z "$PROFILE" ]] && { PROFILE="$val"; _apply_profile_defaults "$val"; } ;;
            tier_docs)    [[ "$FLAG_NO_TIER_SCAFFOLDING" != true ]] && INSTALL_TIER_DOCS="$val" ;;
            statusline)   [[ "$FLAG_NO_STATUSLINE" != true ]] && INSTALL_STATUSLINE="$val" ;;
            perm)         [[ -z "$FLAG_PERMISSIONS" ]] && PERMISSION_PROFILE="$val" ;;
            pre_compact)  [[ "$FLAG_NO_PRE_COMPACT" != true ]] && INSTALL_PRE_COMPACT="$val" ;;
            agent_teams)  [[ "$FLAG_NO_AGENT_TEAMS" != true ]] && INSTALL_AGENT_TEAMS="$val" ;;
            project_hooks) [[ "$FLAG_NO_PROJECT_HOOKS" != true ]] && INSTALL_PROJECT_HOOKS="$val" ;;
            local_perms)  [[ "$FLAG_NO_LOCAL_PERMISSIONS" != true ]] && INSTALL_LOCAL_PERMISSIONS="$val" ;;
        esac
    done < <(_apply_saved_state)
fi

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

if [[ "$INSTALL_TIER_DOCS" == true ]]; then
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

# Copy scaffold READMEs into docs subdirectories (idempotent — never overwrite)
if [[ -d "$SCRIPT_DIR/templates/scaffold-readmes" ]]; then
    _copy_scaffold_readme() {
        local src="$1" dst="$2"
        if [[ ! -f "$dst" ]]; then
            cp "$src" "$dst"
            echo -e "  ${GREEN}✓${NC} Created $(basename "$dst") in $(dirname "$dst" | sed "s|$PROJECT_ROOT/||")"
        else
            echo -e "  ${GREEN}✓${NC} $(basename "$dst") already exists — skipping"
        fi
    }
    _copy_scaffold_readme \
        "$SCRIPT_DIR/templates/scaffold-readmes/docs-README.md" \
        "$PROJECT_ROOT/docs/README.md"
    _copy_scaffold_readme \
        "$SCRIPT_DIR/templates/scaffold-readmes/architecture-README.md" \
        "$PROJECT_ROOT/docs/architecture/README.md"
    _copy_scaffold_readme \
        "$SCRIPT_DIR/templates/scaffold-readmes/patterns-README.md" \
        "$PROJECT_ROOT/docs/patterns/README.md"
    _copy_scaffold_readme \
        "$SCRIPT_DIR/templates/scaffold-readmes/archive-README.md" \
        "$PROJECT_ROOT/docs/backlog/archive/README.md"
fi
fi

if [[ "$INSTALL_LOCAL_PERMISSIONS" == true ]]; then
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

if [[ "$INSTALL_PROJECT_HOOKS" == true ]]; then
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
fi

if [[ "$INSTALL_STATUSLINE" == true ]]; then
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
  ]
}
HOOKS_JSON
)

# Conditionally add PreCompact hook
if [[ "$INSTALL_PRE_COMPACT" == true ]]; then
    DAIC_HOOKS=$(export _DAIC_HOOKS_JSON="$DAIC_HOOKS" && python3 <<'PRECOMPACT_PY'
import json, os
h = json.loads(os.environ['_DAIC_HOOKS_JSON'])
h['PreCompact'] = [{'hooks': [{'type': 'command', 'command': '$CLAUDE_PROJECT_DIR/.claude/hooks/pre-compact.py', 'timeout': 30}]}]
print(json.dumps(h))
PRECOMPACT_PY
)
fi

# Merge or create settings.json
SETTINGS_FILE="$PROJECT_ROOT/.claude/settings.json"

if [[ -f "$SETTINGS_FILE" ]]; then
    echo -e "${YELLOW}Merging hooks into existing settings.json...${NC}"
    cp "$SETTINGS_FILE" "$SETTINGS_FILE.backup.$(date +%Y%m%d%H%M%S)"

    # Use Python to merge (preserves other settings, adds statusLine if missing)
    export DAIC_PERMISSION_PROFILE="$PERMISSION_PROFILE"
    export INSTALL_AGENT_TEAMS_PY="$INSTALL_AGENT_TEAMS"
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

import os as _os_agent
if _os_agent.environ.get('INSTALL_AGENT_TEAMS_PY', 'true').lower() == 'true':
    if 'env' not in settings:
        settings['env'] = {}
    if 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' not in settings.get('env', {}):
        settings['env']['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1'
        print("  Enabled agent teams (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)")
    else:
        print("  Agent teams already configured")

# Merge default permissions (additive - never removes existing allow rules)
import os as _os_perm
_profile = _os_perm.environ.get('DAIC_PERMISSION_PROFILE', 'standard')
_STRICT = [
    "Read(//tmp/**)", "Edit(//tmp/**)", "Write(//tmp/**)",
    "WebSearch",
    "Bash(git status)", "Bash(git status *)", "Bash(git diff *)",
    "Bash(git log *)", "Bash(git branch *)", "Bash(git show *)",
    "Bash(git blame *)", "Bash(python *)", "Bash(python3 *)", "Bash(gh *)",
]
_STANDARD = [
    "Read(//tmp/**)", "Edit(//tmp/**)", "Write(//tmp/**)",
    "WebSearch", "WebFetch",
    "WebFetch(domain:localhost)", "WebFetch(domain:127.0.0.1)",
    "Bash(git status)", "Bash(git status *)", "Bash(git diff *)",
    "Bash(git log *)", "Bash(git branch *)", "Bash(git show *)",
    "Bash(git blame *)", "Bash(git remote -v)", "Bash(git remote -v *)",
    "Bash(ls *)", "Bash(pwd)", "Bash(which *)", "Bash(wc *)",
    "Bash(file *)", "Bash(tree *)", "Bash(uname *)", "Bash(whoami)",
    "Bash(* --version)", "Bash(* --help)", "Bash(* --help *)",
    "Bash(mkdir *)", "Bash(touch *)", "Bash(echo *)",
    "Bash(python *)", "Bash(python3 *)",
    "Bash(cat *)", "Bash(head *)", "Bash(tail *)", "Bash(diff *)",
    "Bash(sort *)", "Bash(jq *)",
    "Bash(find *)", "Bash(grep *)", "Bash(rg *)",
    "Bash(gh *)",
    "Bash(cp *)", "Bash(mv *)", "Bash(ln *)", "Bash(chmod *)",
    "Bash(sed *)", "Bash(awk *)", "Bash(tee *)", "Bash(xargs *)",
    "Bash(date *)", "Bash(basename *)", "Bash(dirname *)",
    "Bash(realpath *)", "Bash(stat *)", "Bash(env *)",
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
_EXTRA_PERMISSIVE = [
    "Bash(rm *)", "Bash(curl *)", "Bash(wget *)",
    "Bash(docker *)", "Bash(npm *)", "Bash(pnpm *)", "Bash(yarn *)",
]
if _profile == 'strict':
    DAIC_DEFAULT_PERMISSIONS = _STRICT
elif _profile == 'permissive':
    DAIC_DEFAULT_PERMISSIONS = _STANDARD + _EXTRA_PERMISSIVE
else:
    DAIC_DEFAULT_PERMISSIONS = _STANDARD

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
    export DAIC_PERMISSION_PROFILE="$PERMISSION_PROFILE"
    export INSTALL_AGENT_TEAMS_PY="$INSTALL_AGENT_TEAMS"
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
    "env": {},
    "permissions": {
        "allow": []
    },
    "additionalDirectories": ["/tmp/"]
}

import os as _os_agent
if _os_agent.environ.get('INSTALL_AGENT_TEAMS_PY', 'true').lower() == 'true':
    settings['env']['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1'

import os as _os_perm2
_profile2 = _os_perm2.environ.get('DAIC_PERMISSION_PROFILE', 'standard')
_STRICT2 = [
    "Read(//tmp/**)", "Edit(//tmp/**)", "Write(//tmp/**)",
    "WebSearch",
    "Bash(git status)", "Bash(git status *)", "Bash(git diff *)",
    "Bash(git log *)", "Bash(git branch *)", "Bash(git show *)",
    "Bash(git blame *)", "Bash(python *)", "Bash(python3 *)", "Bash(gh *)",
]
_STANDARD2 = [
    "Read(//tmp/**)", "Edit(//tmp/**)", "Write(//tmp/**)",
    "WebSearch", "WebFetch",
    "WebFetch(domain:localhost)", "WebFetch(domain:127.0.0.1)",
    "Bash(git status)", "Bash(git status *)", "Bash(git diff *)",
    "Bash(git log *)", "Bash(git branch *)", "Bash(git show *)",
    "Bash(git blame *)", "Bash(git remote -v)", "Bash(git remote -v *)",
    "Bash(ls *)", "Bash(pwd)", "Bash(which *)", "Bash(wc *)",
    "Bash(file *)", "Bash(tree *)", "Bash(uname *)", "Bash(whoami)",
    "Bash(* --version)", "Bash(* --help)", "Bash(* --help *)",
    "Bash(mkdir *)", "Bash(touch *)", "Bash(echo *)",
    "Bash(python *)", "Bash(python3 *)",
    "Bash(cat *)", "Bash(head *)", "Bash(tail *)", "Bash(diff *)",
    "Bash(sort *)", "Bash(jq *)",
    "Bash(find *)", "Bash(grep *)", "Bash(rg *)",
    "Bash(gh *)",
    "Bash(cp *)", "Bash(mv *)", "Bash(ln *)", "Bash(chmod *)",
    "Bash(sed *)", "Bash(awk *)", "Bash(tee *)", "Bash(xargs *)",
    "Bash(date *)", "Bash(basename *)", "Bash(dirname *)",
    "Bash(realpath *)", "Bash(stat *)", "Bash(env *)",
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
_EXTRA_PERMISSIVE2 = [
    "Bash(rm *)", "Bash(curl *)", "Bash(wget *)",
    "Bash(docker *)", "Bash(npm *)", "Bash(pnpm *)", "Bash(yarn *)",
]
if _profile2 == 'strict':
    settings['permissions']['allow'] = list(_STRICT2)
elif _profile2 == 'permissive':
    settings['permissions']['allow'] = list(_STANDARD2 + _EXTRA_PERMISSIVE2)
else:
    settings['permissions']['allow'] = list(_STANDARD2)

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
fi  # end if [[ -n "$PROJECT_ROOT" ]]

# ---------------------------------------------------------------------------
# Global statusline install (--global flag)
# ---------------------------------------------------------------------------
if [[ "$INSTALL_GLOBAL_STATUSLINE" == true ]]; then
    echo -e "${YELLOW}Installing statusline globally (~/.claude/settings.json)...${NC}"
    GLOBAL_DAIC_DIR="$HOME/.claude/daic"
    mkdir -p "$GLOBAL_DAIC_DIR"

    # Symlink statusline script to stable absolute path
    GLOBAL_SL_TARGET="$GLOBAL_DAIC_DIR/statusline-script.py"
    GLOBAL_SL_SRC="$SCRIPT_DIR/scripts/statusline-script.py"
    if [[ -e "$GLOBAL_SL_TARGET" ]] || [[ -L "$GLOBAL_SL_TARGET" ]]; then
        rm -f "$GLOBAL_SL_TARGET"
    fi
    ln -s "$GLOBAL_SL_SRC" "$GLOBAL_SL_TARGET"
    echo -e "  ${GREEN}✓${NC} statusline-script.py -> $GLOBAL_SL_SRC"

    # Merge statusLine into ~/.claude/settings.json
    GLOBAL_SETTINGS="$HOME/.claude/settings.json"
    export _DAIC_GLOBAL_SL_PATH="$GLOBAL_SL_TARGET"
    export _DAIC_GLOBAL_SETTINGS="$GLOBAL_SETTINGS"
    python3 - <<'GLOBAL_SL_SCRIPT'
import json, os
from pathlib import Path

settings_path = Path(os.environ['_DAIC_GLOBAL_SETTINGS'])
sl_path = os.environ['_DAIC_GLOBAL_SL_PATH']

if settings_path.exists():
    with open(settings_path) as f:
        settings = json.load(f)
    print("  Merging into existing ~/.claude/settings.json")
else:
    settings = {}
    print("  Creating ~/.claude/settings.json")

settings['statusLine'] = {
    "type": "command",
    "command": sl_path,
    "padding": 0
}

settings_path.parent.mkdir(parents=True, exist_ok=True)
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
print(f"  Set statusLine to {sl_path}")
GLOBAL_SL_SCRIPT

    echo -e "  ${GREEN}✓${NC} Global statusline installed"
fi

# ---------------------------------------------------------------------------
# Phase 5: Persist install state (project install only)
# ---------------------------------------------------------------------------
if [[ -n "$PROJECT_ROOT" ]]; then
INSTALL_STATE_FILE="$PROJECT_ROOT/.claude/state/daic-install.json"
export _DAIC_PROFILE="${PROFILE:-standard}"
export _DAIC_TIER_DOCS="$INSTALL_TIER_DOCS"
export _DAIC_STATUSLINE="$INSTALL_STATUSLINE"
export _DAIC_PERM_PROFILE="$PERMISSION_PROFILE"
export _DAIC_PRE_COMPACT="$INSTALL_PRE_COMPACT"
export _DAIC_AGENT_TEAMS="$INSTALL_AGENT_TEAMS"
export _DAIC_PROJECT_HOOKS="$INSTALL_PROJECT_HOOKS"
export _DAIC_LOCAL_PERMS="$INSTALL_LOCAL_PERMISSIONS"
export _DAIC_SOURCE_DIR="$SCRIPT_DIR"
export _DAIC_STATE_FILE="$INSTALL_STATE_FILE"

python3 - <<'PERSIST_SCRIPT'
import json, os
from datetime import datetime, timezone

def _b(v): return v.strip().lower() == 'true'

state = {
    "schema_version": 1,
    "profile": os.environ.get("_DAIC_PROFILE", "standard"),
    "install_tier_docs": _b(os.environ["_DAIC_TIER_DOCS"]),
    "install_statusline": _b(os.environ["_DAIC_STATUSLINE"]),
    "permission_profile": os.environ.get("_DAIC_PERM_PROFILE", "standard"),
    "install_pre_compact": _b(os.environ["_DAIC_PRE_COMPACT"]),
    "install_agent_teams": _b(os.environ["_DAIC_AGENT_TEAMS"]),
    "install_project_hooks": _b(os.environ["_DAIC_PROJECT_HOOKS"]),
    "install_local_permissions": _b(os.environ["_DAIC_LOCAL_PERMS"]),
    "installed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source_dir": os.path.realpath(os.environ["_DAIC_SOURCE_DIR"]),
}
with open(os.environ["_DAIC_STATE_FILE"], "w") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
print("  Saved install state to .claude/state/daic-install.json")
PERSIST_SCRIPT
fi  # end if [[ -n "$PROJECT_ROOT" ]]

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

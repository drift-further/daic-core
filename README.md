# DAIC Workflow Plugin for Claude Code

A comprehensive workflow discipline system for Claude Code that enforces Discussion-Alignment-Implementation-Check (DAIC) patterns.

## Features

- **DAIC Mode Enforcement**: Separates discussion and implementation phases
- **Branch Consistency**: Validates git branches match task requirements
- **Security Policies**: Blocks dangerous commands and sensitive file modifications
- **Task Management**: Integrates with task-based development workflows
- **Context Monitoring**: Tracks token usage and warns before context limits
- **Session Lifecycle**: Hooks for start, stop, compact, and end events

## Installation

### Method 1: Claude Code Plugin (Recommended)

```bash
# From within Claude Code
/plugin install path/to/daic-workflow
```

### Method 2: Manual Installation

```bash
# Clone or copy the plugin to your project
cp -r daic-workflow ~/.claude/plugins/

# Or for project-specific installation
cp -r daic-workflow /path/to/project/.claude/plugins/

# Run the setup script
cd /path/to/project
.claude/plugins/daic-workflow/install.sh
```

### Method 3: Git Submodule

```bash
# Add as a submodule
git submodule add https://github.com/drift-further/daic-workflow.git .claude/plugins/daic-workflow

# Initialize
.claude/plugins/daic-workflow/install.sh
```

## Configuration

Create `sessions/sessions-config.json` in your project:

```json
{
  "developer_name": "Your Name",
  "trigger_phrases": [
    "implement it",
    "fix it",
    "do it",
    "go ahead",
    "make it so",
    "run that"
  ],
  "blocked_tools": ["NotebookEdit"],
  "task_detection": {
    "enabled": true
  },
  "branch_enforcement": {
    "enabled": true
  },
  "security": {
    "enabled": true,
    "block_sensitive_paths": true,
    "block_path_traversal": true
  },
  "api_mode": false
}
```

### Installer Configuration

The installer supports profiles and feature flags for non-interactive and custom setups.

#### Profiles

```bash
# Standard (default) — all features, standard permissions
./install.sh /path/to/project --profile=standard

# Minimal — core hooks only, strict permissions, no statusline/tier-docs
./install.sh /path/to/project --profile=minimal

# Full — all features, permissive permissions, Python venv
./install.sh /path/to/project --profile=full

# Non-interactive with explicit profile (CI/scripts)
./install.sh /path/to/project --profile=minimal --yes
```

| Profile | Tier Docs | Statusline | Permissions | Agent Teams | Venv |
|---------|-----------|------------|-------------|-------------|------|
| minimal | off | off | strict | off | off |
| standard | on | on | standard | on | off |
| full | on | on | permissive | on | on |

#### Feature Flags

Override individual features regardless of profile:

| Flag | Effect |
|------|--------|
| `--no-tier-scaffolding` | Skip tiered docs dirs and scaffold READMEs |
| `--no-statusline` | Skip statusline symlink |
| `--permissions=strict\|standard\|permissive` | Override permission set |
| `--no-pre-compact` | Skip PreCompact hook |
| `--no-agent-teams` | Skip agent teams env var |
| `--no-project-hooks` | Skip project hooks extension dir |
| `--no-local-permissions` | Skip local-permissions.json |
| `--venv` | Set up Python venv (overrides profile default) |
| `--yes` / `-y` | Assume yes to all prompts (non-interactive) |
| `--non-interactive` | Fully suppress prompts, use resolved defaults |
| `--global` | Install statusline into `~/.claude/settings.json` (all projects) |

#### Interactive Mode

When run in a terminal without `--yes`, the installer prompts for a profile:

```
DAIC Workflow Installer
  Profile [S]tandard / minimal / full / custom?
```

Choosing `custom` shows five grouped questions:

```
  ─ Tiered docs + scaffold READMEs + tier reminder?  [Y]/n
  ─ DAIC statusline?                                  [Y]/n
  ─ Permissions [S]tandard / strict / permissive?     [S]
  ─ Optional hooks (pre-compact, agent-teams, project-hooks, local-permissions)? [Y]/n
  ─ Python venv?                                      y/[N]
  Install statusline globally (~/.claude) for all projects? y/[N]
  Proceed? [Y]/n
```

#### Tier Reminder

When tiered docs are installed, the session-start hook injects a 6-line tier
reminder before `docs/ACTIVE_CONTEXT.md` for the first 5 sessions. Control
this via `sessions/sessions-config.json`:

```json
{
  "tier_reminder": "auto"
}
```

Values: `"auto"` (first 5 sessions), `true` (always), `false` (never).

#### Global Statusline

Install the statusline once for all Claude Code projects instead of per-project:

```bash
# Global only (no project setup)
./install.sh --global

# Combined with project install
./install.sh /path/to/project --profile=standard --global --yes
```

This symlinks `statusline-script.py` to `~/.claude/daic/statusline-script.py` and writes the `statusLine` key into `~/.claude/settings.json`.

## Usage

### DAIC Workflow

1. **Discussion Mode** (default): Claude focuses on planning and discussion
   - Edit tools are blocked
   - Read-only operations are allowed

2. **Implementation Mode**: Triggered by phrases like "make it so"
   - Edit tools are unlocked
   - Claude reminds you to run `daic` when done

3. **Return to Discussion**: Run `daic` command to switch back

### Trigger Phrases

Default phrases that activate implementation mode:
- "implement it"
- "fix it"
- "do it"
- "go ahead"
- "make it so"
- "run that"

Emergency stop: Say "SILENCE" or "STOP" (case-sensitive)

### Task Management

Create tasks in `sessions/tasks/`:
- `h-taskname.md` - High priority
- `m-taskname.md` - Medium priority
- `l-taskname.md` - Low priority
- `?-taskname.md` - Investigation/research

Set active task in `.claude/state/current_task.json`:
```json
{
  "task": "h-my-feature",
  "branch": "feature/my-feature",
  "services": ["api", "frontend"],
  "updated": "2026-01-25"
}
```

## Hooks Reference

| Hook | Event | Purpose |
|------|-------|---------|
| `session-start.py` | SessionStart | Loads task context, clears warning flags |
| `user-messages.py` | UserPromptSubmit | Detects trigger phrases, monitors context |
| `sessions-enforce.py` | PreToolUse | Enforces DAIC mode, security, branch rules |
| `task-transcript-link.py` | PreToolUse (Task) | Chunks transcripts for subagents |
| `post-tool-use.py` | PostToolUse | DAIC reminders after edits |
| `stop-check.py` | Stop | Validates before Claude stops |
| `pre-compact.py` | PreCompact | Saves state before context compaction |
| `session-end.py` | SessionEnd | Cleanup and state persistence |

## Security Features

### Path Validation
- Blocks path traversal (`..` in paths)
- Protects sensitive directories (`/etc/`, `/root/`, etc.)
- Protects sensitive files (`.env`, credentials, keys)

### Bash Command Safety
- Blocks dangerous patterns:
  - `rm -rf /` or `rm -rf ~`
  - `chmod 777`
  - Piping curl/wget to shell
  - Writing to system directories
  - `sudo rm`
  - Filesystem operations (`dd`, `mkfs`)

## Dependencies

- Python 3.9+
- `tiktoken` (optional, for transcript chunking)

Install tiktoken:
```bash
pip install tiktoken
```

## Tiered Documentation System

DAIC supports a Tiered Documentation System for optimal AI context management:

| Tier | File | Purpose |
|------|------|---------|
| **HOT** | `docs/ACTIVE_CONTEXT.md` | Current session context (max 200 lines, auto-loaded) |
| **WARM** | `docs/catalogs/`, `docs/architecture/` | On-demand reference documentation |
| **COLD** | `docs/backlog/archive/` | Historical archives |

The session-start hook automatically loads `docs/ACTIVE_CONTEXT.md` if it exists, warns if it exceeds 200 lines, and provides guidance if missing.

**See**: `docs/TIERED_DOCUMENTATION_GUIDE.md` for full setup instructions.

**Template**: `templates/ACTIVE_CONTEXT.template.md` for a starter file.

## Directory Structure

```
daic-workflow/
├── plugin.json           # Plugin manifest
├── README.md             # This file
├── install.sh            # Installation script
├── docs/
│   └── TIERED_DOCUMENTATION_GUIDE.md  # Documentation system guide
├── hooks/
│   └── hooks.json        # Hook configuration
├── scripts/
│   ├── shared_state.py   # State management
│   ├── session-start.py  # Loads ACTIVE_CONTEXT.md
│   ├── user-messages.py
│   ├── sessions-enforce.py
│   ├── task-transcript-link.py
│   ├── post-tool-use.py
│   ├── stop-check.py
│   ├── pre-compact.py
│   └── session-end.py
└── templates/
    ├── sessions-config.json
    └── ACTIVE_CONTEXT.template.md  # HOT tier template
```

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome! Please read the contributing guidelines before submitting PRs.

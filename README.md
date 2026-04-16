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

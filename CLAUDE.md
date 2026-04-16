# Claude Code Workflow Plugin

Claude Code plugin providing session management, security policies, and context monitoring.

## Project Structure

- `scripts/` — Canonical source for all hook scripts and statusline
- `.claude/hooks/` — Symlinks to `scripts/` (created by `install.sh`)
- `.claude/state/` — Runtime state files (gitignored, not source)
- `sessions/` — Task management, protocols, and config

## Key Files

- `scripts/shared_state.py` — Shared module imported by all hooks (state management, path validation)
- `scripts/user-messages.py` — UserPromptSubmit hook (context monitoring, protocol detection)
- `scripts/sessions-enforce.py` — PreToolUse hook (security, branch validation)
- `scripts/post-tool-use.py` — PostToolUse hook (contextual feedback)
- `scripts/statusline-script.py` — Statusline (single Python process, no subshells)
- `scripts/session-start.py` — SessionStart hook (loads task context, ACTIVE_CONTEXT.md)
- `scripts/pre-compact.py` — PreCompact hook (saves checkpoint before compaction)

## Conventions

- Hooks output JSON to stdout using `hookSpecificOutput.additionalContext` pattern
- Hooks use exit code 0 (allow), 1 (error), 2 (block with message to stderr)
- All hooks wrap logic in try/except to never crash the session
- State files live in `.claude/state/` as JSON
- When editing hooks, edit the canonical file in `scripts/`, not the symlink in `.claude/hooks/`

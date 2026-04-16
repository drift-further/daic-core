#!/usr/bin/env python3
"""User message hook to detect special patterns and manage context."""
import json
import sys
import re
import os
from pathlib import Path

# Handle imports for both direct execution and symlinked scenarios
script_dir = Path(__file__).resolve().parent
if str(script_dir) not in sys.path:
    sys.path.insert(0, str(script_dir))

from shared_state import get_project_root, run_project_extension

# Load input
input_data = json.load(sys.stdin)
prompt = input_data.get("prompt", "")
transcript_path = input_data.get("transcript_path", "")
context = ""

# Get configuration (if exists)
try:
    PROJECT_ROOT = get_project_root()
    CONFIG_FILE = PROJECT_ROOT / "sessions" / "sessions-config.json"

    if CONFIG_FILE.exists():
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
    else:
        config = {}
except Exception:
    config = {}

# Check API mode and add ultrathink if not in API mode
if not config.get("api_mode", False):
    context = "[[ ultrathink ]]\n"

# Token monitoring - two sources for context percentage:
# 1. Statusline bridge (most accurate - uses Claude Code's own data)
# 2. Transcript parsing (fallback)

def get_context_percentage_from_bridge():
    """Read context percentage from statusline bridge state file."""
    try:
        state_file = PROJECT_ROOT / ".claude" / "state" / "context-usage.json"
        if state_file.exists():
            with open(state_file, 'r') as f:
                data = json.load(f)
                pct = data.get("used_percentage", 0)
                if isinstance(pct, str):
                    pct = float(pct)
                tokens = data.get("tokens", 0)
                if isinstance(tokens, str):
                    tokens = int(tokens)
                return pct, tokens
    except Exception:
        pass
    return None, None

def get_context_length_from_transcript(transcript_path):
    """Get current context length from the most recent main-chain message in transcript"""
    try:
        if not os.path.exists(transcript_path):
            return 0

        with open(transcript_path, 'r') as f:
            lines = f.readlines()

        most_recent_usage = None
        most_recent_timestamp = None

        # Parse each JSONL entry
        for line in lines:
            try:
                data = json.loads(line.strip())
                # Skip sidechain entries (subagent calls)
                if data.get('isSidechain', False):
                    continue

                # Check if this entry has usage data
                if data.get('message', {}).get('usage'):
                    entry_time = data.get('timestamp')
                    # Track the most recent main-chain entry with usage
                    if entry_time and (not most_recent_timestamp or entry_time > most_recent_timestamp):
                        most_recent_timestamp = entry_time
                        most_recent_usage = data['message']['usage']
            except json.JSONDecodeError:
                continue

        # Calculate context length from most recent usage
        if most_recent_usage:
            context_length = (
                most_recent_usage.get('input_tokens', 0) +
                most_recent_usage.get('cache_read_input_tokens', 0) +
                most_recent_usage.get('cache_creation_input_tokens', 0)
            )
            return context_length
    except Exception:
        pass
    return 0

# Check context usage and warn if needed
# Try statusline bridge first (most accurate), fall back to transcript parsing
context_length = 0

bridge_pct, bridge_tokens = get_context_percentage_from_bridge()
if bridge_pct is not None and bridge_pct > 0:
    context_length = bridge_tokens or 0
elif transcript_path and os.path.exists(transcript_path):
    context_length = get_context_length_from_transcript(transcript_path)

if context_length > 0:
    # Token-based context warnings with escalating urgency (calibrated for 800k usable context).
    # Each threshold fires once per session via flag files.
    # Checked highest-first so only the most urgent unfired warning is shown.
    CONTEXT_WARNINGS = [
        (800000, "context-warning-800k.flag",
         "PROVIDE A HANDOFF PROMPT IMMEDIATELY, DO NOTHING ELSE. Save all state and docs NOW."),
        (775000, "context-warning-775k.flag",
         "PROVIDE A HANDOFF PROMPT IMMEDIATELY, DO NOTHING ELSE. Save all state and docs NOW."),
        (750000, "context-warning-750k.flag",
         "PROVIDE A HANDOFF PROMPT IMMEDIATELY, DO NOTHING ELSE. Save all state and docs NOW."),
        (700000, "context-warning-700k.flag",
         "Wrap up what you are doing ASAP and give a handoff prompt. Stop any new tasks. Update ACTIVE_CONTEXT.md and all docs before handing off."),
        (600000, "context-warning-600k.flag",
         "You are approaching the end of this session. Finish your current task, update ACTIVE_CONTEXT.md and docs, and prepare a handoff prompt. Delegate remaining work to sub-agents rather than doing it inline."),
        (500000, "context-warning-500k.flag",
         "You are past the halfway point. Update ACTIVE_CONTEXT.md and docs with current progress. Review your remaining work — delegate via Agent tool (sub-agents, multi-team groups) wherever possible. Provide full context to each sub-agent and review their output as it returns. Start thinking about what a handoff prompt would look like."),
        (400000, "context-warning-400k.flag",
         "Context checkpoint: update ACTIVE_CONTEXT.md and any relevant docs with progress so far. You should be actively using Agent tool with sub-agents and TeamCreate for parallel work. Oversee and review sub-agent results rather than doing everything inline. Provide each sub-agent with sufficient context to work autonomously."),
        (300000, "context-warning-300k.flag",
         "Context checkpoint: ensure ACTIVE_CONTEXT.md reflects current state. Prioritize dispatching work to sub-agents (Agent tool) and multi-agent teams (TeamCreate) — you are the orchestrator, not the solo executor. Give each agent enough context to succeed and review their output critically."),
        (200000, "context-warning-200k.flag",
         "Context checkpoint: update ACTIVE_CONTEXT.md and session docs with decisions made and progress. Start favoring sub-agent delegation (Agent tool, TeamCreate) over inline work to preserve your context window for oversight and coordination."),
        (100000, "context-warning-100k.flag",
         "Context checkpoint: you have used ~100k tokens. Update ACTIVE_CONTEXT.md with current state. For any remaining multi-step work, prefer using the Agent tool to dispatch sub-agents rather than doing everything in this context. This preserves your window for orchestration and review."),
    ]

    state_dir = PROJECT_ROOT / ".claude" / "state"
    tokens_k = context_length // 1000

    for threshold, flag_name, message in CONTEXT_WARNINGS:
        if context_length >= threshold:
            flag_file = state_dir / flag_name
            if not flag_file.exists():
                context += f"\n[CONTEXT WARNING - {tokens_k}k tokens used] {message}\n"
                flag_file.parent.mkdir(parents=True, exist_ok=True)
                flag_file.touch()
                break  # Only show one warning per prompt

# Iterloop detection
if "iterloop" in prompt.lower():
    context += "You have been instructed to iteratively loop over a list. Identify what list the user is referring to, then follow this loop: present one item, wait for the user to respond with questions and discussion points, only continue to the next item when the user explicitly says 'continue' or something similar\n"

# Protocol detection - explicit phrases that trigger protocol reading
prompt_lower = prompt.lower()

# Context compaction detection
if any(phrase in prompt_lower for phrase in ["compact", "restart session", "context compaction"]):
    context += "If the user is asking to compact context, read and follow sessions/protocols/context-compaction.md protocol.\n"

# Task completion detection
if any(phrase in prompt_lower for phrase in ["complete the task", "finish the task", "task is done", 
                                               "mark as complete", "close the task", "wrap up the task"]):
    context += "If the user is asking to complete the task, read and follow sessions/protocols/task-completion.md protocol.\n"

# Task creation detection
if any(phrase in prompt_lower for phrase in ["create a new task", "create a task", "make a task",
                                               "new task for", "add a task"]):
    context += "If the user is asking to create a task, read and follow sessions/protocols/task-creation.md protocol.\n"

# Task switching detection
if any(phrase in prompt_lower for phrase in ["switch to task", "work on task", "change to task"]):
    context += "If the user is asking to switch tasks, read and follow sessions/protocols/task-startup.md protocol.\n"

# Task detection patterns (optional feature)
if config.get("task_detection", {}).get("enabled", True):
    task_patterns = [
        r"(?i)we (should|need to|have to) (implement|fix|refactor|migrate|test|research)",
        r"(?i)create a task for",
        r"(?i)add this to the (task list|todo|backlog)",
        r"(?i)we'll (need to|have to) (do|handle|address) (this|that) later",
        r"(?i)that's a separate (task|issue|problem)",
        r"(?i)file this as a (bug|task|issue)"
    ]
    
    task_mentioned = any(re.search(pattern, prompt) for pattern in task_patterns)
    
    if task_mentioned:
        # Add task detection note
        context += """
[Task Detection Notice]
The message may reference something that could be a task.

IF you or the user have discovered a potential task that is sufficiently unrelated to the current task, ask if they'd like to create a task file.

Tasks are:
• More than a couple commands to complete
• Semantically distinct units of work
• Work that takes meaningful context
• Single focused goals (not bundled multiple goals)
• Things that would take multiple days should be broken down
• NOT subtasks of current work (those go in the current task file/directory)

If they want to create a task, follow the task creation protocol.
"""

# Run project-specific user-messages extension
try:
    ext_result = run_project_extension("user-messages", input_data)
    if ext_result and ext_result.get("additionalContext"):
        context += ext_result["additionalContext"]
except Exception:
    pass  # Never fail user prompt handling due to extension issues

# Output the context additions
if context:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context
        }
    }
    print(json.dumps(output))

sys.exit(0)

#!/usr/bin/env python3
"""
Fast block timer calculation for Claude Code 5-hour billing windows.
Reads JSONL files to find the most recent activity and calculate block boundaries.

Extracted logic from ccusage - but much faster since we only need timestamps,
not pricing/cost calculations.
"""

import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

# 5-hour block duration in seconds
BLOCK_DURATION_SECONDS = 5 * 60 * 60
BLOCK_DURATION_MS = BLOCK_DURATION_SECONDS * 1000


def get_claude_projects_dirs() -> list[Path]:
    """Get Claude data directories containing projects."""
    dirs = []

    # Check environment variable first
    env_path = os.environ.get('CLAUDE_CONFIG_DIR', '').strip()
    if env_path:
        for p in env_path.split(','):
            p = p.strip()
            if p:
                projects_dir = Path(p) / 'projects'
                if projects_dir.is_dir():
                    dirs.append(projects_dir)
        if dirs:
            return dirs

    # Default paths
    home = Path.home()
    default_paths = [
        home / '.config' / 'claude' / 'projects',  # New default (v1.0.30+)
        home / '.claude' / 'projects',              # Legacy
    ]

    for p in default_paths:
        if p.is_dir():
            dirs.append(p)

    return dirs


def floor_to_hour(dt: datetime) -> datetime:
    """Floor a datetime to the beginning of the hour in UTC."""
    return dt.replace(minute=0, second=0, microsecond=0)


def get_recent_timestamps(projects_dir: Path, max_files: int = 50) -> list[datetime]:
    """
    Get recent timestamps from JSONL files.
    Only reads the tail of files for speed.
    """
    timestamps = []

    # Get all jsonl files, sorted by modification time (most recent first)
    jsonl_files = list(projects_dir.glob('*/*.jsonl'))
    jsonl_files.sort(key=lambda f: f.stat().st_mtime, reverse=True)

    # Only check recent files
    for jsonl_file in jsonl_files[:max_files]:
        try:
            # Read last ~50KB of file (enough for recent entries)
            file_size = jsonl_file.stat().st_size
            read_size = min(file_size, 50000)

            with open(jsonl_file, 'rb') as f:
                if file_size > read_size:
                    f.seek(file_size - read_size)
                    # Skip partial first line
                    f.readline()
                content = f.read().decode('utf-8', errors='ignore')

            # Parse lines from the tail
            for line in content.strip().split('\n'):
                if not line:
                    continue
                try:
                    data = json.loads(line)
                    # Only count assistant messages (actual API calls)
                    if data.get('type') == 'assistant' and 'timestamp' in data:
                        ts_str = data['timestamp']
                        # Parse ISO timestamp
                        if ts_str.endswith('Z'):
                            ts_str = ts_str[:-1] + '+00:00'
                        dt = datetime.fromisoformat(ts_str)
                        if dt.tzinfo is None:
                            dt = dt.replace(tzinfo=timezone.utc)
                        timestamps.append(dt)
                except (json.JSONDecodeError, ValueError, KeyError):
                    continue
        except (IOError, OSError):
            continue

    return timestamps


def calculate_active_block(timestamps: list[datetime]) -> Optional[dict]:
    """
    Calculate the active block from timestamps.
    Returns block info or None if no active block.
    """
    if not timestamps:
        return None

    now = datetime.now(timezone.utc)

    # Sort timestamps
    timestamps.sort()

    # Find entries within the last 5 hours (potential active block)
    cutoff = now - timedelta(seconds=BLOCK_DURATION_SECONDS)
    recent = [ts for ts in timestamps if ts > cutoff]

    if not recent:
        # No recent activity - no active block
        return None

    # Find block start: floor the first recent entry to the hour
    # But we need to find the actual block boundary
    # A block starts when there's a gap > 5h before an entry

    # Work backwards to find block start
    block_entries = []
    for ts in reversed(timestamps):
        if not block_entries:
            block_entries.append(ts)
        else:
            # Check gap from this entry to the earliest in our block
            gap = (block_entries[-1] - ts).total_seconds()
            if gap > BLOCK_DURATION_SECONDS:
                # Gap too large - this entry is from a previous block
                break
            block_entries.append(ts)

    block_entries.reverse()

    if not block_entries:
        return None

    # Block start is first entry floored to the hour
    first_entry = block_entries[0]
    block_start = floor_to_hour(first_entry)
    block_end = block_start + timedelta(seconds=BLOCK_DURATION_SECONDS)
    last_entry = block_entries[-1]

    # Check if block is still active
    # Active if: now < block_end AND (now - last_entry) < 5 hours
    time_since_last = (now - last_entry).total_seconds()
    is_active = now < block_end and time_since_last < BLOCK_DURATION_SECONDS

    if not is_active:
        return None

    # Calculate times
    elapsed_seconds = (now - block_start).total_seconds()
    remaining_seconds = max(0, (block_end - now).total_seconds())

    return {
        'blockStart': block_start.isoformat(),
        'blockEnd': block_end.isoformat(),
        'lastEntry': last_entry.isoformat(),
        'elapsedSeconds': int(elapsed_seconds),
        'remainingSeconds': int(remaining_seconds),
        'entries': len(block_entries),
        'isActive': True,
        'calculatedAt': now.isoformat(),
    }


def main():
    """Calculate and output block timing info."""
    projects_dirs = get_claude_projects_dirs()

    if not projects_dirs:
        print(json.dumps({'error': 'No Claude projects directory found', 'isActive': False}))
        return

    # Collect timestamps from all projects dirs
    all_timestamps = []
    for projects_dir in projects_dirs:
        all_timestamps.extend(get_recent_timestamps(projects_dir))

    block_info = calculate_active_block(all_timestamps)

    if block_info:
        print(json.dumps(block_info))
    else:
        print(json.dumps({'isActive': False, 'calculatedAt': datetime.now(timezone.utc).isoformat()}))


if __name__ == '__main__':
    main()

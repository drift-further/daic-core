"""Tests for tier_reminder_block() in session-start.py.

Run from repo root:
    python3 -m pytest scripts/tests/test_session_start_tier.py -v
"""
import importlib
import json
import sys
import types
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest

# ---------------------------------------------------------------------------
# Helpers to import tier_reminder_block without executing the module's
# top-level side-effects (hook output, subprocess calls, etc.)
# ---------------------------------------------------------------------------

def _load_tier_reminder_block(tmp_path: Path):
    """Return the tier_reminder_block function isolated in a fresh module."""
    src = Path(__file__).parent.parent / "session-start.py"
    source = src.read_text()

    # Stub out shared_state to avoid project-root detection side effects
    fake_shared = types.ModuleType("shared_state")
    fake_shared.get_project_root = lambda: tmp_path
    fake_shared.ensure_state_dir = lambda: None
    fake_shared.get_task_state = lambda: {"task": None}
    fake_shared.run_project_extension = lambda *a, **kw: None
    sys.modules["shared_state"] = fake_shared

    mod = types.ModuleType("session_start_under_test")
    mod.__file__ = str(src)

    # Provide a PROJECT_ROOT so the module-level code doesn't blow up
    mod.PROJECT_ROOT = tmp_path
    # Execute only the function definitions, skip the main script body by
    # compiling just up to the first non-def top-level statement after the
    # function. We use exec with a patched __name__ guard trick: we inject
    # __name__ != '__main__' logic by wrapping in a function-extraction
    # approach — exec the whole module but capture tier_reminder_block.
    # The module has no `if __name__ == '__main__'` guard so we mock
    # json.dumps and sys.stdout to absorb the print() at module end.
    import io
    with patch("builtins.print"), \
         patch("subprocess.run", return_value=MagicMock(returncode=1, stdout="")):
        exec(compile(source, str(src), "exec"), mod.__dict__)

    # Reset counter after exec — module-level code called tier_reminder_block once
    counter_file = tmp_path / ".claude" / "state" / "tier-reminder-count.json"
    if counter_file.exists():
        counter_file.write_text('{"count": 0}')

    return mod.tier_reminder_block

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def project(tmp_path):
    """Minimal project layout required by tier_reminder_block."""
    (tmp_path / "sessions").mkdir()
    (tmp_path / ".claude" / "state").mkdir(parents=True)
    (tmp_path / "docs" / "architecture").mkdir(parents=True)
    (tmp_path / "docs" / "patterns").mkdir(parents=True)
    config = {
        "developer_name": "Tester",
        "tier_reminder": "auto"
    }
    (tmp_path / "sessions" / "sessions-config.json").write_text(
        json.dumps(config)
    )
    return tmp_path


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestTierReminderBlock:

    def test_auto_injects_on_first_call(self, project):
        fn = _load_tier_reminder_block(project)
        result = fn(project)
        assert "== TIER REMINDER ==" in result
        assert "HOT" in result
        assert "WARM" in result
        assert "COLD" in result

    def test_auto_increments_counter(self, project):
        fn = _load_tier_reminder_block(project)
        fn(project)
        counter_file = project / ".claude" / "state" / "tier-reminder-count.json"
        assert counter_file.exists()
        data = json.loads(counter_file.read_text())
        assert data["count"] == 1

    def test_auto_injects_up_to_5_times(self, project):
        fn = _load_tier_reminder_block(project)
        for i in range(1, 6):
            result = fn(project)
            assert "== TIER REMINDER ==" in result, f"Expected injection on call {i}"

    def test_auto_stops_after_5(self, project):
        fn = _load_tier_reminder_block(project)
        counter_file = project / ".claude" / "state" / "tier-reminder-count.json"
        counter_file.write_text(json.dumps({"count": 5}))
        result = fn(project)
        assert result == ""

    def test_true_always_injects(self, project):
        config = {"developer_name": "Tester", "tier_reminder": True}
        (project / "sessions" / "sessions-config.json").write_text(
            json.dumps(config)
        )
        fn = _load_tier_reminder_block(project)
        counter_file = project / ".claude" / "state" / "tier-reminder-count.json"
        counter_file.write_text(json.dumps({"count": 999}))
        result = fn(project)
        assert "== TIER REMINDER ==" in result

    def test_false_never_injects(self, project):
        config = {"developer_name": "Tester", "tier_reminder": False}
        (project / "sessions" / "sessions-config.json").write_text(
            json.dumps(config)
        )
        fn = _load_tier_reminder_block(project)
        result = fn(project)
        assert result == ""

    def test_missing_scaffold_dirs_skips(self, project):
        """No docs/architecture dir → no injection even with tier_reminder=true."""
        import shutil
        shutil.rmtree(project / "docs" / "architecture")
        config = {"developer_name": "Tester", "tier_reminder": True}
        (project / "sessions" / "sessions-config.json").write_text(
            json.dumps(config)
        )
        fn = _load_tier_reminder_block(project)
        result = fn(project)
        assert result == ""

    def test_missing_sessions_config_returns_empty(self, project):
        (project / "sessions" / "sessions-config.json").unlink()
        fn = _load_tier_reminder_block(project)
        result = fn(project)
        assert result == ""

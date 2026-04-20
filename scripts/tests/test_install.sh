#!/usr/bin/env bash
# Integration tests for install.sh
# Run from repo root: bash scripts/tests/test_install.sh
set -euo pipefail

DAIC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

_assert() {
    local desc="$1" result="$2"
    if [[ "$result" == "0" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

_run_install() {
    local dir="$1"; shift
    bash "$DAIC_ROOT/install.sh" "$dir" "$@" > /dev/null 2>&1
}

echo "=== test_install.sh ==="

# ------------------------------------------------------------------
# Test: minimal profile
# ------------------------------------------------------------------
echo ""
echo "-- minimal profile --"
T=$(mktemp -d)
_run_install "$T" --profile=minimal --yes

_assert "state file created"           "$([[ -f "$T/.claude/state/daic-install.json" ]]; echo $?)"
_assert "hooks dir created"            "$([[ -d "$T/.claude/hooks" ]]; echo $?)"
_assert "sessions dir created"         "$([[ -d "$T/sessions" ]]; echo $?)"
_assert "no docs/architecture/README"  "$([[ ! -f "$T/docs/architecture/README.md" ]]; echo $?)"
_assert "no statusline symlink"        "$([[ ! -L "$T/.claude/statusline-script.py" ]]; echo $?)"

PROFILE=$(python3 -c "import json; d=json.load(open('$T/.claude/state/daic-install.json')); print(d['profile'])")
_assert "state profile=minimal"        "$([[ "$PROFILE" == "minimal" ]]; echo $?)"

TIER=$(python3 -c "import json; d=json.load(open('$T/.claude/state/daic-install.json')); print(d['install_tier_docs'])")
_assert "state install_tier_docs=false" "$([[ "$TIER" == "False" ]]; echo $?)"

PERM=$(python3 -c "import json; d=json.load(open('$T/.claude/state/daic-install.json')); print(d['permission_profile'])")
_assert "state permission_profile=strict" "$([[ "$PERM" == "strict" ]]; echo $?)"

SCHEMA=$(python3 -c "import json; d=json.load(open('$T/.claude/state/daic-install.json')); print(d['schema_version'])")
_assert "state schema_version=1"       "$([[ "$SCHEMA" == "1" ]]; echo $?)"
rm -rf "$T"

# ------------------------------------------------------------------
# Test: standard profile
# ------------------------------------------------------------------
echo ""
echo "-- standard profile --"
T=$(mktemp -d)
_run_install "$T" --profile=standard --yes

_assert "docs/architecture created"        "$([[ -d "$T/docs/architecture" ]]; echo $?)"
_assert "docs/architecture/README.md"      "$([[ -f "$T/docs/architecture/README.md" ]]; echo $?)"
_assert "docs/patterns/README.md"          "$([[ -f "$T/docs/patterns/README.md" ]]; echo $?)"
_assert "docs/backlog/archive/README.md"   "$([[ -f "$T/docs/backlog/archive/README.md" ]]; echo $?)"
_assert "docs/README.md"                   "$([[ -f "$T/docs/README.md" ]]; echo $?)"
_assert "statusline symlink exists"        "$([[ -L "$T/.claude/statusline-script.py" ]]; echo $?)"
_assert "sessions-config.json created"     "$([[ -f "$T/sessions/sessions-config.json" ]]; echo $?)"

PERM=$(python3 -c "import json; d=json.load(open('$T/.claude/state/daic-install.json')); print(d['permission_profile'])")
_assert "state permission_profile=standard" "$([[ "$PERM" == "standard" ]]; echo $?)"
rm -rf "$T"

# ------------------------------------------------------------------
# Test: full profile
# ------------------------------------------------------------------
echo ""
echo "-- full profile --"
T=$(mktemp -d)
_run_install "$T" --profile=full --yes

PERM=$(python3 -c "import json; d=json.load(open('$T/.claude/state/daic-install.json')); print(d['permission_profile'])")
_assert "state permission_profile=permissive" "$([[ "$PERM" == "permissive" ]]; echo $?)"

VENV=$(python3 -c "import json; d=json.load(open('$T/.claude/state/daic-install.json')); print(d.get('install_tier_docs', False))")
_assert "full profile tier_docs=true"  "$([[ "$VENV" == "True" ]]; echo $?)"
rm -rf "$T"

# ------------------------------------------------------------------
# Test: idempotency — run standard twice, no overwrites
# ------------------------------------------------------------------
echo ""
echo "-- idempotency --"
T=$(mktemp -d)
_run_install "$T" --profile=standard --yes
echo "sentinel" > "$T/docs/architecture/README.md"
_run_install "$T" --profile=standard --yes
CONTENT=$(cat "$T/docs/architecture/README.md")
_assert "existing README.md not overwritten" "$([[ "$CONTENT" == "sentinel" ]]; echo $?)"
rm -rf "$T"

# ------------------------------------------------------------------
# Test: --no-tier-scaffolding flag
# ------------------------------------------------------------------
echo ""
echo "-- --no-tier-scaffolding --"
T=$(mktemp -d)
_run_install "$T" --profile=standard --no-tier-scaffolding --yes
_assert "docs/architecture/README.md absent with --no-tier-scaffolding" \
    "$([[ ! -f "$T/docs/architecture/README.md" ]]; echo $?)"
rm -rf "$T"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]

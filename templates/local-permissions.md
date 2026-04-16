# Local Permissions

Project-specific Claude Code permission rules. Rules in `local-permissions.json` are merged into `settings.json` by `install.sh` on each run.

## Quick Start

Add rules to `.claude/local-permissions.json`:

```json
{
  "allow": [
    "Bash(bash scripts/my-tool.sh *)",
    "Bash(python3 scripts/my-pipeline.py *)"
  ]
}
```

Then re-run `install.sh` or manually copy the rule into `settings.json > permissions > allow`.

## Rule Syntax

| Pattern | Matches |
|---------|---------|
| `Bash(bash scripts/deploy.sh *)` | `bash scripts/deploy.sh staging --verbose` |
| `Bash(python3 tools/render.py *)` | `python3 tools/render.py --output /tmp/out` |
| `Bash(cd src && npm run build)` | Exact compound command |
| `Bash(cd src && npm *)` | `cd src && npm run build`, `cd src && npm test`, etc. |
| `Bash(./scripts/yt-*)` | Any `./scripts/yt-` prefixed script with any args |

## Rules

- `*` is a glob — matches any characters including spaces and flags
- Match is against the full command string as Claude would invoke it
- Compound commands (`cd x && cmd`) match from the first token
- Rules are additive — install.sh never removes existing rules
- Duplicates are skipped automatically

## Examples

**Allow specific scripts:**
```json
"Bash(bash remotion/scripts/yt-render-scenes.sh *)"
```

**Allow a family of scripts by prefix:**
```json
"Bash(bash remotion/scripts/yt-*)"
```

**Allow a tool with compound cd:**
```json
"Bash(cd remotion && python3 scripts/generate-yt-*)"
```

**Allow a build tool:**
```json
"Bash(./build.sh *)"
```

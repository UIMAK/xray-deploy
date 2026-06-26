<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->

# xray-deploy

Bash shell script for Xray deployment/management on NAT VPS. Targets Debian/Ubuntu (systemd) and Alpine (OpenRC).

## Verification Commands

```bash
# Syntax check all shell files (primary validation)
for f in install.sh xray-deploy.sh lib/*.sh; do bash -n "$f"; done

# Validate templates render valid JSON
for f in templates/*.jsonc; do
  sed 's/,*[[:space:]]*{{[A-Z_0-9]*_BLOCK}}//g; s/{{[A-Z_0-9]*}}/null/g' "$f" | python3 -c 'import json,sys; json.load(sys.stdin)' && echo "OK $f"
done

# Check for duplicate function names across modules
bash -c 'set -u; for f in lib/00-common lib/10-system lib/20-xray-core lib/30-geo lib/40-cloudflared lib/50-nodes lib/51-reality-pq lib/90-menu; do . $f.sh; done; declare -F|awk "{print \$3}"|sort|uniq -d'

# Repack distribution bundle
tar czf xray-deploy-bundle.tar.gz install.sh xray-deploy.sh README.md VERSION lib templates docs
```

**Dev host is Windows with Git Bash.** `jq` and `python3` are available locally; `xray`/`cloudflared` are not. Run `bash -n` via WSL (`C:\WINDOWS\system32\bash.exe -c '...'`) or Git Bash.

## Architecture

**Entry → loader → modules:** `install.sh` lays files → `xray-deploy.sh` sources `lib/*.sh` in numeric order (00→90) → calls `main`. Supports cron subcommands `geo-update` and `timed-restart`.

**Startup sequence:** `_main_menu` runs three silent idempotent ops before the loop: tag tagless inbounds → adopt orphan inbounds → normalize config format.

**All files install to `/opt/xray-deploy`** (except cloudflared binary at `/usr/local/bin/cloudflared`, xray symlink at `/usr/local/bin/xray`).

**Git-tracked files:** `install.sh`, `xray-deploy.sh`, `VERSION`, `README.md`, `.gitignore`, `lib/*.sh`, `templates/*.jsonc`. Local-only (gitignored): `AGENTS.md`, `CLAUDE.md`, `.claude/`, `.opencode/`, `.trellis/`, `docs/`.

## Conventions

- Functions prefixed `_` (e.g., `_add_node`, `_cf_toggle`); log helpers: `_info`, `_success`, `_warn`, `_error`, `_tip`
- **All config.json modifications go through `_mutate_config`** — jq filter must be passed as a single string (jq ≥1.8 breaks filter-concatenation)
- `set -u` is on — default all render variables (`: "${R_HOST:=}"`)
- Only the `VERSION` file needs bumping — `_check_script_update` reads it at runtime
- Node metadata: per-file JSON in `nodes/<tag>.json`, config.json `inbounds[]` is source of truth

## Alpine/Busybox Gotchas

- **No `sed -E` / `grep -E`** — use `jq` or BRE patterns
- **Edit service files with pure bash** (parameter expansion, while loops) — not `sed -E`
- **Templates are pure JSON (no `//` comments)** — busybox sed mangles jsonc
- **`cat tmp > file` not `mv`** for service file writes — preserves execute bit on openrc init.d scripts

## Critical Bash Gotchas

- **`_mutate_config` jq filter must be a single argument.** jq ≥1.8 treats second string as filename. Combine: `local combined="${!#} ${reorder}"; jq "${combined}" ...`
- **Bash placeholder `${content//\{\{KEY\}\}/val}` is unreliable** — store pattern in variable first: `p="{{KEY}}"; content="${content//$p/val}"`
- **`local IFS=','` persists through entire function.** Use `IFS=',' read -ra entries <<< "$input"` instead
- **`return` inside `echo | while read` doesn't exit function** — subshell. Use `while read ... done <<< "$var"`
- **`set -u` + arithmetic on user input crashes.** Validate first: `[[ "$n" =~ ^[0-9]+$ ]] || continue`

## cloudflared Process Lifecycle

**Critical:** Never call `systemctl restart` or `rc-service restart` directly. Always use `_cf_kill_all` → `_cf_restart`.

- `_cf_kill_all` sends SIGTERM first, waits 3s, then SIGKILL
- `_cf_restart` includes `sleep 2` before start and `sleep 3` after start
- **Never surgically edit command line with sed.** Always rebuild via `_cf_build_cmdline` + `_cf_write_service_line`. Flags after `--token` are silently ignored.

## More Details

See `CLAUDE.md` for full documentation: Xray config field names, node model, protocol-specific gotchas, security audit notes, template path rules, share link transport types, Hysteria2 port hopping, VLESS+ENC key generation, and cross-module dependency warnings.

# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## AKS Environment

### Gateway Scripts

| Script | What it does |
|---|---|
| `sh /home/node/bin/gateway-restart.sh` | Kill PID 1 → K8s restarts container (~2-3 min) |
| `sh /home/node/bin/gateway-stop.sh` | Same as restart (gateway IS PID 1) |
| `sh /home/node/bin/gateway-start.sh` | Check if gateway is running |

### CLI

- `openclaw` → wrapper at `/home/node/bin/openclaw`, runs from tmpfs (fast)
- `openclaw cron list` — list scheduled tasks
- `openclaw cron add` — add a cron job (~6-18s execution time, be patient)
- `openclaw pairing approve feishu <CODE>` — approve DM pairing
- `openclaw config set <key> <value>` — update config (requires gateway restart)

### Storage Locations

| Path | Type | Survives restart? |
|---|---|---|
| `/home/node/.openclaw/` | Azure Disk PVC | Yes |
| `/home/node/.openclaw/workspace/` | Working directory | Yes |
| `/home/node/.openclaw/workspace/memory/` | Memory files | Yes |
| `/opt/openclaw-fast/` | tmpfs (in-VM RAM) | No |
| `/persist/` | NFS shared across agents | Yes |
| `/tmp/` | Container tmpdir | No |

### Config

- Main config: `/home/node/.openclaw/openclaw.json` (auto-modified by gateway at startup)
- Do NOT edit `openclaw.json` while gateway is running — it will be overwritten
- Use `openclaw config set` then restart gateway

### Known Limitations

- No `ps`, `pkill`, `killall`, `/bin/kill` — only shell builtin `kill`
- No `systemctl` or `service` — container has no systemd
- `lsof` is available (useful for checking port listeners)
- Container runs as `node` (uid 1000) — no root access
- `/home/node/bin/` is writable (owned by node)
- CLI commands through gateway take 6-18s due to Kata VM overhead

---

Add whatever else helps you do your job. This is your cheat sheet.

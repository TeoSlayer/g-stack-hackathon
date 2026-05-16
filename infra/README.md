# infra

Everything the two agents need to run that isn't agent code: OpenClaw
configuration, Pilot trust bootstrap, DuckDB and gbrain storage layout,
Telegram bot registration, environment variables, runbook.

This directory is the operator's surface. If you're setting the system up on
a fresh homelab box, you start here.

## What lives here

| Concern | Owner |
|---|---|
| OpenClaw daemon config | `openclaw/gateway.toml` (template) |
| Skill manifests (paths to `agent-a/`, `agent-b/`) | `openclaw/skills.toml` |
| Pilot identity for the homelab node | `pilot/identity.json` — generated, never committed |
| Pilot trust list (which iOS device IDs are accepted) | `pilot/trust.json` |
| DuckDB database file | `data/facts.duckdb` (created on first ingest) |
| gbrain PGLite database | `data/gbrain.db` (created by `setup-gbrain`) |
| Telegram bot token | `.env` (gitignored), referenced by Coach |
| systemd / launchd unit files | `services/` |
| Backup script | `scripts/backup.sh` |
| Health-check script | `scripts/healthcheck.sh` |

## First-time setup

These are the **six steps** that turn a fresh homelab box into a working
substrate. Do them once, in order.

### 1. Install prerequisites

```sh
# macOS homelab box
brew install duckdb node@22
npm install -g openclaw@latest pnpm
```

OpenClaw needs Node ≥22. DuckDB CLI is optional but useful for inspecting
the warehouse directly.

### 2. Bootstrap OpenClaw

```sh
openclaw onboard --install-daemon
```

The wizard creates `~/.openclaw/openclaw.json`, installs the launchd /
systemd user service, asks for an LLM provider (pick anything; the
architecture doesn't care), and leaves the Gateway running.

Verify:

```sh
openclaw doctor
```

### 3. Create the Telegram bot

1. In Telegram, message [@BotFather](https://t.me/BotFather) → `/newbot`.
2. Save the token it gives you.
3. Add it to `infra/.env`:

   ```sh
   TELEGRAM_BOT_TOKEN=123456:ABC...
   ```

4. Register the channel with OpenClaw:

   ```sh
   openclaw channel add telegram --token $TELEGRAM_BOT_TOKEN
   ```

5. Open the bot in Telegram and send `/start` so OpenClaw learns your
   chat ID. The Coach skill will scope replies to that chat.

### 4. Initialize gbrain

```sh
# from this directory:
gstack setup-gbrain --backend pglite --data-dir ./data/gbrain
```

`setup-gbrain` (a gstack skill) installs the gbrain CLI, creates a local
PGLite database, registers the MCP endpoint, and writes the trust policy.
When it finishes, gbrain is reachable as an MCP tool to any agent on this
machine.

### 5. Bootstrap the Pilot identity for this box

The homelab box becomes a Pilot node so the iOS app can address it. Each
agent (A and B) ride this single identity — they're skills, not separate
nodes.

```sh
mkdir -p pilot
pilot-daemon init --data-dir ./pilot
pilot-daemon start --data-dir ./pilot &
pilotctl info  # prints node_id and virtual addr
```

Note the `node_id` and `addr` — the iOS app needs both. Drop them into
`infra/.env`:

```sh
HOMELAB_PILOT_ID=161006
HOMELAB_PILOT_ADDR=0:0000.0002.74EE
```

### 6. Register the iOS device as a trusted peer

First time the iOS HealthSync app launches with Pilot embedded, it requests
a handshake. On the homelab box, approve it:

```sh
pilotctl pending           # see the request
pilotctl approve <node_id> # accept it
pilotctl trust             # confirm it's listed
```

After this, the iOS app can send envelopes to the homelab without further
ceremony. The trust is persistent across iOS reinstalls *unless* the bundle
id changes (which generates a fresh identity).

For convenience you can flip auto-approve on in `pilot/config.toml`:

```toml
trust_auto_approve = true
```

…but only if you understand the threat model.

### 7. Install the agent skills

```sh
openclaw skill install ../agent-a
openclaw skill install ../agent-b
openclaw skill enable agent-a
openclaw skill enable agent-b
```

OpenClaw daemon reloads. From this point:

- Agent A is listening on Pilot port 1001 (ingest), 1003 (query), 1004 (events)
- Agent B is listening on Pilot port 1005 (insights inbox from Coach side)
- Agent B is also listening on Telegram

## Operational tasks

### Backup

```sh
./scripts/backup.sh /external/backup/healthsync
```

What it does: pause Agent A, `COPY` DuckDB to Parquet, snapshot gbrain
PGLite, tar Pilot identity + trust list, resume Agent A. Atomic against
ongoing ingest.

### Health check

```sh
./scripts/healthcheck.sh
```

Verifies:

- OpenClaw daemon responding (`openclaw doctor`)
- Both skills running (`openclaw skill list`)
- DuckDB readable + sample count moved in the last hour
- Pilot daemon up + at least one trusted peer
- Telegram bot replies to a `/ping`

Exit code `0` if green, non-zero with the failing component named.

### Restart everything

```sh
launchctl kickstart -k gui/$(id -u)/com.openclaw.gateway
```

Skills come back with their state intact. Pilot identity is persistent on
disk; trust list is persistent; DuckDB is persistent; gbrain is persistent.
No data loss across a full restart.

### Rotate the Telegram bot token

@BotFather → `/revoke` → new token. Update `infra/.env`. Restart OpenClaw.

## Directory layout (when populated)

```
infra/
├── README.md                    this file
├── .env.example                 template; copy to .env and fill in
├── openclaw/
│   ├── gateway.toml             OpenClaw gateway config
│   └── skills.toml              skill registry pointers
├── pilot/
│   ├── identity.json            generated, NEVER commit
│   ├── trust.json               peer trust list
│   └── config.toml              auto-approve, keepalive, etc.
├── data/
│   ├── facts.duckdb             Agent A's warehouse
│   └── gbrain/                  PGLite directory
├── services/
│   ├── com.openclaw.gateway.plist  launchd unit (macOS)
│   └── openclaw.service             systemd unit (Linux)
└── scripts/
    ├── backup.sh
    ├── healthcheck.sh
    └── restore.sh
```

## Status

Skeleton only — none of the templates or scripts above exist on disk yet.
This README pre-specifies them so they can be written in the right place when
the agents land in phase 2 and 3.

## Threat model in one paragraph

The homelab box is the trusted root. Anything that lands on its disk is
considered yours. The iOS device is trusted via Pilot identity (Ed25519,
persistent on the device). External services touched: Telegram (sees the
conversation, not the data) and whichever LLM provider Coach is configured
with (sees each turn's prompt, which may include redacted data summaries).
Everything else is local. If Telegram or the LLM provider matters for your
threat model, swap them; the architecture doesn't bind to either.

## See also

- [../README.md](../README.md) — overall project and the loop it closes
- [../health-sync](../health-sync) — the iOS source
- [../pilot-swift](../pilot-swift) — the Swift Pilot SDK that the iOS app embeds
- [../agent-a](../agent-a) — Collector spec
- [../agent-b](../agent-b) — Coach spec

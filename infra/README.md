# infra

Everything the two agents need to run that isn't agent code: OpenClaw
configuration, Pilot trust bootstrap, DuckDB and G-Brain storage layout,
Google OAuth credentials, health-intelligence server config, environment
variables, runbook.

This directory is the operator's surface. If you're setting the system up on
a fresh homelab box, start here.

## What lives here

| Concern | Owner |
|---|---|
| OpenClaw daemon config | `openclaw/gateway.toml` (template) |
| Skill manifests (paths to `agent-a/`, `agent-b/`) | `openclaw/skills.toml` |
| Pilot identity for the homelab node | `pilot/identity.json` — generated, never committed |
| Pilot trust list (iOS device IDs + agent identities) | `pilot/trust.json` |
| Agent A health warehouse | `data/health.duckdb` (created on first ingest) |
| Agent B GSuite warehouse | `data/gsuite.duckdb` (created on first GSuite pull) |
| G-Brain PGLite database (shared) | `data/gbrain.db` (created by `setup-gbrain`) |
| Google OAuth credentials | `.env` (gitignored) — `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REFRESH_TOKEN` |
| ZeroEntropy API key | `.env` — `ZEROENTROPY_API_KEY` |
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

### 3. Configure Google OAuth for Agent B

Agent B pulls Calendar, Drive, and Gmail via OAuth 2.0. You need a refresh
token with the appropriate scopes.

1. Create a project in [Google Cloud Console](https://console.cloud.google.com).
2. Enable APIs: Google Calendar, Google Drive, Gmail.
3. Create an OAuth 2.0 Client ID (Desktop app type).
4. Run the one-time consent flow to get a refresh token:

   ```sh
   python agent-b/coach/calendar_sync.py \
     --client-id $GOOGLE_CLIENT_ID \
     --client-secret $GOOGLE_CLIENT_SECRET \
     --auth-only
   ```

5. Add credentials to `infra/.env`:

   ```sh
   GOOGLE_CLIENT_ID=...
   GOOGLE_CLIENT_SECRET=...
   GOOGLE_REFRESH_TOKEN=...
   ```

### 3b. Configure ZeroEntropy for health-intelligence reranking

```sh
# Add to infra/.env
ZEROENTROPY_API_KEY=ze-...
```

health-intelligence reads this at startup. If absent, the server falls back
to raw retrieval scores (no reranking).

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

- Agent A is listening on Pilot port 1001 (health ingest), 1003 (query API), 1004 (change events)
- Agent B is running the GSuite pull loop and subscribing to Agent A on port 1004

### 8. Start health-intelligence server

```sh
cd ../health-intelligence
.venv/bin/python server.py &   # http://127.0.0.1:8741
```

Or install as a launchd/systemd unit from `services/`.

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
- Both agent skills running (`openclaw skill list`)
- Agent A DuckDB readable + sample count moved in the last hour
- Agent B DuckDB readable + GSuite sync timestamp recent
- G-Brain MCP endpoint reachable
- Pilot daemon up + iOS device in trusted peers
- health-intelligence server at port 8741 returning `{"status":"ok"}`

Exit code `0` if green, non-zero with the failing component named.

### Restart everything

```sh
launchctl kickstart -k gui/$(id -u)/com.openclaw.gateway
```

Skills come back with their state intact. Pilot identity is persistent on
disk; trust list is persistent; DuckDB is persistent; gbrain is persistent.
No data loss across a full restart.

### Rotate Google OAuth credentials

Run the consent flow again with `python agent-b/coach/calendar_sync.py --auth-only`, update
`GOOGLE_REFRESH_TOKEN` in `.env`, then restart Agent B: `openclaw skill restart agent-b`.

## Directory layout (when populated)

```
infra/
├── README.md                       this file
├── .env.example                    template; copy to .env and fill in
├── openclaw/
│   ├── gateway.toml                OpenClaw gateway config
│   └── skills.toml                 skill registry pointers
├── pilot/
│   ├── identity.json               generated, NEVER commit
│   ├── trust.json                  peer trust list (iOS + agent identities)
│   └── config.toml                 auto-approve, keepalive, etc.
├── data/
│   ├── health.duckdb               Agent A's health warehouse
│   ├── gsuite.duckdb               Agent B's GSuite warehouse
│   └── gbrain/                     G-Brain PGLite directory (shared)
├── services/
│   ├── com.openclaw.gateway.plist  launchd unit — OpenClaw daemon (macOS)
│   ├── openclaw.service            systemd unit (Linux)
│   └── health-intelligence.plist   launchd unit — FastAPI server (macOS)
└── scripts/
    ├── backup.sh
    ├── healthcheck.sh
    └── restore.sh
```

## Status

Spec complete — templates and scripts materialise as agents are deployed.
Agent A core is built (84 tests passing); Agent B framework is built (GSuite
pull pending); health-intelligence server is running. The infra layer wires
them together for production.

## Threat model in one paragraph

The homelab box is the trusted root. Anything that lands on its disk is
considered yours. The iOS device is trusted via Pilot identity (Ed25519,
persistent on the device). External services touched: Google (OAuth pull —
sees metadata, not raw health data), ZeroEntropy (sees intervention query
text for reranking), and whichever LLM is used for synthesis (sees prompt
summaries). Everything else — DuckDB, G-Brain, the Pilot overlay — is local.
Any of the three external services can be swapped out; the architecture
doesn't bind to them.

## See also

- [`../README.md`](../README.md) — overall architecture and data flow
- [`../health-sync`](../health-sync) — iOS app (HealthKit + 27 on-device models)
- [`../pilot-swift`](../pilot-swift) — Swift Pilot SDK embedded in the iOS app
- [`../agent-a`](../agent-a) — Health ingest agent (built)
- [`../agent-b`](../agent-b) — GSuite ingest agent (framework built)
- [`../health-intelligence`](../health-intelligence) — RAG + ZeroEntropy retrieval server
- [`../gstack-ios`](../gstack-ios) — iOS dev skill pack (used to build health-sync)

# infra

Everything needed to deploy and operate the two agents: Docker Compose files,
Dockerfiles, OpenClaw workspace configs, G-Brain setup scripts, secrets
layout, and operational runbook.

Deployed on GCP VM `hackathon-openclaw`. The two agent containers run
side-by-side with their own Pilot daemon identities.

## What lives here

| Path | What it is |
|---|---|
| `docker/docker-compose.yml` | Defines `g-stack-agent-a` and `g-stack-agent-b` containers |
| `docker/Dockerfile.agent-a` | Collector image: Python 3.13 + Pilot binaries + agent-a package |
| `docker/Dockerfile.agent-b` | Coach image: Python 3.13 + Pilot binaries + agent-b package |
| `docker/entrypoint-agent-a.sh` | Starts Pilot daemon, waits for socket, launches `python -m collector.server` |
| `docker/entrypoint-agent-b.sh` | Starts Pilot daemon, waits for socket, launches `python -m coach watch` |
| `docker/pilot-bin/` | Pre-built Linux Pilot daemon + pilotctl binaries for the container images |
| `secrets/` | Bind-mounted into agent-b at `/run/secrets` — Google OAuth tokens, API keys (gitignored) |
| `data/gbrain-collector-home/` | Collector's G-Brain PGLite database |
| `data/gbrain-coach-home/` | Coach's G-Brain PGLite database |
| `bin/gbrain-collector` | Wrapper script: sets HOME to gbrain-collector-home before calling gbrain CLI |
| `bin/gbrain-coach` | Wrapper script: sets HOME to gbrain-coach-home before calling gbrain CLI |
| `.env.example` | Template — copy to `~/.env` on the VM and fill in credentials |

## Container topology

```
hackathon-openclaw (GCP VM)
├── g-stack-agent-a          (port 4001/udp — Pilot daemon UDP endpoint)
│   ├── Pilot daemon  →  Collector node
│   ├── python -m collector.server
│   └── Docker volumes:
│       ├── docker_agent_a_data  → /var/collector_data  (facts.duckdb)
│       ├── docker_agent_a_pilot → /root/.pilot         (Pilot identity + inbox)
│       └── docker_agent_a_inbox → /var/collector_inbox (e2e test drop dir)
│
└── g-stack-agent-b          (port 4002/udp — Pilot daemon UDP endpoint)
    ├── Pilot daemon  →  Coach node
    ├── python -m coach watch
    └── Docker volumes:
        ├── docker_agent_b_pilot → /root/.pilot         (Pilot identity + inbox)
        ├── infra/secrets        → /run/secrets         (Google OAuth tokens)
        └── ~/brain              → /root/brain           (calendar markdown files)
```

Each container has its own Pilot daemon with a distinct identity. They
communicate via `pilotctl send-message` over the public Pilot overlay —
not via shared volumes or localhost networking.

## First-time setup on a fresh GCP VM

### 1. Clone the repo

```sh
git clone https://github.com/TeoSlayer/g-stack-hackathon ~/g-stack-hackathon
cd ~/g-stack-hackathon
```

### 2. Install prerequisites

```sh
# Docker + Docker Compose
curl -fsSL https://get.docker.com | sh

# OpenClaw (for Telegram channel + workspace orchestration)
# Follow install instructions from openclaw.dev

# G-Brain CLI
npm install -g @garrytan/gbrain  # or follow gbrain install docs

# Python venv for health-intelligence
python3 -m venv .venv && .venv/bin/pip install -r health-intelligence/requirements.txt
```

### 3. Set up secrets

Copy `.env.example` to `~/.env` and fill in:

```sh
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
GOOGLE_REFRESH_TOKEN=...   # from calendar_sync.py --auth-only
ZEROENTROPY_API_KEY=...
TELEGRAM_BOT_TOKEN=...
```

Create `infra/secrets/` (bind-mounted into agent-b):

```sh
mkdir -p infra/secrets
cp ~/.env infra/secrets/.env
```

### 4. Initialize G-Brain instances

```sh
mkdir -p infra/data/gbrain-collector-home infra/data/gbrain-coach-home
HOME=~/g-stack-hackathon/infra/data/gbrain-collector-home gbrain init
HOME=~/g-stack-hackathon/infra/data/gbrain-coach-home    gbrain init
```

### 5. Configure OpenClaw and wire Telegram

```sh
openclaw configure   # set gateway mode, LLM provider
openclaw channels add --channel telegram --token "$TELEGRAM_BOT_TOKEN"
openclaw agents bind --agent coach --bind telegram
```

### 6. Build and start containers

```sh
cd infra/docker
docker compose up --build -d
docker compose logs -f
```

### 7. Register Pilot peers (first run only)

Each container generates a fresh Pilot identity on first start. Approve
the iOS device trust request when the HealthSync app first connects:

```sh
# Inside agent-a container:
docker exec g-stack-agent-a /opt/pilot/bin/pilotctl pending
docker exec g-stack-agent-a /opt/pilot/bin/pilotctl approve <node_id>
```

### 8. Run Google Calendar OAuth consent (once)

```sh
python agent-b/coach/calendar_sync.py \
  --client-id "$GOOGLE_CLIENT_ID" \
  --client-secret "$GOOGLE_CLIENT_SECRET" \
  --auth-only
# Saves refresh token to secrets — copy to infra/secrets/
```

### 9. Seed G-Brain with calendar data

```sh
bash ~/g-stack-hackathon/seed_vm.sh
```

### 10. Start health-intelligence server

```sh
cd ~/g-stack-hackathon
nohup .venv/bin/python health-intelligence/server.py > /tmp/hi.log 2>&1 &
curl http://127.0.0.1:8741/health
```

## Operational tasks

### Redeploy after a code change

```sh
cd ~/g-stack-hackathon && git pull
cd infra/docker
docker compose up --build -d
```

Volumes persist across rebuilds — Pilot identities, DuckDB, G-Brain data
are not lost.

### Query the Collector warehouse

```sh
docker exec g-stack-agent-b python -m coach query \
  "SELECT type, COUNT(*) FROM samples GROUP BY type"

docker exec g-stack-agent-b python -m coach readiness
```

### Check G-Brain content

```sh
infra/bin/gbrain-collector list --tag calendar -n 5
infra/bin/gbrain-coach     list -n 10
```

### Health check

```sh
docker ps                                          # both containers running
docker logs g-stack-agent-a --tail 20             # recent envelope + query log
docker logs g-stack-agent-b --tail 20             # recent ChangeEvent + Telegram log
curl http://127.0.0.1:8741/health                 # health-intelligence up
docker exec g-stack-agent-a /opt/pilot/bin/pilotctl peers  # Pilot connectivity
```

### Rotate Google OAuth credentials

Run `calendar_sync.py --auth-only` again, update `infra/secrets/.env`,
then restart agent-b: `docker compose restart agent-b`.

## Directory layout

```
infra/
├── README.md                       this file
├── .env.example                    template — fill in and copy to ~/  
├── docker/
│   ├── docker-compose.yml          two-container deployment
│   ├── Dockerfile.agent-a          Collector image
│   ├── Dockerfile.agent-b          Coach image
│   ├── entrypoint-agent-a.sh       Pilot daemon + collector.server
│   ├── entrypoint-agent-b.sh       Pilot daemon + coach watch
│   └── pilot-bin/                  Linux pilot-daemon + pilotctl binaries
├── secrets/                        gitignored — bind-mounted into agent-b
│   └── .env                        Google OAuth, ZeroEntropy, Telegram tokens
├── data/
│   ├── gbrain-collector-home/      Collector's G-Brain PGLite database
│   └── gbrain-coach-home/          Coach's G-Brain PGLite database
└── bin/
    ├── gbrain-collector            wrapper: HOME=gbrain-collector-home gbrain
    └── gbrain-coach                wrapper: HOME=gbrain-coach-home gbrain
```

Note: `facts.duckdb` lives in Docker volume `docker_agent_a_data`, not in
this directory. Access it via `docker exec g-stack-agent-b python -m coach query`.

## Threat model

The GCP VM is the trusted root. The iOS device is trusted via Pilot identity
(Ed25519, persistent on device). External surfaces:

- **Google OAuth** — sees Calendar/Drive/Gmail metadata, not raw health data
- **ZeroEntropy** — sees intervention query text for reranking
- **Telegram** — sees the Coach's replies (health summaries, nudges)
- **LLM provider via OpenClaw** — sees the Coach's reasoning context

DuckDB, G-Brain, and Pilot identities are local to the VM.
Any external service can be swapped; the architecture doesn't bind to them.

## See also

- [`../README.md`](../README.md) — overall architecture and data flow
- [`../agent-a`](../agent-a) — Collector (health ingest)
- [`../agent-b`](../agent-b) — Coach (Telegram interface + rule models)
- [`../health-intelligence`](../health-intelligence) — RAG retrieval server
- [`../health-sync`](../health-sync) — iOS app (HealthKit + 27 on-device models)
- [`../pilot-swift`](../pilot-swift) — Swift Pilot SDK embedded in iOS app
- [`../gstack-ios`](../gstack-ios) — iOS dev skill pack

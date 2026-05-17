# Redeploy to GCP VM `hackathon-openclaw`

> **TL;DR — fully scripted path**
>
> ```bash
> gcloud compute scp --recurse ~/g-stack-hackathon hackathon-openclaw:~/
> gcloud compute ssh hackathon-openclaw --zone us-central1-a -- \
>     bash ~/g-stack-hackathon/infra/scripts/bootstrap-vm.sh
> # Then re-OAuth Google Calendar (step 7 below) and that's it.
> ```
>
> The script chains everything below into one idempotent run:
> docker → node → bun → uv → openclaw → gbrain → workspace venv →
> linux pilot binary → docker stack → openclaw gateway → patch env →
> register MCPs → install health-intelligence service → install coach
> proactive watch.

---


The current laptop setup uses Pilot's NAT-relay path (both daemons behind the
same household NAT) so query round-trip is 30–90s. The GCP VM
`hackathon-openclaw` has a public IP and no NAT loopback, so direct
peer-to-peer tunnels should drop latency to single-digit seconds.

This file is the **playbook**, not a script — read it once, run it deliberately.
Don't execute until the current laptop setup has produced positive results.

## Preconditions on the VM

- `hackathon-openclaw` VM provisioned in GCP
- SSH access via `gcloud compute ssh hackathon-openclaw`
- VM has a public static IP (so Pilot can advertise a fixed endpoint)
- Docker + Compose installed
- Likely `linux-amd64` (set `PILOT_ARCH=linux-amd64` in `update-pilot.sh`)

## Step 1 — Provision the VM

```bash
gcloud compute ssh hackathon-openclaw -- <<'EOF'
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin jq curl
sudo usermod -aG docker $USER
curl -fsSL https://bun.sh/install | bash      # gbrain runtime
curl -LsSf https://astral.sh/uv/install.sh | sh  # python tool
EOF
```

Re-login so the docker group membership applies.

## Step 2 — Sync the repo

```bash
gcloud compute scp --recurse ~/g-stack-hackathon hackathon-openclaw:~/
# OR: git push the repo and clone on the VM.
```

Do NOT copy:
- `infra/secrets/google-calendar-token.json` — re-OAuth on the VM (token has hardware-bound storage on macOS; portable but fragile)
- `.venv/` — recreate with `uv venv` + `uv pip install -e '.[dev]'`
- `agent_*_pilot` Docker volume contents — those generate **NEW** pilot identities on the VM, which is the whole point. Trust will be re-established.

DO copy:
- `infra/secrets/google-oauth-client.json` — same OAuth client works
- `agent-a/`, `agent-b/` source
- `infra/docker/` Dockerfiles + compose

## Step 3 — Bump pilot to latest

```bash
cd ~/g-stack-hackathon
PILOT_ARCH=linux-amd64 ./infra/docker/pilot-bin/update-pilot.sh
```

## Step 4 — Configure Pilot for a direct (non-relay) tunnel

In `infra/docker/Dockerfile.agent-a` and `Dockerfile.agent-b`, the
entrypoint already runs:

```
pilot-daemon -listen :4001 -registry ... -beacon ...
```

For the public VM, add `-endpoint <VM-public-ip>:<listen-port>` so Pilot
advertises the directly-reachable endpoint instead of relying on STUN. The
two ports (`:4001`, `:4002`) must be allowed by the GCP firewall (UDP).

Either:
- Edit the entrypoints to read a `PILOT_ENDPOINT` env, OR
- Pass `-fake-listen-addr` if you can't bind to the public IP directly inside the container

Open firewall:

```bash
gcloud compute firewall-rules create pilot-overlay \
  --network default --direction INGRESS \
  --action allow --rules udp:4001-4002
```

## Step 5 — Bring up the stack

```bash
cd ~/g-stack-hackathon
uv venv
uv pip install -e '.[dev]'
docker compose -f infra/docker/docker-compose.yml up -d --build
```

## Step 6 — Re-handshake the two daemons

```bash
# Get the new node IDs (different from 193232 / 193233 — fresh identities)
docker exec g-stack-agent-a tail -3 /var/log/pilot.log | grep daemon.running
docker exec g-stack-agent-b tail -3 /var/log/pilot.log | grep daemon.running

# Two handshakes for mutual trust auto-approval
docker exec g-stack-agent-a pilotctl handshake <b_node_id>
docker exec g-stack-agent-b pilotctl handshake <a_node_id>

# Verify
docker exec g-stack-agent-a pilotctl trust
```

Then update the Coach env `COLLECTOR_NODE_ID` in
`infra/docker/docker-compose.yml` to the new agent-a node id, rebuild
agent-b.

## Step 7 — Re-OAuth Google Calendar

The Desktop OAuth client only redirects to `localhost:<port>` and that
needs to reach the container. Two options:

A. **SSH tunnel** during the OAuth flow:
   ```bash
   gcloud compute ssh hackathon-openclaw -- -L 9090:localhost:9090
   ```
   On the VM, run the calendar_sync; on your laptop, open the printed URL.
   Local-loopback redirect gets tunneled through to the container.

B. **Cache the token on the laptop, copy** (works but fragile across OS):
   ```bash
   gcloud compute scp ~/g-stack-hackathon/infra/secrets/google-calendar-token.json \
                    hackathon-openclaw:~/g-stack-hackathon/infra/secrets/
   ```

## Step 8 — Re-seed gbrains

The host gbrains are tied to PGLite files. Either:

A. **Fresh init on the VM:**
   ```bash
   mkdir -p ~/g-stack-hackathon/infra/data/gbrain-{collector,coach}-home
   HOME=~/g-stack-hackathon/infra/data/gbrain-collector-home gbrain init
   HOME=~/g-stack-hackathon/infra/data/gbrain-coach-home gbrain init
   # then re-import calendar (after step 7)
   ~/g-stack-hackathon/infra/bin/gbrain-collector import ~/brain/daily/calendar/
   ~/g-stack-hackathon/infra/bin/gbrain-coach import ~/brain/daily/calendar/
   ```

B. **Migrate** PGLite from the laptop:
   ```bash
   gcloud compute scp --recurse \
     ~/g-stack-hackathon/infra/data/gbrain-collector-home \
     ~/g-stack-hackathon/infra/data/gbrain-coach-home \
     hackathon-openclaw:~/g-stack-hackathon/infra/data/
   ```
   PGLite is a single-file-ish layout so this works.

## Step 9 — Re-ship the mock health data

```bash
cd ~/g-stack-hackathon
.venv/bin/python scripts/mock_health_pipeline.py \
  --start 2026-05-03 --end 2026-05-16 \
  --workout-days 2026-05-05,2026-05-10
```

## Step 10 — Add the two OpenClaw agents

```bash
openclaw agents add collector --workspace ~/g-stack-hackathon/.openclaw/collector-workspace
openclaw agents add coach     --workspace ~/g-stack-hackathon/.openclaw/coach-workspace
```

The IDENTITY.md + TOOLS.md files in the workspace dirs come along with the
repo, so the agent personas are preserved.

## Step 11 — Verify latency dropped

```bash
time docker exec g-stack-agent-b python -m coach query \
  "SELECT type, COUNT(*) FROM samples GROUP BY type ORDER BY 2 DESC LIMIT 5"
```

Target: well under 10s. If still 30s+, check `pilotctl peers` for
`relay=false` on the b↔a tunnel.

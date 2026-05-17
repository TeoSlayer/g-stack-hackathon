"""Host-side proactive loop.

Runs on the GCP VM host (NOT inside the agent-b container). Reasons:
  - The host already has the canonical gbrain CLI installed at
    ~/.bun/bin/gbrain. We don't duplicate that into the container.
  - The host already has OpenClaw + the Telegram channel configured. Nudges
    go out through the SAME bot (@yccoachbot) that's already paired —
    we don't add a second Telegram surface.
  - The host's ~/.env has the bot token. The container doesn't need it.

What this script does on each tick:
  1. Query the Collector's warehouse via `docker exec g-stack-agent-b
     pilotctl send-message 193232 --data <Query JSON>`. (Same wire path
     the Coach LLM uses for SQL.)
  2. Run each rule against the rows. Emit RuleResults.
  3. For results that fire AND aren't on cooldown:
        a. write an insight to gbrain-coach-home (host CLI: gbrain put)
        b. send a Telegram nudge via OpenClaw's existing bot
        c. bump the cooldown
  4. Always: refresh per-day daily-summary gbrain pages so the brain
     grows as new data lands.

Designed to be run by `infra/scripts/install-coach-proactive.sh` as a
systemd timer (or invoked manually).
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import os
import subprocess
import sys
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


log = logging.getLogger("coach.host_proactive")


# ─── config (env-driven) ─────────────────────────────────────────────────────

HOME = os.path.expanduser("~")
REPO = os.environ.get("G_STACK_REPO", f"{HOME}/g-stack-hackathon")
GBRAIN_HOME = os.environ.get(
    "COACH_GBRAIN_HOME", f"{REPO}/infra/data/gbrain-coach-home"
)
GBRAIN_BIN = os.environ.get("GBRAIN_BIN", f"{HOME}/.bun/bin/gbrain")
AGENT_B_CONTAINER = os.environ.get("AGENT_B_CONTAINER", "g-stack-agent-b")
COLLECTOR_NODE = os.environ.get("COLLECTOR_NODE_ID", "193232")
COOLDOWNS_PATH = Path(os.environ.get(
    "COACH_COOLDOWNS_PATH", f"{REPO}/infra/data/coach-cooldowns.json"
))
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.environ.get("COACH_TELEGRAM_CHAT_ID")


# ─── transport: query Collector via docker exec → pilotctl ───────────────────

def _query_collector(sql: str, *, top_k: int = 2000, timeout: int = 90) -> list[dict]:
    """Send a SQL Query envelope through agent-b's pilot daemon and wait for
    the QueryResult. We use docker exec because pilotctl lives inside the
    container; this script runs on the host.
    """
    request_id = str(uuid.uuid4())
    query_body = {
        "v": 1, "request_id": request_id, "reply_port": 1005,
        "kind": "sql", "sql": sql, "params": [], "limit": top_k,
    }
    payload = json.dumps(query_body)

    # 1. Clear stale matching replies (harmless — we look up by request_id)
    # 2. Send
    send_cmd = [
        "docker", "exec", AGENT_B_CONTAINER,
        "pilotctl", "send-message", COLLECTOR_NODE,
        "--data", payload, "--type", "json",
    ]
    try:
        subprocess.run(send_cmd, check=True, capture_output=True, text=True, timeout=15)
    except subprocess.CalledProcessError as e:
        log.warning("pilotctl send failed: %s", e.stderr.strip())
        return []

    # 3. Poll agent-b's inbox for a TEXT-* file containing our request_id.
    deadline = _dt.datetime.now().timestamp() + timeout
    import time
    while _dt.datetime.now().timestamp() < deadline:
        ls = subprocess.run(
            ["docker", "exec", AGENT_B_CONTAINER, "sh", "-c",
             "ls /root/.pilot/inbox/TEXT-*.json 2>/dev/null"],
            capture_output=True, text=True,
        )
        files = [l for l in ls.stdout.strip().split("\n") if l]
        for path in files:
            cat = subprocess.run(
                ["docker", "exec", AGENT_B_CONTAINER, "cat", path],
                capture_output=True, text=True,
            )
            try:
                wrapper = json.loads(cat.stdout)
            except Exception:
                continue
            inner_raw = wrapper.get("data")
            if not isinstance(inner_raw, str):
                continue
            try:
                inner = json.loads(inner_raw)
            except Exception:
                continue
            if inner.get("request_id") != request_id:
                continue
            # found it — clean up the file so future polls don't re-find it
            subprocess.run(
                ["docker", "exec", AGENT_B_CONTAINER, "rm", "-f", path],
                capture_output=True,
            )
            if not inner.get("ok"):
                log.warning("query returned error: %s", inner.get("error"))
                return []
            return inner.get("rows") or []
        time.sleep(0.5)
    log.warning("query timed out after %ss waiting for request_id %s",
                timeout, request_id)
    return []


# ─── side effects ────────────────────────────────────────────────────────────

def _gbrain_put(slug: str, body: str) -> bool:
    """Write a page to the coach gbrain via host CLI. HOME pinned."""
    env = {**os.environ, "HOME": GBRAIN_HOME}
    try:
        subprocess.run(
            [GBRAIN_BIN, "put", slug],
            input=body, env=env, check=True,
            capture_output=True, text=True, timeout=60,
        )
        return True
    except subprocess.CalledProcessError as e:
        log.warning("gbrain put %s failed: %s", slug, e.stderr[:200])
        return False
    except Exception as e:
        log.warning("gbrain put %s failed: %s", slug, e)
        return False


def _telegram_push(text: str) -> bool:
    """Send a proactive message via the SAME bot that's bound to OpenClaw.

    OpenClaw's gateway has the bot in polling mode (read replies). For
    proactive sends, the cleanest path is calling Telegram's Bot API
    directly with the same token openclaw uses. No new bot, no new
    pairing — same `@yccoachbot`, just an outbound push.
    """
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        log.warning("telegram push skipped — TELEGRAM_BOT_TOKEN or COACH_TELEGRAM_CHAT_ID missing")
        return False
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    body = urllib.parse.urlencode({
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
        "parse_mode": "Markdown",
        "disable_web_page_preview": True,
    }).encode("utf-8")
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=10) as r:
            data = json.loads(r.read())
            if data.get("ok"):
                return True
            log.warning("telegram non-ok: %s", data)
            return False
    except Exception as e:
        log.warning("telegram send error: %s", e)
        return False


# ─── cooldowns ───────────────────────────────────────────────────────────────

@dataclass
class Cooldowns:
    path: Path

    def __post_init__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._data: dict[str, float] = {}
        if self.path.exists():
            try:
                self._data = json.loads(self.path.read_text())
            except Exception:
                self._data = {}

    def active(self, rule_id: str, hours: float) -> bool:
        last = self._data.get(rule_id, 0.0)
        return (_dt.datetime.now().timestamp() - last) < hours * 3600.0

    def touch(self, rule_id: str) -> None:
        self._data[rule_id] = _dt.datetime.now().timestamp()
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._data, indent=2))
        tmp.replace(self.path)


# ─── adapter to reuse the existing rules ─────────────────────────────────────

class _CoachAdapter:
    """Quacks like coach.client.Coach for the existing Rule classes:
    only `.query(sql, limit=...)` is needed."""

    def query(self, sql: str, params=None, limit: Optional[int] = None) -> dict:
        rows = _query_collector(sql, top_k=limit or 2000)
        return {"ok": True, "rows": rows, "row_count": len(rows)}


# ─── entrypoint ──────────────────────────────────────────────────────────────

def main() -> int:
    logging.basicConfig(
        level=os.environ.get("COACH_LOG", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    # Late import so the script remains a single file with no python-path requirements.
    sys.path.insert(0, str(Path(REPO) / "agent-b"))
    from coach.rules import ALL_RULES

    coach = _CoachAdapter()
    cooldowns = Cooldowns(COOLDOWNS_PATH)

    log.info(
        "host_proactive starting — rules=%s container=%s collector=%s gbrain_home=%s telegram=%s",
        [r.__name__ for r in ALL_RULES], AGENT_B_CONTAINER, COLLECTOR_NODE,
        GBRAIN_HOME, "yes" if (TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID) else "no",
    )

    # 1. brain growth: daily-summary pages
    rows = _query_collector("""
        SELECT date_trunc('day', to_timestamp(start_utc)) AS day,
               type, ROUND(AVG(value), 2) AS avg_v, COUNT(*) AS n
        FROM samples
        WHERE start_utc > epoch_ms(now() - INTERVAL '3 days') / 1000
        GROUP BY 1, 2 ORDER BY 1 DESC, 2
    """, top_k=200)
    by_day: dict[str, dict[str, dict]] = {}
    for r in rows:
        day = str(r["day"])[:10]
        by_day.setdefault(day, {})[r["type"]] = {"avg": r["avg_v"], "n": r["n"]}
    days_written = 0
    for day, types in sorted(by_day.items()):
        weekday = _dt.date.fromisoformat(day).strftime("%A")
        body = (
            "---\n"
            "type: daily-summary\n"
            f"title: {day} ({weekday})\n"
            f"date: '{day}T00:00:00.000Z'\n"
            "source: coach.host_proactive\n"
            "tags: [daily-summary, autogen]\n"
            "---\n\n"
            f"# Daily summary — {day} ({weekday})\n\n"
        )
        for t in sorted(types):
            v = types[t]
            body += f"- **{t}** — avg {v['avg']} (n={v['n']})\n"
        body += "\n_Auto-generated from the Collector warehouse._\n"
        if _gbrain_put(f"daily-summaries/{day}", body):
            days_written += 1

    # 2. rule loop
    fired: list[dict] = []
    for cls in ALL_RULES:
        rule = cls()
        try:
            result = rule.evaluate(coach)
        except Exception as e:
            log.warning("rule %s crashed: %s", rule.id, e)
            continue
        if result is None:
            log.info("rule %s: insufficient data, skipped", rule.id)
            continue
        log.info("rule %s: band=%s value=%s", rule.id, result.band.value, result.value)
        if not result.fires:
            continue
        if cooldowns.active(rule.id, rule.default_cooldown_h):
            log.info("rule %s would fire but is on cooldown", rule.id)
            continue
        msg = f"⚠️ *{rule.title}*\n\n{result.message}"
        _telegram_push(msg)
        today = _dt.date.today().isoformat()
        slug = f"insights/{today}-{rule.id}"
        body = (
            "---\n"
            "type: insight\n"
            f"date: '{today}T00:00:00.000Z'\n"
            "source: coach.host_proactive\n"
            f"rule_id: {rule.id}\nband: {result.band.value}\n"
            f"tags: [coach, rule, {rule.id}]\n"
            "---\n\n"
            f"# {rule.title} — {today} ({result.band.value.upper()})\n\n"
            f"{result.message}\n\n"
            "## Detail\n\n```json\n"
            f"{json.dumps(result.detail, indent=2)}\n"
            "```\n\n"
            f"Value: **{result.value}**\n"
        )
        _gbrain_put(slug, body)
        cooldowns.touch(rule.id)
        fired.append({"rule_id": rule.id, "band": result.band.value,
                      "value": result.value, "message": result.message})

    summary = {
        "days_written_to_gbrain": days_written,
        "rules_fired": fired,
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

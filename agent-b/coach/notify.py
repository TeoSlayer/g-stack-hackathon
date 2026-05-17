"""TelegramNotifier — direct Telegram Bot API call.

We don't go through the OpenClaw gateway because gateway-routed messages
travel as replies to inbound user messages. Proactive nudges are pushes
— the bot reaches out unprompted — so we call Telegram's `sendMessage`
endpoint directly with the bot token.

Configuration is loaded from env:
  TELEGRAM_BOT_TOKEN    bot's API token (required)
  COACH_TELEGRAM_CHAT_ID  the user's chat id to push to (required)

If `COACH_TELEGRAM_CHAT_ID` is unset, the notifier reads
~/.openclaw/openclaw.json and pulls the single owner chat from
`commands.ownerAllowFrom` (the value that's set when the user runs
`openclaw pairing approve telegram <code>`). This avoids you having to
hand-stamp the chat id.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Optional


log = logging.getLogger("coach.notify")


class TelegramNotifier:
    def __init__(
        self,
        *,
        bot_token: Optional[str] = None,
        chat_id: Optional[str] = None,
        api_base: str = "https://api.telegram.org",
    ):
        self.bot_token = bot_token or os.environ.get("TELEGRAM_BOT_TOKEN")
        self.chat_id = chat_id or os.environ.get("COACH_TELEGRAM_CHAT_ID") or _autodetect_chat_id()
        self.api_base = api_base.rstrip("/")

    @property
    def configured(self) -> bool:
        return bool(self.bot_token and self.chat_id)

    def send(self, text: str, *, parse_mode: str = "Markdown") -> bool:
        if not self.configured:
            log.warning(
                "TelegramNotifier missing config (token=%s chat=%s) — skipping",
                bool(self.bot_token), bool(self.chat_id),
            )
            return False
        url = f"{self.api_base}/bot{self.bot_token}/sendMessage"
        payload = {
            "chat_id": self.chat_id,
            "text": text,
            "parse_mode": parse_mode,
            "disable_web_page_preview": True,
        }
        body = urllib.parse.urlencode(payload).encode("utf-8")
        req = urllib.request.Request(url, data=body)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                if not data.get("ok"):
                    log.warning("telegram sendMessage non-ok: %s", data)
                    return False
                return True
        except Exception as e:
            log.warning("telegram sendMessage error: %s", e)
            return False


def _autodetect_chat_id() -> Optional[str]:
    """Read OpenClaw config and find the approved Telegram chat id."""
    candidates = [
        Path("/root/.openclaw/openclaw.json"),
        Path.home() / ".openclaw" / "openclaw.json",
    ]
    for path in candidates:
        if not path.exists():
            continue
        try:
            cfg = json.loads(path.read_text())
        except Exception:
            continue
        # Try a few schema variants
        commands = cfg.get("commands") or {}
        owners = commands.get("ownerAllowFrom") or commands.get("owner_allow_from") or []
        for entry in owners:
            # Each entry like "telegram:8579139191" or {"channel": "telegram", "id": "..."}
            if isinstance(entry, str) and ":" in entry:
                kind, ident = entry.split(":", 1)
                if kind.strip().lower() == "telegram":
                    return ident.strip()
            if isinstance(entry, dict):
                if entry.get("channel") == "telegram" and entry.get("id"):
                    return str(entry["id"])
        # Also look in channels.telegram.* for first pairing
        channels = cfg.get("channels") or {}
        telegram = channels.get("telegram") or {}
        accounts = telegram.get("accounts") or {}
        for _name, acct in accounts.items():
            owners = (acct or {}).get("owners") or []
            for o in owners:
                if isinstance(o, str) and o.isdigit():
                    return o
                if isinstance(o, dict) and o.get("id"):
                    return str(o["id"])
    return None

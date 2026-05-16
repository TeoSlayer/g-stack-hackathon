"""Google Calendar → markdown → gbrain.

A standalone re-implementation of gbrain's `calendar-to-brain` Option B
flow, using a Desktop-app OAuth2 client. Steps:

  1. Run the local-loopback OAuth flow if no refresh token is stored
     (opens a browser; you sign in once; tokens cached to disk).
  2. List the user's calendars (or only the ones in --calendars).
  3. Paginate events in a date range; write one markdown file per day
     to brain/daily/calendar/YYYY/YYYY-MM-DD.md.
  4. Mirror raw API responses under brain/daily/calendar/.raw/.
  5. (Optional) `gbrain import` and `gbrain embed --stale`.

This script is idempotent: re-runs overwrite the same daily files with the
latest data. Manual notes appended below the calendar block survive (we
only rewrite lines we own; see `_merge_with_existing_notes`).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import logging
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build


log = logging.getLogger("coach.calendar")

SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]
HOME = Path.home()
DEFAULT_CLIENT = HOME / "g-stack-hackathon" / "infra" / "secrets" / "google-oauth-client.json"
DEFAULT_TOKEN = HOME / "g-stack-hackathon" / "infra" / "secrets" / "google-calendar-token.json"
DEFAULT_BRAIN = HOME / "brain" / "daily" / "calendar"

# Boundary markers so we can re-run safely without trampling user notes below.
HEADER_MARK = "<!-- calendar:autogen:start -->"
FOOTER_MARK = "<!-- calendar:autogen:end -->"


# ─── OAuth ───────────────────────────────────────────────────────────────────

def load_credentials(
    *,
    client_secret_path: Path,
    token_path: Path,
    port: int = 0,
    open_browser: bool = True,
) -> Credentials:
    """Return valid Google credentials. Runs the local-loopback flow on first
    use; refreshes silently on later calls."""
    token_path.parent.mkdir(parents=True, exist_ok=True)
    creds: Optional[Credentials] = None
    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)
    if creds and creds.valid:
        return creds
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
        token_path.write_text(creds.to_json())
        return creds
    flow = InstalledAppFlow.from_client_secrets_file(str(client_secret_path), SCOPES)
    # bind_addr=0.0.0.0 makes the listener reachable through Docker's port-forward;
    # host=localhost keeps the redirect URI Google sees identical.
    creds = flow.run_local_server(
        host="localhost",
        bind_addr="0.0.0.0",
        port=port,
        open_browser=open_browser,
        success_message="You can close this tab — Calendar Sync is connected.",
        authorization_prompt_message=(
            "Visit this URL in a browser signed into the target Google account:\n\n{url}\n"
        ),
    )
    token_path.write_text(creds.to_json())
    token_path.chmod(0o600)
    return creds


# ─── Calendar fetch ──────────────────────────────────────────────────────────

def list_calendars(creds: Credentials) -> list[dict]:
    service = build("calendar", "v3", credentials=creds, cache_discovery=False)
    cals = []
    page = None
    while True:
        resp = service.calendarList().list(pageToken=page).execute()
        cals.extend(resp.get("items", []))
        page = resp.get("nextPageToken")
        if not page:
            break
    return cals


def fetch_events(
    creds: Credentials,
    *,
    calendar_id: str,
    start: _dt.datetime,
    end: _dt.datetime,
) -> list[dict]:
    service = build("calendar", "v3", credentials=creds, cache_discovery=False)
    events: list[dict] = []
    page = None
    while True:
        resp = service.events().list(
            calendarId=calendar_id,
            timeMin=start.isoformat(),
            timeMax=end.isoformat(),
            singleEvents=True,
            orderBy="startTime",
            maxResults=2500,
            pageToken=page,
        ).execute()
        events.extend(resp.get("items", []))
        page = resp.get("nextPageToken")
        if not page:
            break
    return events


# ─── Markdown rendering ──────────────────────────────────────────────────────

def _local_date(ev: dict) -> Optional[str]:
    start = ev.get("start") or {}
    if "date" in start:
        return start["date"]  # all-day events: YYYY-MM-DD
    if "dateTime" in start:
        return _dt.datetime.fromisoformat(start["dateTime"]).date().isoformat()
    return None


def _local_time(ev: dict, field: str = "start") -> Optional[str]:
    v = ev.get(field) or {}
    if "dateTime" in v:
        return _dt.datetime.fromisoformat(v["dateTime"]).strftime("%H:%M")
    return None


def _attendee_names(ev: dict) -> list[str]:
    out = []
    for a in ev.get("attendees", []) or []:
        if a.get("self"):
            continue
        if a.get("responseStatus") == "declined":
            continue
        name = a.get("displayName") or _email_to_name(a.get("email", ""))
        if name and name not in out:
            out.append(name)
    return out


def _email_to_name(email: str) -> str:
    local = email.split("@", 1)[0]
    parts = re.split(r"[._+-]", local)
    return " ".join(p.capitalize() for p in parts if p)


def render_daily(
    *,
    date: str,
    calendar_label: str,
    events_for_date: list[dict],
) -> str:
    """Produce the autogen block for a single date."""
    weekday = _dt.date.fromisoformat(date).strftime("%A")
    lines: list[str] = [
        HEADER_MARK,
        f"# {date} ({weekday})",
        "",
    ]
    if not events_for_date:
        lines.append("_No calendar events._")
        lines.append("")
        lines.append(FOOTER_MARK)
        return "\n".join(lines)

    # All-day first, then timed by start
    def sort_key(e):
        t = _local_time(e, "start")
        return (1, t) if t else (0, e.get("summary", ""))

    for ev in sorted(events_for_date, key=sort_key):
        if ev.get("status") == "cancelled":
            continue
        title = ev.get("summary") or "(no title)"
        t1 = _local_time(ev, "start")
        t2 = _local_time(ev, "end")
        when = f"{t1}-{t2}" if t1 and t2 else "all-day"
        location = ev.get("location")
        loc_s = f" 📍 {location}" if location else ""
        attendees = _attendee_names(ev)
        att_s = f" — with {', '.join(attendees)}" if attendees else ""
        lines.append(f"- {when} **{title}** ({calendar_label}){loc_s}{att_s}")

    lines.append("")
    lines.append(FOOTER_MARK)
    return "\n".join(lines)


def _frontmatter(date: str, account: str, label: str) -> str:
    return (
        "---\n"
        "type: daily\n"
        f"title: {date.replace('-', ' ')}\n"
        f"date: '{date}T00:00:00.000Z'\n"
        "source: google-calendar\n"
        f"account: {account}\n"
        "tags:\n"
        "  - calendar\n"
        f"  - {label.lower()}\n"
        "---\n\n"
    )


def _merge_with_existing_notes(existing: str, new_autogen: str) -> str:
    """Preserve anything OUTSIDE the autogen markers; replace what's inside."""
    if HEADER_MARK in existing and FOOTER_MARK in existing:
        before, _rest = existing.split(HEADER_MARK, 1)
        _, after = _rest.split(FOOTER_MARK, 1)
        return before.rstrip() + "\n" + new_autogen + after
    # No prior autogen block — preserve everything, append a fresh block at top.
    return new_autogen + "\n\n" + existing.lstrip()


def write_daily_file(
    *,
    out_dir: Path,
    date: str,
    account: str,
    label: str,
    body: str,
):
    year_dir = out_dir / date[:4]
    year_dir.mkdir(parents=True, exist_ok=True)
    path = year_dir / f"{date}.md"
    autogen = _frontmatter(date, account, label) + body + "\n"
    if path.exists():
        existing = path.read_text()
        merged = _merge_with_existing_notes(existing, autogen)
        path.write_text(merged)
    else:
        path.write_text(autogen)


# ─── Orchestrator ────────────────────────────────────────────────────────────

def sync(
    *,
    client_secret_path: Path,
    token_path: Path,
    brain_dir: Path,
    start: _dt.date,
    end: _dt.date,
    calendars: Optional[list[str]] = None,
    account_label: str = "primary",
    open_browser: bool = True,
    run_gbrain_import: bool = True,
    oauth_port: int = 0,
) -> dict:
    creds = load_credentials(
        client_secret_path=client_secret_path,
        token_path=token_path,
        open_browser=open_browser,
        port=oauth_port,
    )

    all_calendars = list_calendars(creds)
    if calendars:
        target = [c for c in all_calendars if c["id"] in calendars]
    else:
        target = [c for c in all_calendars if c.get("primary")]
    if not target:
        target = all_calendars[:1]  # graceful fallback
    log.info("syncing %d calendars in range %s..%s",
             len(target), start.isoformat(), end.isoformat())

    raw_dir = brain_dir / ".raw"
    raw_dir.mkdir(parents=True, exist_ok=True)

    # Group events by date across all selected calendars.
    by_date: dict[str, list[tuple[str, dict]]] = {}
    range_label = f"{start.isoformat()}_{end.isoformat()}"
    range_start = _dt.datetime.combine(start, _dt.time.min, tzinfo=_dt.UTC)
    range_end = _dt.datetime.combine(end, _dt.time.max, tzinfo=_dt.UTC)
    for cal in target:
        cal_label = cal.get("summary") or cal["id"]
        events = fetch_events(
            creds, calendar_id=cal["id"], start=range_start, end=range_end,
        )
        raw_path = raw_dir / f"events_{_safe(cal_label)}_{range_label}.json"
        raw_path.write_text(json.dumps(events, indent=2, ensure_ascii=False))
        for ev in events:
            d = _local_date(ev)
            if d is None:
                continue
            if start.isoformat() <= d <= end.isoformat():
                by_date.setdefault(d, []).append((cal_label, ev))

    # One markdown file per date.
    days_written = 0
    for date, items in sorted(by_date.items()):
        # Group items by calendar so the markdown sub-bullets share a label.
        for cal_label in {it[0] for it in items}:
            cal_events = [ev for lbl, ev in items if lbl == cal_label]
            body = render_daily(date=date, calendar_label=cal_label,
                                events_for_date=cal_events)
            write_daily_file(out_dir=brain_dir, date=date,
                             account=account_label, label=cal_label, body=body)
        days_written += 1

    log.info("wrote %d daily files under %s", days_written, brain_dir)

    # Optional: import into gbrain.
    if run_gbrain_import:
        try:
            subprocess.run(["gbrain", "import", str(brain_dir), "--no-embed"],
                            check=True, capture_output=True, timeout=600)
            subprocess.run(["gbrain", "embed", "--stale"], check=True,
                            capture_output=True, timeout=1200)
            log.info("gbrain import + embed complete")
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            log.warning("gbrain import failed (markdown still on disk): %s", e)

    return {
        "calendars": [c.get("summary") or c["id"] for c in target],
        "days_written": days_written,
        "range": [start.isoformat(), end.isoformat()],
    }


def _safe(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", s)


def _parse_date(s: str) -> _dt.date:
    return _dt.date.fromisoformat(s)


def main():
    parser = argparse.ArgumentParser(description="Google Calendar → gbrain")
    parser.add_argument("--client-secret", default=str(DEFAULT_CLIENT),
                        help="Path to OAuth client JSON")
    parser.add_argument("--token", default=str(DEFAULT_TOKEN),
                        help="Where to cache the refresh token")
    parser.add_argument("--brain-dir", default=str(DEFAULT_BRAIN),
                        help="Output directory for daily markdown")
    parser.add_argument("--start", default=None,
                        help="Start date YYYY-MM-DD (default: 30 days ago)")
    parser.add_argument("--end", default=None,
                        help="End date YYYY-MM-DD (default: 30 days from now)")
    parser.add_argument("--calendar", action="append", default=None,
                        help="Calendar ID to sync (repeatable; default: primary)")
    parser.add_argument("--account-label", default="primary",
                        help="account: frontmatter value")
    parser.add_argument("--no-browser", action="store_true",
                        help="Print the auth URL instead of opening a browser")
    parser.add_argument("--port", type=int, default=0,
                        help="OAuth local-loopback port (default: ephemeral)")
    parser.add_argument("--no-gbrain", action="store_true",
                        help="Skip gbrain import + embed")
    args = parser.parse_args()

    logging.basicConfig(level=os.environ.get("CAL_LOG", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")

    today = _dt.date.today()
    start = _parse_date(args.start) if args.start else today - _dt.timedelta(days=30)
    end = _parse_date(args.end) if args.end else today + _dt.timedelta(days=30)

    summary = sync(
        client_secret_path=Path(args.client_secret).expanduser(),
        token_path=Path(args.token).expanduser(),
        brain_dir=Path(args.brain_dir).expanduser(),
        start=start, end=end,
        calendars=args.calendar,
        account_label=args.account_label,
        open_browser=not args.no_browser,
        run_gbrain_import=not args.no_gbrain,
        oauth_port=args.port,
    )
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

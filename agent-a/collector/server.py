"""Collector daemon entry point (agent-a).

Wires the polling inbox watcher, the DuckDB warehouse, the trust policy,
and the outgoing transport together. Default paths follow infra/README:

  inbox:        ~/.pilot/inbox
  warehouse:    <repo>/infra/data/facts.duckdb     (or --var override)
  acks:         <var>/acks_out/
  events:       <var>/events_log/
  poll:         1.0s

This module owns NOTHING about gbrain or markdown — those concerns moved to
agent-b. The Collector is a pure warehouse + Pilot listener.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
from pathlib import Path

from .change_event import ChangeEventBroadcaster
from .inbox_watcher import InboxWatcher, WatcherConfig
from .transport import FileTransport, PilotctlTransport, TeeTransport
from .trust import TrustPolicy
from .warehouse import Warehouse


HOME = Path.home()
DEFAULT_INBOX = HOME / ".pilot" / "inbox"
# Repo-relative default (infra/data/facts.duckdb). When invoked via `collector`
# entrypoint from anywhere we resolve against $G_STACK_HOME if set, else CWD.
_REPO = Path(os.environ.get("G_STACK_HOME", Path.cwd()))
DEFAULT_VAR = _REPO / "infra" / "data"


def _build_trust(config_path: Path | None) -> TrustPolicy:
    if config_path and config_path.exists():
        try:
            return TrustPolicy.from_config(json.loads(config_path.read_text()))
        except Exception as e:
            logging.warning("trust config unreadable, defaulting to wildcard: %s", e)
    return TrustPolicy()


def build_runtime(
    *,
    inbox: Path = DEFAULT_INBOX,
    var: Path = DEFAULT_VAR,
    trust_config: Path | None = None,
    use_pilotctl: bool = False,
    poll_interval_s: float = 1.0,
    warehouse_path: Path | None = None,
) -> InboxWatcher:
    var.mkdir(parents=True, exist_ok=True)
    wh_path = warehouse_path or (var / "facts.duckdb")
    warehouse = Warehouse(wh_path)
    trust = _build_trust(trust_config)

    file_transport = FileTransport(var / "acks_out")
    if use_pilotctl:
        transport = TeeTransport([file_transport, PilotctlTransport()])
    else:
        transport = file_transport

    events = ChangeEventBroadcaster(
        transport=transport,
        event_log_dir=var / "events_log",
        subscribers=trust.subscribed_coaches(),
    )

    watcher = InboxWatcher(
        config=WatcherConfig(
            inbox_dir=inbox,
            archive_dir=inbox / ".archive",
            unrecognized_dir=inbox / ".unrecognized",
            poll_interval_s=poll_interval_s,
        ),
        warehouse=warehouse,
        trust=trust,
        transport=transport,
        events=events,
    )
    return watcher


def main():
    parser = argparse.ArgumentParser(description="HealthSync Collector daemon (agent-a)")
    parser.add_argument("--inbox", default=str(DEFAULT_INBOX), help="Pilot inbox to watch")
    parser.add_argument("--var", default=str(DEFAULT_VAR), help="Runtime data dir")
    parser.add_argument("--warehouse", default=None,
                        help="Override DuckDB path (default: <var>/facts.duckdb)")
    parser.add_argument("--trust", default=None, help="Trust config JSON path")
    parser.add_argument("--pilotctl", action="store_true", help="Send Acks via pilotctl too")
    parser.add_argument("--poll", type=float, default=1.0, help="Poll interval seconds")
    parser.add_argument("--once", action="store_true", help="Run a single tick then exit")
    args = parser.parse_args()

    logging.basicConfig(
        level=os.environ.get("COLLECTOR_LOG", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    watcher = build_runtime(
        inbox=Path(args.inbox).expanduser(),
        var=Path(args.var).expanduser(),
        trust_config=Path(args.trust).expanduser() if args.trust else None,
        use_pilotctl=args.pilotctl,
        poll_interval_s=args.poll,
        warehouse_path=Path(args.warehouse).expanduser() if args.warehouse else None,
    )
    if args.once:
        counters = watcher.tick()
        print(json.dumps(counters, indent=2))
        return
    try:
        watcher.run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

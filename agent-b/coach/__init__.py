"""Coach client — runs on a separate Pilot identity from the Collector.

Speaks the wire schema's Query/QueryResult/ChangeEvent surface:
  - sends Query messages to the Collector on port 1003
  - listens for QueryResult on its own reply_port
  - subscribes to ChangeEvent on port 1004

The Coach is intentionally stateless: every tick it runs the same set of
SQL queries against the Collector and surfaces the results. Derived state
(baselines, readiness scores, model outputs) is computed on the fly from
DuckDB rows — not persisted on the Coach side.
"""

__version__ = "0.1.0"

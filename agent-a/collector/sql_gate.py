"""Read-only SQL gate for the Coach surface (port 1003).

Pilot identity is the only auth. A Coach we trust still shouldn't be able
to run writes, because the Collector is the only writer to the warehouse —
parallel writes from elsewhere break the per-uuid dedupe contract.

Validation strategy: lex enough of the SQL to determine the LEAD STATEMENT
verb, reject anything that isn't read-only, and reject multiple statements.
We do not try to interpret nested CTEs or sub-queries — DuckDB will error on
those if they reference unknown tables; we just guard the verb.
"""

from __future__ import annotations

import re
import time
from typing import Any

from . import __version__ as COLLECTOR_VERSION
from .schema import Query, QueryError, QueryResult
from .trust import TrustPolicy, TrustRejected
from .warehouse import Warehouse


# Statements that read. Everything else is rejected.
READ_VERBS = {"select", "with", "show", "describe", "explain", "pragma", "table", "values"}
# Forbidden tokens anywhere in the query (cheap defense-in-depth against
# SELECT … INTO and DuckDB-specific side-effecting reads).
FORBIDDEN_TOKENS = {
    "insert", "update", "delete", "drop", "create", "alter", "truncate",
    "attach", "detach", "copy", "export", "import", "vacuum", "checkpoint",
    "load", "install", "set",
}

DEFAULT_LIMIT = 1000
MAX_LIMIT = 10_000


def _strip_comments(sql: str) -> str:
    # Remove /* ... */ block comments and -- line comments.
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    sql = re.sub(r"--[^\n]*", " ", sql)
    return sql


def _tokens(sql: str) -> list[str]:
    return re.findall(r"[A-Za-z_][A-Za-z0-9_]*", sql.lower())


class SqlRejected(Exception):
    pass


def gate_sql(sql: str) -> str:
    """Validate `sql` is read-only. Returns the normalized statement.

    Raises SqlRejected on any forbidden verb, semicolon (statement chaining),
    or empty input.
    """
    if not sql or not sql.strip():
        raise SqlRejected("empty sql")
    stripped = _strip_comments(sql).strip().rstrip(";")
    if ";" in stripped:
        raise SqlRejected("multiple statements not allowed")
    tokens = _tokens(stripped)
    if not tokens:
        raise SqlRejected("no statement keyword found")
    first = tokens[0]
    if first not in READ_VERBS:
        raise SqlRejected(f"statement type '{first}' not allowed")
    for forbidden in FORBIDDEN_TOKENS:
        if forbidden in tokens:
            raise SqlRejected(f"forbidden token '{forbidden}'")
    return stripped


def handle_query(
    raw_query: dict,
    *,
    warehouse: Warehouse,
    trust: TrustPolicy,
    coach_identity: str | None = None,
    now: float | None = None,
) -> QueryResult:
    """Execute a Coach query and return a QueryResult."""
    now = time.time() if now is None else now

    try:
        trust.check_coach(coach_identity)
    except TrustRejected as e:
        return QueryResult(
            request_id=str(raw_query.get("request_id", "<missing>")),
            ok=False, ms=0,
            error=QueryError(code="trust_rejected", message=str(e)),
        )

    try:
        q = Query.model_validate(raw_query)
    except Exception as e:
        return QueryResult(
            request_id=str(raw_query.get("request_id", "<missing>")),
            ok=False, ms=0,
            error=QueryError(code="schema_error", message=str(e)),
        )

    try:
        sql = gate_sql(q.sql)
    except SqlRejected as e:
        return QueryResult(
            request_id=q.request_id, ok=False, ms=0,
            error=QueryError(code="sql_rejected", message=str(e)),
        )

    requested = q.limit or DEFAULT_LIMIT
    limit = min(max(1, int(requested)), MAX_LIMIT)
    # Wrap user SQL in `SELECT * FROM (…) LIMIT ?` so we can clamp even when
    # the user didn't write LIMIT themselves. Use a fresh placeholder list.
    wrapped = f"SELECT * FROM ({sql}) AS _q LIMIT {limit + 1}"

    t0 = time.perf_counter()
    try:
        with warehouse.lock():
            cur = warehouse.connection().execute(wrapped, list(q.params))
            rows_raw = cur.fetchall()
            schema = [
                {"name": d[0], "type": str(d[1])} for d in cur.description
            ] if cur.description else []
    except Exception as e:
        return QueryResult(
            request_id=q.request_id, ok=False,
            ms=int((time.perf_counter() - t0) * 1000),
            error=QueryError(code="execution_error", message=str(e)),
        )

    truncated = len(rows_raw) > limit
    if truncated:
        rows_raw = rows_raw[:limit]
    rows = [
        {schema[i]["name"]: _coerce_value(v) for i, v in enumerate(row)}
        for row in rows_raw
    ]
    return QueryResult(
        request_id=q.request_id, ok=True,
        rows=rows, schema=schema, row_count=len(rows),
        ms=int((time.perf_counter() - t0) * 1000),
        truncated=truncated,
    )


def _coerce_value(v: Any) -> Any:
    """Convert DuckDB return values to JSON-safe primitives."""
    import datetime as _dt
    if isinstance(v, (_dt.datetime, _dt.date, _dt.time)):
        return v.isoformat()
    return v

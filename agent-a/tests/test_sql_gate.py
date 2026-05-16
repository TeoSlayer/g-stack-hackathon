"""SQL gate + Coach query surface."""

from __future__ import annotations

import pytest

from collector.ingester import process_envelope
from collector.sql_gate import SqlRejected, gate_sql, handle_query
from tests.helpers import make_envelope, make_quantity_sample


# ─── Gate ────────────────────────────────────────────────────────────────────

class TestGate:
    def test_select_allowed(self):
        assert gate_sql("SELECT 1") == "SELECT 1"

    def test_with_allowed(self):
        sql = "WITH x AS (SELECT 1) SELECT * FROM x"
        assert gate_sql(sql) == sql

    def test_show_allowed(self):
        assert gate_sql("SHOW TABLES") == "SHOW TABLES"

    def test_describe_allowed(self):
        assert gate_sql("DESCRIBE samples") == "DESCRIBE samples"

    @pytest.mark.parametrize("bad", [
        "INSERT INTO samples VALUES (1)",
        "UPDATE samples SET value = 99",
        "DELETE FROM samples",
        "DROP TABLE samples",
        "CREATE TABLE x (a INT)",
        "ALTER TABLE samples ADD COLUMN x INT",
        "TRUNCATE samples",
        "ATTACH 'foo.db' AS x",
        "COPY samples TO 'out.csv'",
        "PRAGMA disable_object_cache; DELETE FROM samples",
    ])
    def test_writes_rejected(self, bad):
        with pytest.raises(SqlRejected):
            gate_sql(bad)

    def test_empty_rejected(self):
        with pytest.raises(SqlRejected):
            gate_sql("")
        with pytest.raises(SqlRejected):
            gate_sql("   ")

    def test_multiple_statements_rejected(self):
        with pytest.raises(SqlRejected):
            gate_sql("SELECT 1; SELECT 2")

    def test_select_with_insert_token_rejected(self):
        # Defense-in-depth: even SELECT ... INTO style or hidden writes are blocked.
        with pytest.raises(SqlRejected):
            gate_sql("SELECT * FROM samples WHERE 1=1 UNION ALL INSERT INTO x VALUES(1)")

    def test_comments_stripped(self):
        result = gate_sql("/* comment */ SELECT 1 -- trailing")
        assert "SELECT 1" in result


# ─── handle_query end-to-end ─────────────────────────────────────────────────

def _seed_warehouse(warehouse, trust):
    samples = [
        make_quantity_sample(uuid_=f"hr{i}", type="heartRate",
                             value=60 + i, start=1000.0 + i, end=1000.0 + i)
        for i in range(5)
    ]
    samples += [
        make_quantity_sample(uuid_=f"hrv{i}", type="heartRateVariabilitySDNN",
                             unit="ms", value=40 + i, start=2000.0 + i, end=2000.0 + i)
        for i in range(3)
    ]
    env = make_envelope(batch_id="b1", samples=samples)
    process_envelope(env, warehouse=warehouse, trust=trust, source_identity="ios")


def test_query_returns_rows(warehouse, trust_open):
    _seed_warehouse(warehouse, trust_open)
    q = {
        "v": 1, "request_id": "r1", "reply_port": 1005,
        "kind": "sql",
        "sql": "SELECT type, value FROM samples WHERE type='heartRate' ORDER BY value",
    }
    result = handle_query(q, warehouse=warehouse, trust=trust_open, coach_identity="coach")
    assert result.ok
    assert result.row_count == 5
    assert result.rows[0]["value"] == 60
    # Schema present
    names = [c["name"] for c in result.schema_]
    assert "type" in names and "value" in names


def test_query_aggregation(warehouse, trust_open):
    _seed_warehouse(warehouse, trust_open)
    q = {
        "v": 1, "request_id": "r2", "reply_port": 1005,
        "kind": "sql",
        "sql": "SELECT type, AVG(value) AS avg_v FROM samples GROUP BY type",
    }
    result = handle_query(q, warehouse=warehouse, trust=trust_open, coach_identity="coach")
    assert result.ok
    by_type = {row["type"]: row["avg_v"] for row in result.rows}
    assert "heartRate" in by_type
    assert by_type["heartRate"] == pytest.approx(62.0)


def test_query_limit_clamped(warehouse, trust_open):
    _seed_warehouse(warehouse, trust_open)
    q = {
        "v": 1, "request_id": "r3", "reply_port": 1005,
        "kind": "sql",
        "sql": "SELECT * FROM samples",
        "limit": 3,
    }
    result = handle_query(q, warehouse=warehouse, trust=trust_open, coach_identity="coach")
    assert result.ok
    assert result.row_count == 3
    assert result.truncated is True


def test_query_rejects_write(warehouse, trust_open):
    q = {
        "v": 1, "request_id": "r4", "reply_port": 1005,
        "kind": "sql",
        "sql": "DROP TABLE samples",
    }
    result = handle_query(q, warehouse=warehouse, trust=trust_open, coach_identity="coach")
    assert not result.ok
    assert result.error.code == "sql_rejected"


def test_query_trust_rejected(warehouse, trust_strict):
    q = {
        "v": 1, "request_id": "r5", "reply_port": 1005,
        "kind": "sql", "sql": "SELECT 1",
    }
    result = handle_query(q, warehouse=warehouse, trust=trust_strict, coach_identity="stranger")
    assert not result.ok
    assert result.error.code == "trust_rejected"


def test_query_executes_with_params(warehouse, trust_open):
    _seed_warehouse(warehouse, trust_open)
    q = {
        "v": 1, "request_id": "r6", "reply_port": 1005,
        "kind": "sql",
        "sql": "SELECT COUNT(*) AS n FROM samples WHERE value >= ?",
        "params": [62],
    }
    result = handle_query(q, warehouse=warehouse, trust=trust_open, coach_identity="coach")
    assert result.ok
    assert result.rows[0]["n"] == 3  # values 62, 63, 64


def test_query_execution_error_returned(warehouse, trust_open):
    q = {
        "v": 1, "request_id": "r7", "reply_port": 1005,
        "kind": "sql",
        "sql": "SELECT * FROM no_such_table",
    }
    result = handle_query(q, warehouse=warehouse, trust=trust_open, coach_identity="coach")
    assert not result.ok
    assert result.error.code == "execution_error"

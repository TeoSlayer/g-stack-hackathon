#!/usr/bin/env bash
# Comprehensive smoke + regression test for pilot-swift SDK.
#
# Tests (in order):
#   1. info        — boot, Info/Health, SMOKE OK
#   2. bob         — PilotBinding trust + send iOS→Linux; optional round-trip Linux→iOS
#   3. persistence — bob with PILOT_DATA_DIR; verify same node_id on second boot
#   4. async-bind  — ensureTrusted() fast-path after persistence test
#   5. (skipped)   — alice/iOS-receive is NOT the production scenario (Linux is receiver)
#   6. throughput  — 20×30KB datagrams to agent-a port 1001; measure msg/s
#
# Env (optional):
#   PILOT_SIM_UDID     — override simulator UDID
#   AGENT_A_NODE_ID    — agent-a node_id (default 161006)
#   AGENT_A_ADDR       — agent-a overlay address (default 0:0000.0002.74EE)
#   SKIP_TESTS         — space-separated list of test names to skip

set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT_DIR="$(pwd)"
OUT_BIN="/tmp/pilot-smoke-swift"
PERSIST_DIR="/tmp/pilot-persist-test-$$"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
XCFW="$SWIFT_DIR/Frameworks/Pilot.xcframework"
SIM_SLICE="$XCFW/ios-arm64-simulator"

AGENT_A_NODE_ID="${AGENT_A_NODE_ID:-161006}"
AGENT_A_ADDR="${AGENT_A_ADDR:-0:0000.0002.74EE}"
SKIP_TESTS="${SKIP_TESTS:-}"

# Resolve pilotctl — look in known locations before falling back to PATH.
PILOTCTL=""
for candidate in \
    "$HOME/.pilot/bin/pilotctl" \
    "$(go env GOPATH 2>/dev/null)/bin/pilotctl" \
    "/usr/local/bin/pilotctl" \
    "/opt/homebrew/bin/pilotctl"; do
    if [ -x "$candidate" ]; then PILOTCTL="$candidate"; break; fi
done
if [ -z "$PILOTCTL" ] && command -v pilotctl &>/dev/null; then
    PILOTCTL="$(command -v pilotctl)"
fi
if [ -z "$PILOTCTL" ]; then
    echo "FATAL: pilotctl not found. Set PATH or install to ~/.pilot/bin/" >&2; exit 1
fi
echo "==> pilotctl: $PILOTCTL"

PASS=0
FAIL=0
SKIP=0

UDID="${PILOT_SIM_UDID:-}"
if [ -z "$UDID" ]; then
    UDID="$(xcrun simctl list devices booted 2>/dev/null \
            | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' \
            | head -1)"
fi
if [ -z "$UDID" ]; then
    echo "FATAL: no booted simulator. Boot one: xcrun simctl boot <udid>" >&2
    exit 1
fi
echo "==> Simulator UDID: $UDID"
echo "==> Agent-A: node_id=$AGENT_A_NODE_ID addr=$AGENT_A_ADDR"
echo

# ── helpers ─────────────────────────────────────────────────────────────────

should_skip() { echo " $SKIP_TESTS " | grep -qw "$1"; }

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1: $2"; FAIL=$((FAIL+1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP+1)); }


wait_for_pattern() {
    # wait_for_pattern <file> <pattern> <timeout_sec>
    local file="$1" pat="$2" timeout="$3"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if grep -qE "$pat" "$file" 2>/dev/null; then return 0; fi
        sleep 1
        elapsed=$((elapsed+1))
    done
    return 1
}

extract() {
    # extract <file> <key>  — extracts value from key=value in log
    grep -oE "${1}[^ ]+" "$2" | head -1 | cut -d= -f2-
}

# ── build ────────────────────────────────────────────────────────────────────

echo "==> Building pilot-smoke-swift for ios-arm64-simulator..."
swiftc \
    -target arm64-apple-ios16.0-simulator \
    -sdk "$SDK" \
    -I "$SIM_SLICE/Headers" \
    -Xcc -fmodule-map-file="$SIM_SLICE/Headers/module.modulemap" \
    "$SWIFT_DIR/Sources/Pilot/Pilot.swift" \
    "$SWIFT_DIR/Examples/pilot-smoke-swift/main.swift" \
    "$SIM_SLICE/libPilot.a" \
    -framework Foundation \
    -lresolv \
    -o "$OUT_BIN" 2>&1
echo "  built $OUT_BIN"
echo

# ── TEST 1: info ─────────────────────────────────────────────────────────────

T="info"
if should_skip "$T"; then skip "$T"
else
    echo "==> Test 1: $T"
    LOG="/tmp/smoke-${T}.log"
    xcrun simctl spawn "$UDID" "$OUT_BIN" info >"$LOG" 2>&1 || true
    if grep -q "SMOKE OK" "$LOG"; then
        pass "$T"
        grep -E "INFO_OK|HEALTH_OK|SMOKE" "$LOG" | sed 's/^/    /'
    else
        fail "$T" "SMOKE OK not found"
        cat "$LOG" | sed 's/^/    /'
    fi
    echo
fi

# ── TEST 2: bob (fresh identity) ─────────────────────────────────────────────

T="bob"
if should_skip "$T"; then skip "$T"
else
    echo "==> Test 2: $T (fresh identity, approval orchestration)"
    LOG="/tmp/smoke-bob.log"
    # Run bob in background; we need to capture its node_id to approve
    xcrun simctl spawn "$UDID" "$OUT_BIN" bob "$AGENT_A_NODE_ID" "$AGENT_A_ADDR" \
        >"$LOG" 2>&1 &
    BOB_PID=$!

    # Wait for daemon to register and emit node_id via syslog
    echo "    Waiting for BOB_START..."
    BOB_NODE_ID=""
    for i in $(seq 1 30); do
        LINE="$(log show --predicate 'process == "pilot-smoke-swift"' \
                --last 30s --style compact 2>/dev/null \
                | grep 'daemon registered' | tail -1 || true)"
        if [ -n "$LINE" ]; then
            BOB_NODE_ID="$(echo "$LINE" | grep -oE 'node_id=[0-9]+' | cut -d= -f2 | head -1)"
            [ -n "$BOB_NODE_ID" ] && break
        fi
        # Also try from log file directly
        if grep -qE "BOB_START" "$LOG" 2>/dev/null; then
            BOB_NODE_ID="$(grep -oE 'node_id=[0-9]+' "$LOG" | head -1 | cut -d= -f2)"
            [ -n "$BOB_NODE_ID" ] && break
        fi
        sleep 1
    done

    if [ -z "$BOB_NODE_ID" ]; then
        # Try once more from log file
        BOB_NODE_ID="$(grep -oE 'node_id=[0-9]+' "$LOG" 2>/dev/null | head -1 | cut -d= -f2 || true)"
    fi

    if [ -z "$BOB_NODE_ID" ]; then
        fail "$T" "could not extract bob node_id from logs"
        cat "$LOG" | sed 's/^/    /'
        kill $BOB_PID 2>/dev/null || true
        echo
    else
        echo "    bob node_id=$BOB_NODE_ID"
        # Wait until handshake appears in pilotctl pending
        echo "    Waiting for handshake in pilotctl pending..."
        APPROVED=false
        for i in $(seq 1 60); do
            if "$PILOTCTL" pending 2>/dev/null | grep -q "$BOB_NODE_ID"; then
                echo "    Approving node $BOB_NODE_ID..."
                "$PILOTCTL" approve "$BOB_NODE_ID" 2>/dev/null || true
                APPROVED=true
                break
            fi
            sleep 2
        done
        if ! $APPROVED; then
            echo "    Handshake did not appear in pending within 120s; attempting approval anyway..."
            "$PILOTCTL" approve "$BOB_NODE_ID" 2>/dev/null || true
        fi

        # Wait for SMOKE OK or timeout
        echo "    Waiting for SMOKE OK..."
        wait $BOB_PID || true
        if grep -q "SMOKE OK" "$LOG"; then
            pass "$T (iOS→Linux)"
            grep -E "BOB_TRUST|BOB_READY|BOB_SENT|SMOKE" "$LOG" | sed 's/^/    /'

            # Optional round-trip: Linux→iOS. bob is public after SMOKE OK? No —
            # bob has exited. We note whether the host can see bob in its trust list.
            BOB_ADDR="$(grep -oE 'addr=0:[^ ]+' "$LOG" | head -1 | cut -d= -f2)"
            if [ -n "$BOB_ADDR" ]; then
                echo "    [round-trip check] bob addr=$BOB_ADDR"
                echo "    [round-trip check] Linux trust entry for bob:"
                "$PILOTCTL" trust 2>/dev/null | grep "$BOB_NODE_ID" | sed 's/^/    /' || echo "    (not found — normal for ephemeral run)"
                echo "    [round-trip] NOTE: production round-trip uses persistent identity."
                echo "    [round-trip] To test: run with PILOT_DATA_DIR, then pilotctl send-message <bob_addr>"
            fi
        else
            fail "$T" "SMOKE OK not found"
            cat "$LOG" | sed 's/^/    /'
        fi
        echo
    fi
fi

# ── TEST 3: persistence ───────────────────────────────────────────────────────

T="persistence"
if should_skip "$T"; then skip "$T"
else
    echo "==> Test 3: $T (PILOT_DATA_DIR=$PERSIST_DIR)"
    mkdir -p "$PERSIST_DIR"
    LOG="/tmp/smoke-persist1.log"

    # Run 1: establish persistent identity + trust
    SIMCTL_CHILD_PILOT_DATA_DIR="$PERSIST_DIR" \
    xcrun simctl spawn "$UDID" "$OUT_BIN" bob "$AGENT_A_NODE_ID" "$AGENT_A_ADDR" \
        >"$LOG" 2>&1 &
    P1_PID=$!

    P1_NODE_ID=""
    for i in $(seq 1 30); do
        P1_NODE_ID="$(grep -oE 'node_id=[0-9]+' "$LOG" 2>/dev/null | head -1 | cut -d= -f2 || true)"
        [ -n "$P1_NODE_ID" ] && break
        sleep 1
    done

    if [ -z "$P1_NODE_ID" ]; then
        # fallback: wait for syslog
        for i in $(seq 1 30); do
            LINE="$(log show --predicate 'process == "pilot-smoke-swift"' \
                    --last 30s --style compact 2>/dev/null \
                    | grep 'daemon registered' | tail -1 || true)"
            P1_NODE_ID="$(echo "$LINE" | grep -oE 'node_id=[0-9]+' | cut -d= -f2 | head -1)"
            [ -n "$P1_NODE_ID" ] && break
            sleep 1
        done
    fi

    if [ -z "$P1_NODE_ID" ]; then
        fail "$T" "persist-run1: could not get node_id"
        kill $P1_PID 2>/dev/null || true
    else
        echo "    run1 node_id=$P1_NODE_ID"
        # Approve
        for i in $(seq 1 60); do
            if "$PILOTCTL" pending 2>/dev/null | grep -q "$P1_NODE_ID"; then
                echo "    Approving $P1_NODE_ID..."
                "$PILOTCTL" approve "$P1_NODE_ID" 2>/dev/null || true
                break
            fi
            sleep 2
        done
        wait $P1_PID || true

        if ! grep -q "SMOKE OK" "$LOG"; then
            fail "$T" "persist-run1 did not get SMOKE OK"
            cat "$LOG" | sed 's/^/    /'
        else
            echo "    run1 SMOKE OK, checking persist dir..."
            ls "$PERSIST_DIR" | sed 's/^/    /'

            # Run 2: same PILOT_DATA_DIR → must load same node_id, checkTrust() returns .trusted
            LOG2="/tmp/smoke-persist2.log"
            echo "    Running info with same PILOT_DATA_DIR..."
            SIMCTL_CHILD_PILOT_DATA_DIR="$PERSIST_DIR" \
            xcrun simctl spawn "$UDID" "$OUT_BIN" info \
                >"$LOG2" 2>&1 || true

            P2_NODE_ID="$(grep -oE 'node_id=[0-9]+' "$LOG2" 2>/dev/null | head -1 | cut -d= -f2 || true)"
            echo "    run2 node_id=$P2_NODE_ID"

            if [ "$P1_NODE_ID" = "$P2_NODE_ID" ] && grep -q "SMOKE OK" "$LOG2"; then
                pass "$T (identity persisted: node_id=$P1_NODE_ID)"
            else
                if [ "$P1_NODE_ID" != "$P2_NODE_ID" ]; then
                    fail "$T" "node_id changed: run1=$P1_NODE_ID run2=$P2_NODE_ID"
                else
                    fail "$T" "run2 did not get SMOKE OK"
                    cat "$LOG2" | sed 's/^/    /'
                fi
            fi
        fi
    fi
    echo
fi

# ── TEST 4: async-bind (fast-path, trust already on disk) ───────────────────

T="async-bind"
if should_skip "$T"; then skip "$T"
else
    echo "==> Test 4: $T (fast-path via persisted trust in $PERSIST_DIR)"
    LOG="/tmp/smoke-async-bind.log"

    # Requires persistence test to have run (trust on disk in $PERSIST_DIR).
    if [ ! -f "$PERSIST_DIR/trust.json" ] && [ ! -f "$PERSIST_DIR/identity.json" ]; then
        echo "    WARNING: $PERSIST_DIR has no trust.json/identity.json — skipping fast-path"
        skip "$T (persistence dir empty)"
    else
        SIMCTL_CHILD_PILOT_DATA_DIR="$PERSIST_DIR" \
        xcrun simctl spawn "$UDID" "$OUT_BIN" async-bind "$AGENT_A_NODE_ID" "$AGENT_A_ADDR" \
            >"$LOG" 2>&1 || true

        if grep -q "SMOKE OK" "$LOG"; then
            PRESTATUS="$(grep -oE 'ASYNC_BIND_PRE_STATUS status=[^ ]+' "$LOG" | head -1 | cut -d= -f2-)"
            ISREADY="$(grep -oE 'ASYNC_BIND_READY isReady=[^ ]+' "$LOG" | head -1 | cut -d= -f2)"
            pass "$T (pre_status=$PRESTATUS isReady=$ISREADY)"
            grep -E "ASYNC_BIND|SMOKE" "$LOG" | sed 's/^/    /'
        else
            fail "$T" "SMOKE OK not found"
            cat "$LOG" | sed 's/^/    /'
        fi
    fi
    echo
fi

# ── TEST 5: N/A — iOS is the SENDER, Linux is the receiver ──────────────────
# The alice mode (iOS as receiver) tests the wrong direction for HealthSync.
# Production: iOS sends health envelopes → Linux agent-a (port 1001).
# Reverse telemetry (Linux→iOS) is tested manually via persistent identity:
#   PILOT_DATA_DIR=/tmp/persist bob <id> <addr>   # establish trust
#   pilotctl send-message <bob_addr> --data "ack"  # from host after trust

echo "==> Test 5: (skipped — iOS is sender; Linux (${AGENT_A_NODE_ID}) is receiver)"
skip "alice (not applicable — see bob+throughput for iOS→Linux path)"

# ── TEST 6: throughput ────────────────────────────────────────────────────────

T="throughput"
if should_skip "$T"; then skip "$T"
else
    echo "==> Test 6: $T (20×30KB → agent-a port 1001)"
    LOG="/tmp/smoke-throughput.log"

    # Use persist dir if trust already established, else fresh
    if [ -f "$PERSIST_DIR/trust.json" ]; then
        SIMCTL_CHILD_PILOT_DATA_DIR="$PERSIST_DIR" \
        xcrun simctl spawn "$UDID" "$OUT_BIN" throughput "$AGENT_A_NODE_ID" "$AGENT_A_ADDR" 20 \
            >"$LOG" 2>&1 || true
    else
        xcrun simctl spawn \
            "$UDID" "$OUT_BIN" throughput "$AGENT_A_NODE_ID" "$AGENT_A_ADDR" 20 \
            >"$LOG" 2>&1 &
        THRU_PID=$!

        THRU_NODE_ID=""
        for i in $(seq 1 30); do
            THRU_NODE_ID="$(grep -oE 'node_id=[0-9]+' "$LOG" 2>/dev/null | head -1 | cut -d= -f2 || true)"
            [ -n "$THRU_NODE_ID" ] && break
            sleep 1
        done
        if [ -n "$THRU_NODE_ID" ]; then
            for i in $(seq 1 60); do
                if "$PILOTCTL" pending 2>/dev/null | grep -q "$THRU_NODE_ID"; then
                    "$PILOTCTL" approve "$THRU_NODE_ID" 2>/dev/null || true
                    break
                fi
                sleep 2
            done
        fi
        wait $THRU_PID || true
    fi

    if grep -q "SMOKE OK" "$LOG"; then
        SENT="$(grep -oE 'sent=[0-9]+/[0-9]+' "$LOG" | tail -1)"
        RATE="$(grep -oE 'rate=[0-9.]+ msg/s' "$LOG" | tail -1)"
        MBPS="$(grep -oE 'throughput=[0-9.]+ MB/s' "$LOG" | tail -1)"
        pass "$T ($SENT $RATE $MBPS)"
        grep -E "THROUGHPUT_DONE|sent=|elapsed=|rate=|throughput=" "$LOG" | sed 's/^/    /'
    else
        fail "$T" "SMOKE OK not found"
        cat "$LOG" | sed 's/^/    /'
    fi
    echo
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo "================================================"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "================================================"

[ "$FAIL" -eq 0 ]

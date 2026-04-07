#!/usr/bin/env bash
set -euo pipefail

# remoteIGV — quick start
# Usage: ./run.sh /path/to/your/bam/directory [port]
#        ./run.sh [-i key] user@host:/path/to/bams [port]
#
# SSH options can also be set via REMOTEIGV_SSH_OPTS env var:
#   export REMOTEIGV_SSH_OPTS="-i ~/.ssh/my_key.pem"

# Parse SSH options (flags before the data dir)
SSH_OPTS=()

# Load from env var first
if [[ -n "${REMOTEIGV_SSH_OPTS:-}" ]]; then
    read -ra _env_opts <<< "$REMOTEIGV_SSH_OPTS"
    SSH_OPTS+=("${_env_opts[@]}")
fi

# CLI flags override
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        -i)
            SSH_OPTS+=(-i "$2")
            shift 2
            ;;
        *)
            SSH_OPTS+=("$1")
            shift
            ;;
    esac
done

DATA_DIR="${1:-.}"
PORT="${2:-8080}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── helpers ──────────────────────────────────────────────────────────

open_browser() {
    local url="http://localhost:${PORT}"
    sleep 2  # give server a moment to start
    if command -v open &>/dev/null; then
        open "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    fi
}

# ── remote mode ──────────────────────────────────────────────────────
# Detect user@host:/path syntax and handle everything over SSH

if [[ "$DATA_DIR" == *@*:* ]]; then
    REMOTE_USER_HOST="${DATA_DIR%%:*}"
    REMOTE_PATH="${DATA_DIR#*:}"
    REMOTE_DIR=".remoteIGV"

    echo "=== remoteIGV (remote mode) ==="
    echo ""
    echo "Deploying to ${REMOTE_USER_HOST}..."

    # Build SSH_OPTS array for passing to ssh/scp
    SSH_ARGS=()
    if [[ ${#SSH_OPTS[@]} -gt 0 ]]; then
        SSH_ARGS=("${SSH_OPTS[@]}")
    fi

    # Copy server files to remote
    ssh "${SSH_ARGS[@]}" "$REMOTE_USER_HOST" "mkdir -p ~/${REMOTE_DIR}/templates ~/${REMOTE_DIR}/static"
    scp -q "${SSH_ARGS[@]}" \
        "$SCRIPT_DIR/server.py" \
        "$SCRIPT_DIR/requirements.txt" \
        "$SCRIPT_DIR/run.sh" \
        "${REMOTE_USER_HOST}:~/${REMOTE_DIR}/"
    scp -q "${SSH_ARGS[@]}" \
        "$SCRIPT_DIR/templates/index.html" \
        "${REMOTE_USER_HOST}:~/${REMOTE_DIR}/templates/"

    # Kill any stale server on the same port
    ssh "${SSH_ARGS[@]}" "$REMOTE_USER_HOST" \
        "kill \$(lsof -t -i:${PORT} 2>/dev/null) 2>/dev/null || true"

    # Start SSH tunnel in background
    ssh "${SSH_ARGS[@]}" -N -L "${PORT}:localhost:${PORT}" "$REMOTE_USER_HOST" &
    TUNNEL_PID=$!

    cleanup() {
        echo ""
        echo "Shutting down..."
        # Kill remote server
        ssh "${SSH_ARGS[@]}" "$REMOTE_USER_HOST" \
            "kill \$(lsof -t -i:${PORT} 2>/dev/null) 2>/dev/null || true" 2>/dev/null || true
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    # Open browser in background
    open_browser &

    echo ""
    echo "  Opening http://localhost:${PORT} in your browser"
    echo "  Press Ctrl+C to stop"
    echo ""

    # Run server on remote (blocks until Ctrl+C)
    ssh "${SSH_ARGS[@]}" -t "$REMOTE_USER_HOST" "cd ~/${REMOTE_DIR} && REMOTEIGV_NO_OPEN=1 bash run.sh '${REMOTE_PATH}' ${PORT}"
    exit 0
fi

# ── local mode ───────────────────────────────────────────────────────

echo "=== remoteIGV setup ==="

# create venv and install deps if needed
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -q -r requirements.txt
else
    source .venv/bin/activate
fi

echo ""
echo "Starting remoteIGV on port ${PORT}"
echo "Serving files from: ${DATA_DIR}"
echo ""

# Open browser locally (skip on headless/remote machines)
if [[ -z "${REMOTEIGV_NO_OPEN:-}" ]]; then
    open_browser &
    echo "  Opening http://localhost:${PORT} in your browser"
else
    echo "  Open http://localhost:${PORT} in your browser"
fi
echo ""

python server.py --data-dir "${DATA_DIR}" --port "${PORT}"

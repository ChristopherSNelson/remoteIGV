#!/usr/bin/env bash
set -euo pipefail

# remoteIGV — quick start
# Usage: ./run.sh /path/to/your/bam/directory [port]
#        ./run.sh [-i key] user@host:/path/to/bams [port]

# Parse SSH options (flags before the data dir)
SSH_OPTS=()
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

# ── remote mode ──────────────────────────────────────────────────────
# Detect user@host:/path syntax and handle everything over SSH

if [[ "$DATA_DIR" == *@*:* ]]; then
    REMOTE_USER_HOST="${DATA_DIR%%:*}"
    REMOTE_PATH="${DATA_DIR#*:}"
    REMOTE_DIR=".remoteIGV"

    echo "=== remoteIGV (remote mode) ==="
    echo ""
    echo "Deploying to ${REMOTE_USER_HOST}..."

    # Copy server files to remote
    ssh "${SSH_OPTS[@]}" "$REMOTE_USER_HOST" "mkdir -p ~/${REMOTE_DIR}/templates ~/${REMOTE_DIR}/static"
    scp -q "${SSH_OPTS[@]}" \
        "$SCRIPT_DIR/server.py" \
        "$SCRIPT_DIR/requirements.txt" \
        "$SCRIPT_DIR/run.sh" \
        "${REMOTE_USER_HOST}:~/${REMOTE_DIR}/"
    scp -q "${SSH_OPTS[@]}" \
        "$SCRIPT_DIR/templates/index.html" \
        "${REMOTE_USER_HOST}:~/${REMOTE_DIR}/templates/"

    # Start SSH tunnel in background
    ssh "${SSH_OPTS[@]}" -N -L "${PORT}:localhost:${PORT}" "$REMOTE_USER_HOST" &
    TUNNEL_PID=$!

    cleanup() {
        echo ""
        echo "Shutting down..."
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    echo ""
    echo "  Open http://localhost:${PORT} in your browser"
    echo "  Press Ctrl+C to stop"
    echo ""

    # Run server on remote (blocks until Ctrl+C)
    ssh "${SSH_OPTS[@]}" -t "$REMOTE_USER_HOST" "cd ~/${REMOTE_DIR} && bash run.sh '${REMOTE_PATH}' ${PORT}"
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
echo "  Local:   http://localhost:${PORT}"
echo "  Remote:  http://$(hostname -f 2>/dev/null || hostname):${PORT}"
echo ""

python server.py --data-dir "${DATA_DIR}" --port "${PORT}"

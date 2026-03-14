#!/usr/bin/env bash
set -euo pipefail

# remoteIGV — quick start
# Usage: ./run.sh /path/to/your/bam/directory [port]

DATA_DIR="${1:-.}"
PORT="${2:-8080}"

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

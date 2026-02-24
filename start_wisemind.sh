#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# WiseMind — Start / Stop / Status for all services
#
# Usage:
#   ./start_wisemind.sh          # start all services (nohup)
#   ./start_wisemind.sh stop     # stop all services
#   ./start_wisemind.sh status   # check service status
#   ./start_wisemind.sh logs     # tail all logs
#
# Access:
#   Internal: http://10.72.127.149  (or http://10.146.157.51)
#   External (SSH tunnel from Hyak):
#     ssh -N -L 3000:localhost:3000 -L 5001:localhost:5001 wisemind@10.72.127.149
#   External (SSH tunnel from local):
#     ssh -N -L 3000:localhost:3000 -L 5001:localhost:5001 june0604@klone.hyak.uw.edu
#   Then open: http://localhost:3000
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"
UI_DIR="$SCRIPT_DIR/ui"
LOG_DIR="$SCRIPT_DIR/logs"

BACKEND_PORT=5001
FRONTEND_PORT=3000

export OLLAMA_MODEL="${OLLAMA_MODEL:-alibayram/medgemma:27b}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"

mkdir -p "$LOG_DIR"

# ── Helper: timestamp for log filenames ──
ts() { date '+%Y-%m-%d_%H%M%S'; }
now() { date '+%Y-%m-%d %H:%M:%S'; }

# ── stop ──
do_stop() {
    echo "[$(now)] Stopping WiseMind services..."
    pkill -f "python backend/api_server.py" 2>/dev/null && echo "  Stopped backend" || echo "  Backend not running"
    pkill -f "npm run dev.*$FRONTEND_PORT" 2>/dev/null && echo "  Stopped frontend (npm)" || true
    pkill -f "vite dev.*$FRONTEND_PORT" 2>/dev/null && echo "  Stopped frontend (vite)" || echo "  Frontend not running"
    echo "  Done."
}

# ── status ──
do_status() {
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║             WiseMind — Service Status                ║"
    echo "╚══════════════════════════════════════════════════════╝"

    printf "  %-12s " "MongoDB:"
    pgrep -x mongod > /dev/null && echo "RUNNING (pid $(pgrep -x mongod))" || echo "STOPPED"

    printf "  %-12s " "Ollama:"
    curl -s "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1 && echo "RUNNING" || echo "STOPPED"

    printf "  %-12s " "Backend:"
    if curl -s "http://localhost:$BACKEND_PORT/v1/health" > /dev/null 2>&1; then
        echo "RUNNING (port $BACKEND_PORT, pid $(pgrep -f 'python backend/api_server.py' | head -1))"
    else
        echo "STOPPED"
    fi

    printf "  %-12s " "Frontend:"
    if ss -tlnp 2>/dev/null | grep -q ":$FRONTEND_PORT "; then
        echo "RUNNING (port $FRONTEND_PORT, pid $(pgrep -f 'vite dev' | head -1))"
    else
        echo "STOPPED"
    fi

    echo ""
    echo "  Logs: $LOG_DIR/"
    ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -5 | while read f; do
        echo "    $(basename "$f")  ($(du -h "$f" | cut -f1))"
    done
}

# ── logs ──
do_logs() {
    tail -f "$LOG_DIR"/backend.log "$LOG_DIR"/frontend.log 2>/dev/null
}

# ── start ──
do_start() {
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║           WiseMind — Starting Services               ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Backend API:  http://0.0.0.0:$BACKEND_PORT                 ║"
    echo "║  Frontend UI:  http://0.0.0.0:$FRONTEND_PORT                 ║"
    echo "║  MongoDB:      mongodb://localhost:27017/wisemind    ║"
    echo "║  Ollama Model: $OLLAMA_MODEL"
    echo "║  Logs:         $LOG_DIR/"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    # Activate conda
    source ~/miniconda3/etc/profile.d/conda.sh
    conda activate wisefind

    # ── [1/4] MongoDB ──
    echo "[1/4] Checking MongoDB..."
    if pgrep -x mongod > /dev/null; then
        echo "  Already running"
    else
        echo "  Starting MongoDB..."
        mkdir -p ~/mongodb_data ~/mongodb_log
        ~/mongodb/bin/mongod --dbpath ~/mongodb_data --logpath ~/mongodb_log/mongod.log \
            --fork --bind_ip 127.0.0.1 --port 27017
        echo "  Started"
    fi

    # ── [2/4] Ollama ──
    echo "[2/4] Checking Ollama..."
    if curl -s "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1; then
        echo "  Already running"
    else
        echo "  WARNING: Ollama not running. Start with: ollama serve"
    fi

    # ── [3/4] Backend API ──
    echo "[3/4] Backend API (port $BACKEND_PORT)..."
    if curl -s "http://localhost:$BACKEND_PORT/v1/health" > /dev/null 2>&1; then
        echo "  Already running and healthy — skipping"
    else
        echo "  Starting (log: $LOG_DIR/backend.log)..."
        cd "$BACKEND_DIR"
        nohup python backend/api_server.py --port "$BACKEND_PORT" --preload \
            >> "$LOG_DIR/backend.log" 2>&1 &
        BACKEND_PID=$!
        echo "  PID: $BACKEND_PID"

        echo "  Waiting for backend to be ready..."
        for i in $(seq 1 90); do
            if curl -s "http://localhost:$BACKEND_PORT/v1/health" > /dev/null 2>&1; then
                echo "  Backend is ready!"
                break
            fi
            if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
                echo "  ERROR: Backend died. Check: tail $LOG_DIR/backend.log"
                return 1
            fi
            sleep 2
        done

        if ! curl -s "http://localhost:$BACKEND_PORT/v1/health" > /dev/null 2>&1; then
            echo "  WARNING: Backend not ready yet (still loading embeddings)."
            echo "  Monitor: tail -f $LOG_DIR/backend.log"
        fi
    fi

    # ── [4/4] Frontend UI ──
    echo "[4/4] Frontend UI (port $FRONTEND_PORT)..."
    if ss -tlnp 2>/dev/null | grep -q ":$FRONTEND_PORT "; then
        echo "  Already running — skipping"
    else
        echo "  Starting (log: $LOG_DIR/frontend.log)..."
        cd "$UI_DIR"
        nohup npm run dev -- --port "$FRONTEND_PORT" --host 0.0.0.0 \
            >> "$LOG_DIR/frontend.log" 2>&1 &
        FRONTEND_PID=$!
        echo "  PID: $FRONTEND_PID"

        sleep 3
        if ss -tlnp 2>/dev/null | grep -q ":$FRONTEND_PORT "; then
            echo "  Frontend is ready!"
        else
            echo "  WARNING: Frontend still starting. Check: tail $LOG_DIR/frontend.log"
        fi
    fi

    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  All services launched."
    echo "  View logs:   tail -f $LOG_DIR/backend.log $LOG_DIR/frontend.log"
    echo "  Status:      $SCRIPT_DIR/start_wisemind.sh status"
    echo "  Stop:        $SCRIPT_DIR/start_wisemind.sh stop"
    echo "════════════════════════════════════════════════════════"
}

# ── Main ──
case "${1:-start}" in
    stop)   do_stop   ;;
    status) do_status ;;
    logs)   do_logs   ;;
    start)  do_start  ;;
    *)      echo "Usage: $0 {start|stop|status|logs}"; exit 1 ;;
esac

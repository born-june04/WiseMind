#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# WiseMind — Start / Stop / Status for all services
#
# Usage:
#   ./start_wisemind.sh               # start production services
#   ./start_wisemind.sh dev           # start dev services (port 3001/5002)
#   ./start_wisemind.sh stop          # stop production services
#   ./start_wisemind.sh stop dev      # stop dev services
#   ./start_wisemind.sh status        # check all service status
#   ./start_wisemind.sh logs          # tail production logs
#   ./start_wisemind.sh logs dev      # tail dev logs
#
# Architecture:
#   [Host]   MongoDB (:27017), Ollama (:11434)
#   [Docker] Production Backend (:5001), Dev Backend (:5002)
#   [Host]   Production UI (:3000), Dev UI (:3001)
#
# Access:
#   Production — Internal:  http://10.72.127.149:3000
#   Production — External:  ssh -N -L 3000:localhost:3000 -L 5001:localhost:5001 wisemind@10.72.127.149
#   Dev        — External:  ssh -N -L 3001:localhost:3001 -L 5002:localhost:5002 wisemind@10.72.127.149
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NGC_IMAGE="nvcr.io/nvidia/pytorch:25.12-py3"

# ── Environment (prod vs dev) ──
DEV_MODE=false
if [[ "$1" == "dev" || "$2" == "dev" ]]; then
    DEV_MODE=true
fi

if $DEV_MODE; then
    UI_DIR="/home/wisemind/workspace/june/WiseMind-dev/ui"
    LOG_DIR="/home/wisemind/workspace/june/WiseMind-dev/logs"
    BACKEND_PORT=5002
    FRONTEND_PORT=3001
    CONTAINER_NAME="wisemind-backend-dev"
    WORKSPACE_DIR="/home/wisemind/workspace/june/WiseMind-dev"
    RUN_SCRIPT="run_backend_ngc_dev.sh"
else
    UI_DIR="$SCRIPT_DIR/ui"
    LOG_DIR="$SCRIPT_DIR/logs"
    BACKEND_PORT=5001
    FRONTEND_PORT=3000
    CONTAINER_NAME="wisemind-backend"
    WORKSPACE_DIR="/home/wisemind/workspace/june/WiseMind"
    RUN_SCRIPT="run_backend_ngc.sh"
fi

export OLLAMA_MODEL="${OLLAMA_MODEL:-alibayram/medgemma:27b}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"

mkdir -p "$LOG_DIR"

now() { date '+%Y-%m-%d %H:%M:%S'; }
env_label() { $DEV_MODE && echo "[DEV]" || echo "[PROD]"; }

# ── stop ──
do_stop() {
    echo "[$(now)] $(env_label) Stopping WiseMind services..."

    if docker ps -q -f name="$CONTAINER_NAME" 2>/dev/null | grep -q .; then
        docker stop "$CONTAINER_NAME" && docker rm "$CONTAINER_NAME" && echo "  Stopped backend (Docker: $CONTAINER_NAME)"
    else
        echo "  Backend container ($CONTAINER_NAME) not running"
    fi

    pkill -f "npm run dev.*$FRONTEND_PORT" 2>/dev/null || true
    pkill -f "vite.*$FRONTEND_PORT" 2>/dev/null && echo "  Stopped frontend (port $FRONTEND_PORT)" || echo "  Frontend not running"
    echo "  Done. (MongoDB and Ollama left running)"
}

# ── status ──
do_status() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              WiseMind — Service Status                   ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    printf "  %-16s " "MongoDB:"
    pgrep -x mongod > /dev/null && echo "RUNNING (pid $(pgrep -x mongod))" || echo "STOPPED"

    printf "  %-16s " "Ollama:"
    curl -s "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1 && echo "RUNNING" || echo "STOPPED"

    echo ""
    echo "  ── Production (:5001 / :3000) ──"
    printf "  %-16s " "Backend [prod]:"
    if docker ps -f name="wisemind-backend" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
        HEALTH=$(curl -s -m 3 http://localhost:5001/v1/health 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('RAG:'+str(d.get('rag_loaded','?')))" 2>/dev/null)
        echo "RUNNING (port 5001) $HEALTH"
    else
        echo "STOPPED"
    fi
    printf "  %-16s " "Frontend [prod]:"
    ss -tlnp 2>/dev/null | grep -q ":3000 " && echo "RUNNING (port 3000)" || echo "STOPPED"

    echo ""
    echo "  ── Dev (:5002 / :3001) ──"
    printf "  %-16s " "Backend [dev]:"
    if docker ps -f name="wisemind-backend-dev" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
        HEALTH=$(curl -s -m 3 http://localhost:5002/v1/health 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('RAG:'+str(d.get('rag_loaded','?')))" 2>/dev/null)
        echo "RUNNING (port 5002) $HEALTH"
    else
        echo "STOPPED"
    fi
    printf "  %-16s " "Frontend [dev]:"
    ss -tlnp 2>/dev/null | grep -q ":3001 " && echo "RUNNING (port 3001)" || echo "STOPPED"

    echo ""
    echo "  Logs:  docker logs -f wisemind-backend[-dev]"
    ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -3 | while read f; do
        echo "    $(basename "$f")  ($(du -h "$f" | cut -f1))"
    done
}

# ── logs ──
do_logs() {
    echo "=== $(env_label) Backend (Docker: $CONTAINER_NAME) ==="
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1
    echo ""
    echo "=== $(env_label) Frontend ==="
    tail -20 "$LOG_DIR/frontend.log" 2>/dev/null
    echo ""
    echo "For live logs:  docker logs -f $CONTAINER_NAME"
}

# ── start ──
do_start() {
    $DEV_MODE && ENV_LABEL="DEV  " || ENV_LABEL="PROD "
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       WiseMind [$ENV_LABEL] — Starting Services          ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Backend:  Docker ($CONTAINER_NAME) :$BACKEND_PORT"
    echo "║  Frontend: http://0.0.0.0:$FRONTEND_PORT"
    echo "║  Workspace: $WORKSPACE_DIR"
    echo "║  Ollama:   $OLLAMA_MODEL"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    source ~/miniconda3/etc/profile.d/conda.sh
    conda activate wisefind

    # ── [1/4] MongoDB (shared) ──
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

    # ── [2/4] Ollama (shared) ──
    echo "[2/4] Checking Ollama..."
    if curl -s "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1; then
        echo "  Already running"
    else
        echo "  WARNING: Ollama not running. Start with: ollama serve"
    fi

    # ── [3/4] Backend API (Docker) ──
    echo "[3/4] Backend API (Docker: $CONTAINER_NAME, port $BACKEND_PORT)..."
    if docker ps -f name="$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
        echo "  Already running"
    else
        docker rm -f "$CONTAINER_NAME" 2>/dev/null

        echo "  Starting NGC PyTorch container with GPU..."
        docker run -d --name "$CONTAINER_NAME" \
            --gpus all --network host --ipc=host \
            --ulimit memlock=-1 --ulimit stack=67108864 \
            -e GREENBERG_IMAGES_DIR=/home/wisemind/workspace/june/greenberg_images \
            -e OLLAMA_MODEL=alibayram/medgemma:27b \
            -e PYTHONUNBUFFERED=1 \
            -e WISEMIND_ENV=$( $DEV_MODE && echo dev || echo prod ) \
            -v "$WORKSPACE_DIR":/workspace/WiseMind-dev \
            -v /home/wisemind/workspace/june/WiseMind:/workspace/WiseMind \
            -v /home/wisemind/workspace/june/greenberg_images:/home/wisemind/workspace/june/greenberg_images \
            -v /home/wisemind/.cache/huggingface:/root/.cache/huggingface \
            -w "$WORKSPACE_DIR" \
            "$NGC_IMAGE" \
            bash "$RUN_SCRIPT"

        echo "  Container started. Waiting for backend to load (~2 min)..."
        for i in $(seq 1 90); do
            if curl -s "http://localhost:$BACKEND_PORT/v1/health" > /dev/null 2>&1; then
                echo "  Backend is ready!"
                break
            fi
            if ! docker ps -f name="$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
                echo "  ERROR: Container died. Check: docker logs $CONTAINER_NAME"
                return 1
            fi
            sleep 2
        done

        if ! curl -s "http://localhost:$BACKEND_PORT/v1/health" > /dev/null 2>&1; then
            echo "  WARNING: Backend still loading. Monitor: docker logs -f $CONTAINER_NAME"
        fi
    fi

    # ── [4/4] Frontend UI ──
    echo "[4/4] Frontend UI (port $FRONTEND_PORT)..."
    if ss -tlnp 2>/dev/null | grep -q ":$FRONTEND_PORT "; then
        echo "  Already running — skipping"
    else
        if [ ! -d "$UI_DIR" ]; then
            echo "  WARNING: UI directory not found: $UI_DIR"
            echo "  Skipping frontend start."
        else
            mkdir -p "$LOG_DIR"
            echo "  Starting (log: $LOG_DIR/frontend-$( $DEV_MODE && echo dev || echo prod ).log)..."
            cd "$UI_DIR"
            FRONTEND_LOG="$LOG_DIR/frontend-$( $DEV_MODE && echo dev || echo prod ).log"
            # Point dev UI at dev backend
            $DEV_MODE && export PUBLIC_API_BASE="http://localhost:5002" || true
            nohup npm run dev -- --port "$FRONTEND_PORT" --host 0.0.0.0 \
                >> "$FRONTEND_LOG" 2>&1 &
            echo "  PID: $!"

            sleep 3
            if ss -tlnp 2>/dev/null | grep -q ":$FRONTEND_PORT "; then
                echo "  Frontend is ready!"
            else
                echo "  WARNING: Still starting. Check: tail $FRONTEND_LOG"
            fi
        fi
    fi

    echo ""
    echo "════════════════════════════════════════════════════════"
    $DEV_MODE && echo "  [DEV] Access: ssh -N -L 3001:localhost:3001 -L 5002:localhost:5002 wisemind@10.72.127.149" \
               || echo "  [PROD] Access: http://10.72.127.149:3000 (internal)"
    echo "  Backend logs: docker logs -f $CONTAINER_NAME"
    echo "  Status:       $SCRIPT_DIR/start_wisemind.sh status"
    echo "  Stop:         $SCRIPT_DIR/start_wisemind.sh stop$( $DEV_MODE && echo " dev" || echo "" )"
    echo "════════════════════════════════════════════════════════"
}

# ── Main ──
# Consume "dev" from first arg so subcommands work cleanly
CMD="${1:-start}"
[[ "$CMD" == "dev" ]] && CMD="start"

case "$CMD" in
    stop)   do_stop   ;;
    status) do_status ;;
    logs)   do_logs   ;;
    start)  do_start  ;;
    *)      echo "Usage: $0 {start|dev|stop [dev]|status|logs [dev]}"; exit 1 ;;
esac

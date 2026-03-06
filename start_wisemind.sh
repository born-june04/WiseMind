#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# WiseMind — Start / Stop / Status for all services
#
# Usage:
#   ./start_wisemind.sh          # start all services
#   ./start_wisemind.sh stop     # stop all services
#   ./start_wisemind.sh status   # check service status
#   ./start_wisemind.sh logs     # tail all logs
#
# Architecture:
#   [Host]   MongoDB (:27017), Ollama (:11434), Frontend UI (:3000)
#   [Docker] Backend API (:5001) — NGC PyTorch container with GPU
#
# Access:
#   Internal: http://10.72.127.149:3000
#   External (SSH tunnel):
#     ssh -N -L 3000:localhost:3000 -L 5001:localhost:5001 wisemind@10.72.127.149
#     Then open: http://localhost:3000
# ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"
LOG_DIR="$SCRIPT_DIR/logs"

BACKEND_PORT=5001
FRONTEND_PORT=3000
CONTAINER_NAME="wisemind-backend"
NGC_IMAGE="nvcr.io/nvidia/pytorch:25.12-py3"

# ── Dev config ──
DEV_CONTAINER_NAME="wisemind-backend-dev"
DEV_BACKEND_PORT=5002                          
DEV_FRONTEND_PORT=3001                         
DEV_IMAGE="wisemind-backend-dev:latest"

export OLLAMA_MODEL="${OLLAMA_MODEL:-alibayram/medgemma:27b}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"

mkdir -p "$LOG_DIR"

now() { date '+%Y-%m-%d %H:%M:%S'; }

# ── stop ──
do_stop() {
    echo "[$(now)] Stopping WiseMind services..."

    # Stop Docker backend
    if docker ps -q -f name="$CONTAINER_NAME" 2>/dev/null | grep -q .; then
        docker stop "$CONTAINER_NAME" && echo "  Stopped backend (Docker)"
    else
        echo "  Backend container not running"
    fi

    # Stop frontend
    pkill -f "npm run dev.*$FRONTEND_PORT" 2>/dev/null || true
    pkill -f "vite dev.*$FRONTEND_PORT" 2>/dev/null && echo "  Stopped frontend" || echo "  Frontend not running"
    echo "  Done. (MongoDB and Ollama left running)"
}

# ── status ──
do_status() {
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║             WiseMind — Service Status                ║"
    echo "╚══════════════════════════════════════════════════════╝"

    printf "  %-14s " "MongoDB:"
    pgrep -x mongod > /dev/null && echo "RUNNING (pid $(pgrep -x mongod))" || echo "STOPPED"

    printf "  %-14s " "Ollama:"
    curl -s "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1 && echo "RUNNING" || echo "STOPPED"

    printf "  %-14s " "Backend:"
    if docker ps -f name="$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
        echo "RUNNING (Docker: $CONTAINER_NAME, port $BACKEND_PORT)"
    else
        echo "STOPPED"
    fi

    printf "  %-14s " "Frontend:"
    if ss -tlnp 2>/dev/null | grep -q ":$FRONTEND_PORT "; then
        echo "RUNNING (port $FRONTEND_PORT)"
    else
        echo "STOPPED"
    fi

    echo ""
    echo "  Docker logs:  docker logs -f $CONTAINER_NAME"
    echo "  Service logs: $LOG_DIR/"
    ls -1t "$LOG_DIR"/*.log 2>/dev/null | head -5 | while read f; do
        echo "    $(basename "$f")  ($(du -h "$f" | cut -f1))"
    done
}

# ── logs ──
do_logs() {
    echo "=== Backend (Docker) ==="
    docker logs --tail 20 "$CONTAINER_NAME" 2>&1
    echo ""
    echo "=== Frontend ==="
    tail -20 "$LOG_DIR/frontend.log" 2>/dev/null
    echo ""
    echo "For live logs:  docker logs -f $CONTAINER_NAME"
}

# ── start ──
do_start() {
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║           WiseMind — Starting Services               ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Backend API:  Docker ($CONTAINER_NAME) :$BACKEND_PORT       ║"
    echo "║  Frontend UI:  http://0.0.0.0:$FRONTEND_PORT                 ║"
    echo "║  MongoDB:      mongodb://localhost:27017             ║"
    echo "║  Ollama Model: $OLLAMA_MODEL"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

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

    # ── [3/4] Backend API (Docker) ──
    echo "[3/4] Backend API (Docker container: $CONTAINER_NAME)..."
    if docker ps -f name="$CONTAINER_NAME" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
        echo "  Already running"
    else
        # Remove old container if exists
        docker rm -f "$CONTAINER_NAME" 2>/dev/null

        echo "  Starting NGC PyTorch container with GPU..."
        docker run -d --name "$CONTAINER_NAME" \
            --gpus all --network host --ipc=host \
            --ulimit memlock=-1 --ulimit stack=67108864 \
            -e GREENBERG_IMAGES_DIR=/home/wisemind/workspace/june/greenberg_images \
            -e OLLAMA_MODEL=alibayram/medgemma:27b \
            -e PYTHONUNBUFFERED=1 \
            -v /home/wisemind/workspace/june/WiseMind:/workspace/WiseMind \
            -v /home/wisemind/workspace/june/greenberg_images:/home/wisemind/workspace/june/greenberg_images \
            -v /home/wisemind/.cache/huggingface:/root/.cache/huggingface \
            -w /workspace/WiseMind \
            "$NGC_IMAGE" \
            bash run_backend_ngc.sh

        echo "  Container started. Waiting for backend to load models (~2 min)..."
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
    echo "  Backend logs: docker logs -f $CONTAINER_NAME"
    echo "  Frontend log: tail -f $LOG_DIR/frontend.log"
    echo "  Status:       $SCRIPT_DIR/start_wisemind.sh status"
    echo "  Stop:         $SCRIPT_DIR/start_wisemind.sh stop"
    echo "════════════════════════════════════════════════════════"
}

# ── Shared backend launcher ──
# Extracted from do_start so prod and dev share the same docker run logic.
# Usage: launch_backend <container_name> <port> <image> [extra docker -e flags]

launch_backend() {
    local container_name="$1"
    local port="$2"
    local image="$3"
    local extra_env="${4:-}"   # optional: "-e FOO=bar -e BAZ=qux"

    if docker ps -f name="$container_name" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
        echo "  Already running ($container_name)"
        return 0
    fi

    # Remove a stopped/crashed container with the same name
    docker rm -f "$container_name" 2>/dev/null

    echo "  Launching container: $container_name on port $port..."
    docker run -d --name "$container_name" \
        --gpus all --network host --ipc=host \
        --ulimit memlock=-1 --ulimit stack=67108864 \
        -e GREENBERG_IMAGES_DIR=/home/wisemind/workspace/june/greenberg_images \
        -e OLLAMA_MODEL=alibayram/medgemma:27b \
        -e PYTHONUNBUFFERED=1 \
        -e BACKEND_PORT="$port" \
        $extra_env \
        -v /home/wisemind/workspace/june/WiseMind:/workspace/WiseMind \
        -v /home/wisemind/workspace/june/greenberg_images:/home/wisemind/workspace/june/greenberg_images \
        -v /home/wisemind/.cache/huggingface:/root/.cache/huggingface \
        -w /workspace/WiseMind \
        "$image" \
        bash run_backend_ngc.sh

    # Wait up to 3 min for the health endpoint to respond
    echo "  Waiting for backend to be ready (~2 min)..."
    for i in $(seq 1 90); do
        if curl -s "http://localhost:$port/v1/health" > /dev/null 2>&1; then
            echo "  Backend ready! ($container_name)"
            return 0
        fi
        # Bail early if the container already died
        if ! docker ps -f name="$container_name" --format '{{.Status}}' 2>/dev/null | grep -q Up; then
            echo "  ERROR: Container died. Check: docker logs $container_name"
            return 1
        fi
        sleep 2
    done

    echo "  WARNING: Backend still loading. Monitor: docker logs -f $container_name"
}

# ── start dev (NEW) — mirrors do_start but wires to dev ports/container ──
do_start_dev() {
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         WiseMind — Starting DEV Services             ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  Backend API:  Docker ($DEV_CONTAINER_NAME) :$DEV_BACKEND_PORT  ║"
    echo "║  Frontend UI:  http://0.0.0.0:$DEV_FRONTEND_PORT               ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    source ~/miniconda3/etc/profile.d/conda.sh
    conda activate wisefind

    # MongoDB and Ollama are shared with prod — just verify they're up
    echo "[1/3] Checking shared services (MongoDB + Ollama)..."
    pgrep -x mongod > /dev/null \
        && echo "  MongoDB: OK" \
        || echo "  WARNING: MongoDB not running — start prod first or run mongod manually"
    curl -s "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1 \
        && echo "  Ollama:  OK" \
        || echo "  WARNING: Ollama not running. Start with: ollama serve"

    # Dev backend — extra env flags enable verbose logging / debug mode
    echo "[2/3] Dev Backend (port $DEV_BACKEND_PORT)..."
    launch_backend \
        "$DEV_CONTAINER_NAME" \
        "$DEV_BACKEND_PORT" \
        "$DEV_IMAGE" \
        "-e ENV=development -e DEBUG=1 -e LOG_LEVEL=debug"
        # swap $NGC_IMAGE for $DEV_IMAGE above if using Dockerfile.dev

    # Dev frontend on its own port
    echo "[3/3] Dev Frontend (port $DEV_FRONTEND_PORT)..."
    if ss -tlnp 2>/dev/null | grep -q ":$DEV_FRONTEND_PORT "; then
        echo "  Already running — skipping"
    else
        echo "  Starting (log: $LOG_DIR/frontend-dev.log)..."
        cd "$UI_DIR"
        nohup npm run dev -- --port "$DEV_FRONTEND_PORT" --host 0.0.0.0 \
            >> "$LOG_DIR/frontend-dev.log" 2>&1 &
        echo "  PID: $!"

        sleep 3
        ss -tlnp 2>/dev/null | grep -q ":$DEV_FRONTEND_PORT " \
            && echo "  Frontend ready!" \
            || echo "  WARNING: Still starting. Check: tail $LOG_DIR/frontend-dev.log"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  Dev services launched."
    echo "  Backend logs: docker logs -f $DEV_CONTAINER_NAME"
    echo "  Frontend log: tail -f $LOG_DIR/frontend-dev.log"
    echo "  Status:       $SCRIPT_DIR/start_wisemind.sh status"
    echo "  Stop dev:     $SCRIPT_DIR/start_wisemind.sh stop-dev"
    echo "════════════════════════════════════════════════════════"
}

# ── stop-dev ──
do_stop_dev() {
    echo "[$(now)] Stopping WiseMind DEV services..."

    if docker ps -q -f name="$DEV_CONTAINER_NAME" 2>/dev/null | grep -q .; then
        docker stop "$DEV_CONTAINER_NAME" && echo "  Stopped dev backend ($DEV_CONTAINER_NAME)"
    else
        echo "  Dev backend container not running"
    fi

    pkill -f "npm run dev.*$DEV_FRONTEND_PORT" 2>/dev/null || true
    pkill -f "vite dev.*$DEV_FRONTEND_PORT" 2>/dev/null && echo "  Stopped dev frontend" || echo "  Dev frontend not running"
    echo "  Done."
}

# ── Main (updated with dev and stop-dev commands) ──
case "${1:-start}" in
    stop)     do_stop      ;;
    stop-dev) do_stop_dev  ;;   # NEW: tears down only dev stack
    status)   do_status    ;;
    logs)     do_logs      ;;
    start)    do_start     ;;
    dev)      do_start_dev ;;   # NEW: spins up dev stack on :5002/:3001
    *)        echo "Usage: $0 {start|stop|stop-dev|status|logs|dev}"; exit 1 ;;
esac

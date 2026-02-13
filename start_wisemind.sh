#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# WiseMind — Start both Backend API + UI on wisemind server
# 
# Usage:  ./start_wisemind.sh
#   (run on wisemind server, then port-forward from Hyak/local)
#
# Port Forwarding (from Hyak):
#   ssh -N -L 3000:localhost:3000 -L 5001:localhost:5001 wisemind@10.72.127.149
#
# Port Forwarding (from local):
#   ssh -N -L 3000:localhost:3000 -L 5001:localhost:5001 june0604@klone-login01.hyak.uw.edu
#
# Then open: http://localhost:3000
# ──────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"
UI_DIR="$SCRIPT_DIR/ui"

# Ollama model (override with: OLLAMA_MODEL=xxx ./start_wisemind.sh)
export OLLAMA_MODEL="${OLLAMA_MODEL:-alibayram/medgemma:27b}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"

# Activate conda
source ~/miniconda3/etc/profile.d/conda.sh
conda activate wisefind

echo "╔══════════════════════════════════════════════════════╗"
echo "║           WiseMind — Starting Services               ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Backend API:  http://localhost:5001                 ║"
echo "║  Frontend UI:  http://localhost:3000                 ║"
echo "║  MongoDB:      mongodb://localhost:27017/wisemind    ║"
echo "║  Ollama Model: $OLLAMA_MODEL"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Start MongoDB (if not already running) ──
echo "🗄️  Checking MongoDB..."
if pgrep -x mongod > /dev/null; then
    echo "✅ MongoDB already running"
else
    echo "   Starting MongoDB..."
    mkdir -p ~/mongodb_data ~/mongodb_log
    ~/mongodb/bin/mongod --dbpath ~/mongodb_data --logpath ~/mongodb_log/mongod.log \
        --fork --bind_ip 127.0.0.1 --port 27017
    echo "✅ MongoDB started"
fi

# ── Check Ollama ──
echo "🔍 Checking Ollama..."
if curl -s "$OLLAMA_BASE_URL/api/tags" > /dev/null 2>&1; then
    echo "✅ Ollama is running"
else
    echo "❌ Ollama not running! Start with: ollama serve"
    exit 1
fi

# ── Start Backend API (background) ──
echo ""
echo "🚀 Starting Backend API on port 5001..."
cd "$BACKEND_DIR"
python backend/api_server.py --port 5001 --preload &
BACKEND_PID=$!
echo "   Backend PID: $BACKEND_PID"

# Wait for backend to start
echo "   Waiting for backend to be ready..."
for i in $(seq 1 60); do
    if curl -s http://localhost:5001/v1/health > /dev/null 2>&1; then
        echo "   ✅ Backend is ready!"
        break
    fi
    sleep 2
done

# ── Start UI (foreground) ──
echo ""
echo "🎨 Starting UI on port 3000..."
cd "$UI_DIR"
npm run dev -- --port 3000 --host 0.0.0.0

# Cleanup on exit
trap "echo 'Shutting down...'; kill $BACKEND_PID 2>/dev/null; exit" INT TERM
wait

#!/bin/bash
# ── Developer-only backend (port 5002, WiseMind-dev branch) ──
export PYTHONUNBUFFERED=1
export GREENBERG_IMAGES_DIR=/home/wisemind/workspace/june/greenberg_images
export OLLAMA_MODEL=alibayram/medgemma:27b
export WISEMIND_ENV=dev

# Install dependencies
pip install flask sentence-transformers open_clip_torch faiss-cpu requests rank-bm25 pymongo gunicorn gevent 2>&1 | tail -5

cd /workspace/WiseMind-dev

# Pre-load RAG models once before workers fork
python backend/backend/api_server.py --preload-only 2>&1

# Start Gunicorn on port 5002 (dev — fewer workers to save resources)
exec gunicorn \
    --bind 0.0.0.0:5002 \
    --workers 2 \
    --worker-class gevent \
    --worker-connections 50 \
    --timeout 600 \
    --keep-alive 5 \
    --backlog 32 \
    --log-level debug \
    --access-logfile - \
    --error-logfile - \
    "backend.backend.api_server:app"

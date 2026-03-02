#!/bin/bash
export PYTHONUNBUFFERED=1
export GREENBERG_IMAGES_DIR=/home/wisemind/workspace/june/greenberg_images
export OLLAMA_MODEL=alibayram/medgemma:27b

# Install dependencies
pip install flask sentence-transformers open_clip_torch faiss-cpu requests rank-bm25 pymongo gunicorn gevent 2>&1 | tail -5

cd /workspace/WiseMind

# Pre-load RAG models once before workers fork (so each worker shares loaded models via CoW)
python backend/backend/api_server.py --preload-only 2>&1

# Start Gunicorn with gevent workers
# Workers: 4 (enough for concurrent users without overloading the single Ollama LLM)
# Worker class: gevent (async I/O — handles streaming responses and long Ollama calls efficiently)
# Timeout: 600s (Thinking mode can take up to ~3 min; add buffer)
# Backlog: 64 (queue depth for incoming connections)
exec gunicorn \
    --bind 0.0.0.0:5001 \
    --workers 4 \
    --worker-class gevent \
    --worker-connections 100 \
    --timeout 600 \
    --keep-alive 5 \
    --backlog 64 \
    --log-level info \
    --access-logfile - \
    --error-logfile - \
    "backend.backend.api_server:app"

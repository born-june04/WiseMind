#!/bin/bash
export PYTHONUNBUFFERED=1
export GREENBERG_IMAGES_DIR=/home/wisemind/workspace/june/greenberg_images
export OLLAMA_MODEL=alibayram/medgemma:27b
pip install flask sentence-transformers open_clip_torch faiss-cpu requests rank-bm25 pymongo 2>&1 | tail -5
cd /workspace/WiseMind
exec python backend/backend/api_server.py --port 5001 --preload

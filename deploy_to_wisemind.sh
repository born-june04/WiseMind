#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════
# WiseFind RAG → wisemind 서버 배포 스크립트
#
# 이 스크립트가 하는 일:
#   1. backend/ submodule의 코드 변경을 git push
#   2. heavy 파일 (모델, 데이터, 이미지)을 scp로 전송
#   3. wisemind 서버에서 git pull + 환경 설정
#
# 사용법:
#   chmod +x deploy_to_wisemind.sh
#   ./deploy_to_wisemind.sh
# ══════════════════════════════════════════════════════════════
set -e

WISEMIND_HOST="wisemind@10.72.127.149"
REMOTE_BASE="/home/wisemind/workspace/june/WiseMind"
LOCAL_BASE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BACKEND="$LOCAL_BASE/backend"
LOCAL_SHARED="$LOCAL_BACKEND/workspace/_shared"
LOCAL_IMAGES="/gscratch/scrubbed/june0604/tbi/DeepSeek-OCR/outputs/images"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  WiseFind RAG → wisemind 서버 배포                       ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Source: $LOCAL_BASE"
echo "║  Target: $WISEMIND_HOST:$REMOTE_BASE"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Git push (backend submodule) ───
echo "═══ Step 1/4: Git push (backend submodule code) ═══"
cd "$LOCAL_BACKEND"
echo "  Current dir: $(pwd)"
echo "  Git status:"
git status --short
echo ""
echo "  Adding and committing changes..."
git add -A
git commit -m "feat: switch api_server to WiseFind LateInteractionMultimodalRAG

- Replace NeurosurgeryRAG (text-only) with LateInteractionMultimodalRAG
- Add multimodal search: text + image results from 3-channel shotgun
- Update paths for shared data directory structure
- Add WiseFind image results to API response media" || echo "  (nothing to commit)"
echo "  Pushing..."
git push origin main || git push origin master || echo "  ⚠️ Push failed — you may need to push manually"
echo ""

# Also update parent repo submodule pointer
cd "$LOCAL_BASE"
git add backend
git commit -m "chore: update backend submodule (WiseFind integration)" || echo "  (nothing to commit)"
git push origin main || git push origin master || echo "  ⚠️ Parent push failed"
echo "✅ Git push complete"
echo ""

# ─── Step 2: Transfer heavy data files ───
echo "═══ Step 2/4: Transfer heavy data files ═══"

# Create target directories on wisemind
echo "  Creating directories on wisemind..."
ssh "$WISEMIND_HOST" "mkdir -p $REMOTE_BASE/backend/workspace/_shared/{data,images,models}"

# 2a. Greenberg chunks (24MB)
echo "  [1/5] greenberg_handbook_chunked.json (24MB)..."
rsync -avz --progress \
    "$LOCAL_SHARED/data/greenberg_handbook_chunked.json" \
    "$WISEMIND_HOST:$REMOTE_BASE/backend/workspace/_shared/data/"

# 2b. Image metadata + embeddings
echo "  [2/5] image_metadata.json + embeddings..."
rsync -avz --progress \
    "$LOCAL_SHARED/images/" \
    "$WISEMIND_HOST:$REMOTE_BASE/backend/workspace/_shared/images/"

# 2c. ColBERT checkpoint
echo "  [3/5] colbert-30000 checkpoint..."
rsync -avz --progress \
    "$LOCAL_SHARED/models/colbert-30000/" \
    "$WISEMIND_HOST:$REMOTE_BASE/backend/workspace/_shared/models/colbert-30000/"

# 2d. BiomedCLIP model
echo "  [4/5] biomedclip-greenberg model..."
rsync -avz --progress \
    "$LOCAL_SHARED/models/biomedclip-greenberg/" \
    "$WISEMIND_HOST:$REMOTE_BASE/backend/workspace/_shared/models/biomedclip-greenberg/"

# 2e. cmli_encoder.pt (cross-modal encoder)
echo "  [5/5] cmli_encoder.pt..."
rsync -avz --progress \
    "$LOCAL_SHARED/models/cmli_encoder.pt" \
    "$WISEMIND_HOST:$REMOTE_BASE/backend/workspace/_shared/models/"

echo "✅ Data files transferred"
echo ""

# ─── Step 3: Transfer Greenberg images ───
echo "═══ Step 3/4: Transfer Greenberg images (406 files) ═══"
if [ -d "$LOCAL_IMAGES" ]; then
    # Create image directory on wisemind
    ssh "$WISEMIND_HOST" "mkdir -p ~/workspace/june/greenberg_images"
    
    echo "  Syncing images from $LOCAL_IMAGES..."
    rsync -avz --progress \
        "$LOCAL_IMAGES/" \
        "$WISEMIND_HOST:~/workspace/june/greenberg_images/"
    echo "✅ Images transferred"
else
    echo "  ⚠️ Image directory not found: $LOCAL_IMAGES"
    echo "  You'll need to transfer images manually"
fi
echo ""

# ─── Step 4: Pull code & setup on wisemind ───
echo "═══ Step 4/4: Pull code & verify on wisemind ═══"
ssh "$WISEMIND_HOST" bash -s <<'REMOTE_SCRIPT'
set -e
cd /home/wisemind/workspace/june/WiseMind

echo "  Pulling latest code..."
git pull origin main || git pull origin master || echo "  git pull failed"
git submodule update --init --recursive

echo ""
echo "  Verifying files..."
echo "  === Data ==="
ls -lh backend/workspace/_shared/data/greenberg_handbook_chunked.json 2>/dev/null || echo "  ❌ MISSING: greenberg_handbook_chunked.json"
echo "  === Images ==="
ls -lh backend/workspace/_shared/images/image_metadata.json 2>/dev/null || echo "  ❌ MISSING: image_metadata.json"
ls -lh backend/workspace/_shared/images/image_embeddings_finetuned.npy 2>/dev/null || echo "  ⚠️ MISSING: image_embeddings_finetuned.npy (optional)"
echo "  === Models ==="
ls -d backend/workspace/_shared/models/colbert-30000/ 2>/dev/null && echo "  ✅ colbert-30000 exists" || echo "  ❌ MISSING: colbert-30000"
ls -d backend/workspace/_shared/models/biomedclip-greenberg/ 2>/dev/null && echo "  ✅ biomedclip-greenberg exists" || echo "  ❌ MISSING: biomedclip-greenberg"
echo "  === Greenberg Images ==="
IMAGE_COUNT=$(ls ~/workspace/june/greenberg_images/*.jpg 2>/dev/null | wc -l)
echo "  Found $IMAGE_COUNT images in ~/workspace/june/greenberg_images/"
echo ""
echo "  === API Server ==="
head -5 backend/backend/api_server.py
grep -n "LateInteractionMultimodalRAG\|NeurosurgeryRAG" backend/backend/api_server.py || true

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ Deployment Verification Complete                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  To start WiseMind with WiseFind:                       ║"
echo "║    ./start_wisemind.sh                                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
REMOTE_SCRIPT

echo ""
echo "🎉 배포 완료! wisemind 서버에서 ./start_wisemind.sh 로 시작하세요"

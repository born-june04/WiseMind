# WiseMind

**Medical AI Assistant — RAG-Powered Neurosurgery Q&A**

WiseMind combines a document-structure-aware RAG backend with a modern chat UI to deliver traceable, evidence-based answers from Greenberg's Handbook of Neurosurgery.

---

## Architecture

```
┌──────────────┐       API       ┌──────────────────────────┐
│   WiseMind   │ ◄────────────►  │       wisefind           │
│     UI       │   (REST/WS)     │  (RAG + MedGemma LLM)    │
│  (Next.js)   │                 │                          │
└──────────────┘                 │  ┌─────────────────────┐ │
                                 │  │ NeurosurgeryRAG     │ │
                                 │  │  • BM25 + Dense     │ │
                                 │  │  • ColBERT (21K ch) │ │
                                 │  └────────┬────────────┘ │
                                 │           │              │
                                 │  ┌────────▼────────────┐ │
                                 │  │ MedGemma-4b-it      │ │
                                 │  │  (HuggingFace)      │ │
                                 │  └─────────────────────┘ │
                                 └──────────────────────────┘
```

## Repository Structure

This is a **parent mono-repo** with two submodules:

| Directory | Repository | Description |
|-----------|------------|-------------|
| `backend/` | [wisefind](https://github.com/born-june04/wisefind) | RAG retrieval + MedGemma LLM generation |
| `ui/` | [WiseMind-UI](https://github.com/nguyenmx/WiseMind-UI) | Next.js chat interface |

Each submodule is versioned independently.

## Quick Start

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/born-june04/WiseMind.git
cd WiseMind

# If already cloned without submodules:
git submodule update --init --recursive
```

### Backend (GPU node)
```bash
conda activate medgemma
cd backend
python backend/run_integration_test.py
```

### UI
```bash
cd ui
npm install
npm run dev
```

## Tech Stack

| Component | Technology |
|-----------|------------|
| **LLM** | `google/medgemma-4b-it` (Medical Gemma, instruction-tuned) |
| **Retrieval** | 3-stage ColBERT (BM25 → Dense → Late Interaction) |
| **Corpus** | Greenberg's Handbook of Neurosurgery (21,429 chunks) |
| **Frontend** | Next.js / React |
| **Inference** | HuggingFace Transformers (bfloat16, multi-GPU) |
| **Hardware** | 2× NVIDIA L40S (46GB each) |


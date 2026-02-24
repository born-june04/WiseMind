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

## Deployment

### Service Management

```bash
./start_wisemind.sh          # Start all services (nohup, backgrounded)
./start_wisemind.sh stop     # Stop all services
./start_wisemind.sh status   # Check service status
./start_wisemind.sh logs     # Tail all logs live
```

All logs are written to the `logs/` directory (`backend.log`, `frontend.log`).

### Internal Network Access

Users on the same network can access WiseMind directly in a browser:

```
http://10.72.127.149    (WiFi)
http://10.146.157.51    (Wired)
```

### External Network Access (SSH Tunnel via Hyak)

External users need a two-hop SSH tunnel through Hyak:

```bash
# Step 1 — on Hyak (run in background):
ssh -N -L 80:localhost:80 wisemind@10.72.127.149

# Step 2 — on your local machine:
ssh -N -L 9090:localhost:80 <netid>@klone.hyak.uw.edu

# Step 3 — open in browser:
http://localhost:9090
```

> **Note:** The local port (left side of `-L`) can be any unused port on your machine.
> If `9090` is taken, try `7777`, `4000`, etc.

Available server ports for tunneling:

| Port | Service |
|------|---------|
| `80` | WiseMind Full (Frontend + API via nginx) |
| `3000` | Frontend UI (direct) |
| `5001` | Backend API (direct) |
| `9001` | WiseMind Full (alt port) |
| `9002` | Backend API only |
| `9003` | Ollama LLM API |
| `9005` | Jupyter Lab |

## Tech Stack

| Component | Technology |
|-----------|------------|
| **LLM** | MedGemma 27B (via Ollama) |
| **Retrieval** | 3-stage ColBERT (BM25 → Dense → Late Interaction) |
| **Corpus** | Greenberg's Handbook of Neurosurgery (21,429 chunks) |
| **Frontend** | SvelteKit (chat-ui) |
| **Inference** | Ollama (CPU/GPU) |
| **Reverse Proxy** | nginx |


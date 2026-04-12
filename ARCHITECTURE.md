# WiseMind System Architecture

> Generated: 2026-04-12 | Version: v1.7.0

---

## 1. Overall System Architecture

```mermaid
flowchart TB
    subgraph USER["👤 User"]
        B["Browser\nhttp://10.72.127.149:3000"]
    end

    subgraph FRONTEND["🖥️ Frontend  (SvelteKit / Vite · port 3000)"]
        direction TB
        UI_CHAT["Chat UI\n(marked.ts rendering)"]
        UI_SRC["Source Panel\nPDF Viewer + Highlight"]
        UI_REF["Reference Buttons\n[Greenberg, p.XXXX]"]
        UI_CHAT --> UI_REF --> UI_SRC
    end

    subgraph BACKEND["⚙️ Backend  (Flask / Gunicorn · port 5001)"]
        direction TB
        EP_GEN["POST /v1/generate\n(Flash / Thinking mode)"]
        EP_SRC["GET /v1/source-page/[page]\nbbox + highlight"]
        EP_IMG["GET /v1/source-page-img/[page]\nbook_page.jpg"]
        EP_CDE["GET /v1/cde/search\nNINDS-CDE lookup"]
        EP_MET["GET /v1/admin/metrics\nSQLite monitoring"]
    end

    subgraph PIPELINE["🔄 Generation Pipeline"]
        direction TB
        CACHE{"Semantic Cache\nFAISS cosine ≥ 0.92"}
        EXPAND["Query Expansion\n① Ontology terms\n② CDE graph variables\n③ Multi-turn entities"]
        TOPIC["Topic Classifier\ngreenberg_chapter_map.json\n→ page_index filter"]
        RAG_BASE["Greenberg RAG\nColBERT (text + image)\n~18,000 chunks"]
        RAG_MID["Middle Layer\nBTF Guidelines\nFAISS"]
        CDE_INJ["CDE Context Injection\n[NINDS CDE Reference]\nStandardized definitions"]
        DEF_INJ["Medical Terms\n1,730 definitions\nInjected into prompt"]
        LLM["Ollama · MedGemma 27B\nFlash: single-step\nThinking: Draft→Review→Refine"]
        FAITH["NLI Faithfulness\ndeberta-v3-small\nEntailment score"]
        GUARD["Hallucination Guard\nNo results → block generation\n< 45% → warning badge"]
        LOG["SQLite query_logs\ntopic / faithfulness /\nconfidence / latency"]

        CACHE -->|miss| EXPAND
        EXPAND --> TOPIC
        TOPIC --> RAG_BASE
        TOPIC --> RAG_MID
        RAG_BASE --> CDE_INJ
        RAG_MID --> CDE_INJ
        CDE_INJ --> DEF_INJ
        DEF_INJ --> LLM
        LLM --> FAITH
        FAITH --> GUARD
        GUARD --> LOG
        LOG -->|store high-quality| CACHE
    end

    subgraph DATA["🗄️ Data Layer"]
        direction LR
        GB_CHUNKS["greenberg_handbook_chunked.json\n~18,000 chunks\npage_index + section_title"]
        GB_IMGS["greenberg_pages/\nbook_page.jpg\n(1067.jpg, 1071.jpg ...)"]
        GB_TEXT["greenberg_text_index.json\nbounding boxes per page"]
        CH_MAP["greenberg_chapter_map.json\n10 topics × page ranges"]
        CDE_GRAPH["NINDS-CDE Graph\ncde_graph.pkl  9.7 MB\ncde_faiss.index 3.8 MB\n2,556 CDEs (TBI + SCI)"]
        MONGO["MongoDB\nConversations\nSessions"]
        SQLITE["wisemind_monitor.db\nquery_logs"]
    end

    subgraph INFRA["🏗️ Infrastructure"]
        OLLAMA["Ollama  port 11434\nalibayram/medgemma:27b"]
        DOCKER["Docker\nwisemind-backend\n--runtime=nvidia --gpus all"]
        GPU["NVIDIA GB10\n(DGX Spark, ARM)"]
    end

    B <-->|HTTP| FRONTEND
    FRONTEND <-->|REST / SSE| BACKEND
    EP_GEN <--> PIPELINE
    EP_SRC --> GB_TEXT
    EP_SRC --> GB_IMGS
    EP_CDE --> CDE_GRAPH
    EP_MET --> SQLITE
    PIPELINE --> DATA
    LLM --> OLLAMA
    OLLAMA --> GPU
    BACKEND --> DOCKER
    MONGO <--> FRONTEND
```

---

## 2. Query Processing Flow (Sequence Diagram)

```mermaid
sequenceDiagram
    actor User
    participant FE as Frontend (port 3000)
    participant BE as Backend (port 5001)
    participant CACHE as Semantic Cache
    participant RAG as Greenberg RAG
    participant CDE as NINDS-CDE Graph
    participant LLM as Ollama / MedGemma

    User->>FE: Submit question
    FE->>BE: POST /v1/generate (stream=true)

    BE->>CACHE: Lookup similar query (cosine ≥ 0.92)
    alt Cache HIT
        CACHE-->>FE: ⚡ Return cached response instantly
    else Cache MISS
        BE->>BE: Classify topic → set page_index filter
        BE->>CDE: Expand query with NINDS variable names
        BE->>RAG: Greenberg search (ColBERT + page filter)
        RAG-->>BE: Relevant chunks + figures
        BE->>CDE: Inject CDE definition snippet
        BE->>LLM: Prompt (context + definitions + question)
        LLM-->>FE: Streaming tokens
        BE->>BE: Compute NLI faithfulness score
        BE->>BE: Log to SQLite (topic, scores, latency)
        BE->>CACHE: Store high-quality response
    end

    FE->>User: Answer + [Greenberg, p.XXXX] button

    opt User clicks reference button
        User->>FE: Click reference button
        FE->>BE: GET /v1/source-page/[page]?search=...
        BE-->>FE: Page image URL + highlight bboxes
        FE->>User: Right panel: PDF page with highlighted passage
    end
```

---

## 3. Data Layer Schema

```mermaid
erDiagram
    GREENBERG_CHUNKS {
        string chunk_id
        int page_index
        string section_title
        string content
        float score
    }
    GREENBERG_PAGES {
        string filename "e.g. 1071.jpg"
        int book_page_num
        list bboxes "normalized [x0,y0,x1,y1]"
    }
    CDE_GRAPH_NODE {
        string node_id "CDE::TBI::C12345"
        string cde_id
        string name
        string variable
        string definition
        string domain
        string subdomain
        string disease "TBI or SCI"
        string snomed
        string loinc
        vector embedding "384-dim all-MiniLM-L6-v2"
    }
    CHAPTER_MAP {
        string topic "e.g. traumatic_brain_injury"
        int page_range_lo
        int page_range_hi
        list keywords
    }
    QUERY_LOGS {
        int id
        string query
        string topic
        float faithfulness
        float confidence
        float avg_retrieval_score
        int response_time_ms
        bool cache_hit
        string thinking_mode "flash or thinking"
    }

    GREENBERG_CHUNKS ||--|| GREENBERG_PAGES : "page_index maps to book_page"
    CDE_GRAPH_NODE }o--|| CHAPTER_MAP : "domain aligns with topic"
    QUERY_LOGS }o--o| CHAPTER_MAP : "classified topic logged"
```

---

## 4. NINDS-CDE Knowledge Graph Structure

```mermaid
graph TD
    ROOT_TBI["Disease: TBI"]
    ROOT_SCI["Disease: SCI"]

    DOM1["Domain: Outcomes and End Points"]
    DOM2["Domain: Assessments and Examinations"]
    DOM3["Domain: Disease/Injury Related Events"]
    DOM4["Domain: International SCI Data Sets"]

    SUB1["Subdomain: Neuropsychological Impairment"]
    SUB2["Subdomain: Post-concussive / TBI Symptoms"]
    SUB3["Subdomain: Imaging Diagnostics"]
    SUB4["Subdomain: Neurological Outcomes"]

    CDE1["CDE: Intracranial Pressure\n(var: ICPMeanDailyMeasure)"]
    CDE2["CDE: Glasgow Coma Scale\n(var: GCSDateAndTime)"]
    CDE3["CDE: ASIA Impairment Scale\n(var: ASIAImprmntScale)"]
    CDE4["CDE: Functional Outcome\n(var: TherpyRehabOngngInd)"]

    SN1["SNOMED: 271782001"]
    SN2["SNOMED: 248241002"]

    SHARED["137 Shared CDEs\n(TBI ↔ SCI)"]

    ROOT_TBI --> DOM1 & DOM2 & DOM3
    ROOT_SCI --> DOM4 & DOM2
    DOM1 --> SUB1 & SUB2
    DOM2 --> SUB3
    DOM4 --> SUB4
    SUB1 --> CDE2
    SUB2 --> CDE1
    SUB3 --> CDE3
    SUB4 --> CDE4
    CDE1 --> SN1
    CDE2 --> SN2
    ROOT_TBI -. "shared CDE" .-> SHARED
    ROOT_SCI -. "shared CDE" .-> SHARED
```

---

## 5. Feature Roadmap by Version

```mermaid
timeline
    title WiseMind Feature Roadmap
    section Foundation
        v1.3 : Greenberg ColBERT RAG
             : Medical terms dictionary (1,730)
             : Middle layer — BTF Guidelines
             : Evidence conflict expression
    section UI & Accuracy
        v1.4 : Reference buttons (RAG-conditional)
             : PDF Source Panel (right side)
             : Highlight bounding boxes
        v1.5 : book_page.jpg filename mapping
             : Content-based page finder
             : Exact-match highlight logic
    section Quality Pipeline
        v1.6.0 : Topic-based page filter
               : greenberg_chapter_map.json
        v1.6.2 : Semantic cache (FAISS, cosine 0.92)
        v1.6.3 : NLI faithfulness scoring
               : SQLite monitoring DB
        v1.6.4 : Hallucination guard
        v1.6.5 : Multi-turn query understanding
    section Ontology
        v1.7 : NINDS-CDE knowledge graph
             : 2556 CDEs (TBI + SCI)
             : Query expansion + definition injection
             : /v1/cde/search API
```

---

## 6. API Endpoints Reference

| Endpoint | Method | Description |
|---|---|---|
| `/v1/generate` | POST | Main chat generation (Flash / Thinking, streaming SSE) |
| `/v1/health` | GET | Service health check |
| `/v1/source-page/[page]` | GET | Greenberg page image URL + highlight bboxes |
| `/v1/source-page-img/[page]` | GET | Serve book page JPEG directly |
| `/v1/cde/search?q=&k=` | GET | Semantic search over NINDS-CDE graph |
| `/v1/admin/metrics?days=` | GET | Aggregated query stats from SQLite |

---

## 7. Infrastructure Summary

| Component | Technology | Host | Notes |
|---|---|---|---|
| Frontend | SvelteKit + Vite | port 3000 | `nohup npm run dev` |
| Backend | Flask + Gunicorn (4 workers, gevent) | port 5001 | Docker `wisemind-backend` |
| LLM Serving | Ollama | port 11434 | `systemctl ollama` |
| GPU | NVIDIA GB10 (DGX Spark, ARM) | host | `--runtime=nvidia --gpus all` |
| Database | MongoDB | localhost | Conversations + sessions |
| Monitoring | SQLite | `/workspace/WiseMind/wisemind_monitor.db` | Query logs |
| Knowledge Graph | NetworkX + FAISS | `/workspace/WiseMind/ninds_cde_graph/` | 15 MB total |
| RAG Index | ColBERT (WiseFind) | `/workspace/WiseMind/` | Greenberg handbook |

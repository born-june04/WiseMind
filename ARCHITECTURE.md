# WiseMind System Architecture

> Version: v1.7.0 | Updated: 2026-04-12

---

## Level 1 — High-Level Overview

> Three core layers: what the user sees, what processes the request, and what data powers it.

```mermaid
flowchart LR
    USER(("👤 User"))

    subgraph FE["Frontend  (port 3000)"]
        CHAT["Chat Interface"]
        PANEL["Source Panel\nPDF + Highlights"]
    end

    subgraph BE["Backend  (port 5001)"]
        QUERY["Query Intelligence"]
        RAG["Greenberg RAG"]
        GEN["LLM Generation"]
        QUAL["Quality Control"]
    end

    subgraph KNOW["Knowledge Layer"]
        BOOK["Greenberg Handbook\n~18,000 chunks"]
        GRAPH["NINDS-CDE Graph\n2,556 CDEs"]
        DEFS["Medical Terms\n1,730 definitions"]
    end

    subgraph INFRA["Infrastructure"]
        LLM["MedGemma 27B\n(Ollama · GPU)"]
        DB["MongoDB\nConversations"]
        MON["SQLite\nMonitoring"]
    end

    USER -->|"question"| CHAT
    CHAT -->|"POST /v1/generate"| QUERY
    QUERY --> RAG
    QUERY --> GRAPH
    RAG --> GEN
    GRAPH --> GEN
    DEFS --> GEN
    GEN --> LLM
    LLM --> QUAL
    QUAL -->|"streaming answer"| CHAT
    CHAT -->|"click reference"| PANEL
    PANEL -->|"GET /v1/source-page"| BE
    BE --> BOOK
    DB <--> FE
    QUAL --> MON
```

---

## Level 2 — Query Processing Flow

> End-to-end sequence from user input to final streamed answer.

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
        BE->>CDE: Inject CDE definition snippet into prompt
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
        FE->>User: Right panel — PDF page with highlighted passage
    end
```

---

## Level 2 — Module: Query Intelligence

> How a raw user query is enriched before hitting the RAG engine.

```mermaid
flowchart TD
    IN["Raw User Query\n+ Conversation History"]

    CORR{"Correction\nSignal?\n(wrong / should be)"}
    HIST["Extract last 3 turns\nfor multi-turn context"]
    ENTITY["Extract Medical Entities\nacronyms + clinical terms\n(e.g. TBI, ICP, GCS)"]

    ONT["Ontology Expansion\nCSV keyword dict\n+ synonym mapping"]
    CDE["NINDS-CDE Graph Expansion\nFAISS cosine search → top-3 CDEs\n→ append variable names"]
    TOPIC["Topic Classification\nKeyword match →\ntraumatic_brain_injury / SCI / vascular..."]
    FILTER["Page Range Filter\npage_index ∈ [lo, hi]\n(ChromaDB where clause)"]
    CACHE_CHK{"Semantic Cache\ncosine ≥ 0.92?"}

    OUT_CACHE["⚡ Cached Response\n(skip RAG + LLM)"]
    OUT_QUERY["Enriched Query\n+ Page Filter\n→ RAG Engine"]

    IN --> CACHE_CHK
    CACHE_CHK -->|"HIT"| OUT_CACHE
    CACHE_CHK -->|"MISS"| CORR
    CORR -->|"yes — drop history"| ONT
    CORR -->|"no"| HIST
    HIST --> ENTITY
    ENTITY --> ONT
    ONT --> CDE
    CDE --> TOPIC
    TOPIC --> FILTER
    FILTER --> OUT_QUERY
```

---

## Level 2 — Module: Greenberg RAG Pipeline

> How the handbook is searched and results are assembled into context.

```mermaid
flowchart TD
    IN["Enriched Query\n+ page_index filter"]

    COLBERT["ColBERT Search\n(WiseFind multimodal)\ntext_k=5  image_k=1"]
    FILTER["Apply Page Range Filter\n(ChromaDB where clause)\nUp to 80% search space reduction"]
    TEXT_R["Text Results\n≤5 chunks with scores"]
    IMG_R["Image Results\n≤1 figure (score threshold)"]

    QUALITY{"RAG Quality\nAvg score ≥ threshold?"}
    FALLBACK["Fallback: Keyword Search\nBM25-style over chunks\n+deduplicate"]

    MIDDLE["Middle Layer Search\nBTF Guidelines / Research Papers\nFAISS  top-3"]

    ENRICH["Enrich with Chunk Metadata\nfigures / tables / section titles"]
    CONTEXT["Format RAG Context\n[1] Section ... content ...\n[2] Section ... content ..."]
    CDE_SNIP["Inject NINDS-CDE Snippet\n[NINDS CDE Reference]\nStandardized definitions"]
    MED_DEFS["Inject Medical Definitions\n1,730 terms → matched subset"]

    HALT{"RAG results\nempty?"}
    BLOCK["⛔ Block Generation\nReturn: no evidence found"]
    OUT["Full Context String\n→ LLM Generation"]

    IN --> COLBERT
    COLBERT --> FILTER
    FILTER --> TEXT_R & IMG_R
    TEXT_R --> QUALITY
    QUALITY -->|"low"| FALLBACK
    FALLBACK --> ENRICH
    QUALITY -->|"ok"| ENRICH
    IMG_R --> ENRICH
    MIDDLE --> ENRICH
    ENRICH --> CONTEXT
    CONTEXT --> HALT
    HALT -->|"yes"| BLOCK
    HALT -->|"no"| CDE_SNIP
    CDE_SNIP --> MED_DEFS
    MED_DEFS --> OUT
```

---

## Level 2 — Module: LLM Generation & Quality

> Two generation modes and post-generation quality scoring.

```mermaid
flowchart TD
    IN["Full Context + Question"]

    MODE{"thinking_mode?"}

    subgraph FLASH["Flash Mode (default)"]
        F1["Single LLM call\n(MedGemma 27B streaming)"]
        F2["Stream tokens → Frontend"]
    end

    subgraph THINK["Thinking Mode"]
        T1["Step 1 — Draft\nGenerate initial answer"]
        T2["Step 2 — Expert Review\nNeeds refinement? (multi-signal check)"]
        T3{"Needs\nrefinement?"}
        T4["Step 3 — Refine\nIncorporate review feedback"]
        T1 --> T2 --> T3
        T3 -->|"yes"| T4
        T3 -->|"no"| T4
    end

    SOURCES["Attach Source Citations\n[Greenberg, p.XXXX]\nchunk_id + page + score"]
    FAITH["NLI Faithfulness Score\ndeberta-v3-small\nentailment over answer sentences"]
    CONF["Confidence Score\nhedge-phrase density\n+ avg ColBERT score"]

    WARN{"faithfulness\n< 45%?"}
    BADGE["⚠️ Yield warning badge\nto frontend stream"]

    CACHE_STORE{"High quality?\nrag≥0.35, faith≥0.45\nlen≥80 chars"}
    STORE["Store in Semantic Cache\nFAISS + metadata"]
    LOG["Log to SQLite\nquery / topic / scores / latency"]

    OUT["Final Response\n+ Sources + Badges"]

    IN --> MODE
    MODE -->|"flash"| FLASH
    MODE -->|"thinking"| THINK
    FLASH --> SOURCES
    THINK --> SOURCES
    SOURCES --> FAITH
    FAITH --> CONF
    CONF --> WARN
    WARN -->|"yes"| BADGE
    WARN -->|"no"| CACHE_STORE
    BADGE --> CACHE_STORE
    CACHE_STORE -->|"yes"| STORE
    CACHE_STORE --> LOG
    LOG --> OUT
```

---

## Level 2 — Module: Source Reference Display

> How a reference button click becomes a highlighted PDF page.

```mermaid
flowchart TD
    IN["Reference Button Click\npage_num (RAG page_index)\n+ search text (chunk content)"]

    BEST["Find Best Page\n_find_best_page()\nContent match over ±3 pages\nPenalize reference/bibliography pages"]
    OFFSET["Compute book_page\npdf_page + GREENBERG_BOOK_PAGE_OFFSET\n→ e.g. 1071"]

    IMG_PATH["Load Page Image\ngreenberg_pages/1071.jpg\n(filename = book page number)"]
    TEXT_IDX["Load Text Index\ngreenberg_text_index.json\ntext blocks for this page"]

    BBOX["Find Highlight BBoxes\n_find_highlight_bboxes()\n① exact: block text ⊂ chunk content → top-3\n② fallback: word-overlap score → top-2"]

    RESP["Response JSON\n{ image_url, highlight_bboxes,\n  book_page, section }"]

    FE_RENDER["Frontend Renders\n<img> overlay with\nnormalized bbox rectangles"]

    IN --> BEST
    BEST --> OFFSET
    OFFSET --> IMG_PATH & TEXT_IDX
    TEXT_IDX --> BBOX
    IMG_PATH --> RESP
    BBOX --> RESP
    RESP --> FE_RENDER
```

---

## Level 3 — NINDS-CDE Knowledge Graph Structure

```mermaid
graph TD
    ROOT_TBI["Disease: TBI"]
    ROOT_SCI["Disease: SCI"]

    DOM1["Domain: Outcomes and End Points"]
    DOM2["Domain: Assessments and Examinations"]
    DOM3["Domain: Disease / Injury Related Events"]
    DOM4["Domain: International SCI Data Sets"]

    SUB1["Subdomain: Neuropsychological Impairment"]
    SUB2["Subdomain: Post-concussive / TBI Symptoms"]
    SUB3["Subdomain: Imaging Diagnostics"]
    SUB4["Subdomain: Neurological Outcomes"]

    CDE1["CDE: Intracranial Pressure\nvar: ICPMeanDailyMeasure"]
    CDE2["CDE: Glasgow Coma Scale\nvar: GCSDateAndTime"]
    CDE3["CDE: ASIA Impairment Scale\nvar: ASIAImprmntScale"]
    CDE4["CDE: Functional Outcome\nvar: TherpyRehabOngngInd"]

    SN1["SNOMED: 271782001"]
    SN2["SNOMED: 248241002"]

    SHARED["137 Shared CDEs\nTBI ↔ SCI cross-links"]

    ROOT_TBI --> DOM1 & DOM2 & DOM3
    ROOT_SCI --> DOM4 & DOM2
    DOM1 --> SUB1 & SUB2
    DOM2 --> SUB3
    DOM4 --> SUB4
    SUB2 --> CDE1
    SUB1 --> CDE2
    SUB3 --> CDE3
    SUB4 --> CDE4
    CDE1 --> SN1
    CDE2 --> SN2
    ROOT_TBI -. "shared_cde" .-> SHARED
    ROOT_SCI -. "shared_cde" .-> SHARED
```

---

## Level 3 — Data Layer Schema

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
        list bboxes "normalized x0 y0 x1 y1"
    }
    CDE_GRAPH_NODE {
        string node_id "CDE--TBI--C12345"
        string cde_id
        string name
        string variable
        string definition
        string domain
        string subdomain
        string disease "TBI or SCI"
        string snomed
        string loinc
        vector embedding "384-dim"
    }
    CHAPTER_MAP {
        string topic "traumatic_brain_injury"
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
        string thinking_mode
    }

    GREENBERG_CHUNKS ||--|| GREENBERG_PAGES : "page_index → book_page"
    CDE_GRAPH_NODE }o--|| CHAPTER_MAP : "domain aligns with topic"
    QUERY_LOGS }o--o| CHAPTER_MAP : "classified topic"
```

---

## Feature Timeline

```mermaid
timeline
    title WiseMind Feature Roadmap
    section Foundation
        v1.3 : Greenberg ColBERT RAG
             : Medical terms dictionary 1730
             : Middle layer BTF Guidelines
             : Evidence conflict expression
    section UI and Accuracy
        v1.4 : Reference buttons RAG-conditional
             : PDF Source Panel right side
             : Highlight bounding boxes
        v1.5 : book_page.jpg filename mapping
             : Content-based page finder
             : Exact-match highlight logic
    section Quality Pipeline
        v1.6.0 : Topic-based page filter
               : greenberg_chapter_map.json
        v1.6.2 : Semantic cache FAISS cosine 0.92
        v1.6.3 : NLI faithfulness scoring
               : SQLite monitoring DB
        v1.6.4 : Hallucination guard
        v1.6.5 : Multi-turn query understanding
    section Ontology
        v1.7 : NINDS-CDE knowledge graph
             : 2556 CDEs TBI and SCI
             : Query expansion and definition injection
             : /v1/cde/search API
```

---

## API Endpoints Reference

| Endpoint | Method | Description |
|---|---|---|
| `/v1/generate` | POST | Main chat generation — Flash / Thinking, streaming SSE |
| `/v1/health` | GET | Service health check |
| `/v1/source-page/[page]` | GET | Greenberg page image URL + highlight bboxes |
| `/v1/source-page-img/[page]` | GET | Serve book page JPEG directly |
| `/v1/cde/search?q=&k=` | GET | Semantic search over NINDS-CDE graph |
| `/v1/admin/metrics?days=` | GET | Aggregated query stats from SQLite |

---

## Infrastructure Summary

| Component | Technology | Location | Notes |
|---|---|---|---|
| Frontend | SvelteKit + Vite | port 3000 | `nohup npm run dev` |
| Backend | Flask + Gunicorn 4 workers gevent | port 5001 | Docker `wisemind-backend` |
| LLM Serving | Ollama | port 11434 | `systemctl ollama` |
| GPU | NVIDIA GB10 DGX Spark ARM | host | `--runtime=nvidia --gpus all` |
| Database | MongoDB | localhost | Conversations + sessions |
| Monitoring | SQLite | `/workspace/WiseMind/wisemind_monitor.db` | Query logs |
| Knowledge Graph | NetworkX + FAISS | `/workspace/WiseMind/ninds_cde_graph/` | 15 MB total |
| RAG Index | ColBERT WiseFind | `/workspace/WiseMind/` | Greenberg handbook |

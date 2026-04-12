# WiseMind Release Notes

---

## v1.7.0 — 2026-04-12  *(NINDS-CDE Knowledge Graph)*

> **Rollback:** `git checkout v1.6.5 -- backend` → `docker exec wisemind-backend kill -HUP 1`

### Summary
Replaced ad-hoc CSV ontology (`wisemind_ontology_terms_v2.csv`) with a full **NINDS-standard
knowledge graph** built from official CDE xlsx exports. Enables structured, standards-compliant
ontology lookup integrated into the RAG pipeline.

### New Features

#### NINDS-CDE Parsing
- Parsed official NINDS TBI CDE xlsx → **1,492 unique CDEs** across 8,648 rows
- Parsed official NINDS SCI CDE xlsx → **1,064 unique CDEs** across 1,597 rows
- Fields retained: CDE ID, Name, Variable, Definition, Domain, Subdomain, Classification, SNOMED, LOINC, CRF Module

#### Knowledge Graph Construction (`cde_graph.pkl`)
- **NetworkX DiGraph**: Disease → Domain → Subdomain → CDE → SNOMED node hierarchy
- **2,615 nodes** total: 2,556 CDE nodes + domain/subdomain/SNOMED nodes
- **137 CDEs cross-linked** between TBI and SCI (shared CDE ID)
- SNOMED CT edges: CDE↔external terminology linking

#### Semantic Embedding + FAISS Index (`cde_faiss.index`)
- All 2,556 CDE nodes embedded with `all-MiniLM-L6-v2` (384-dim)
- Inner-product FAISS index (normalized) for fast cosine similarity search
- Build time: ~8 seconds on GPU

#### RAG Pipeline Integration
- **`_cde_graph_expand_query()`**: appends matching NINDS variable names to RAG query
  → e.g., "intracranial pressure" → query + "IntracranPressEpisode IntracranPressMonitorStop..."
- **`_cde_context_snippet()`**: injects top-3 CDE definitions as `[NINDS CDE Reference]` block
  into LLM prompt → authoritative standardized definitions grounding the answer
- Both functions use threshold filtering (score ≥ 0.50–0.55) to suppress low-confidence matches

#### New API Endpoint
- `GET /v1/cde/search?q=<query>&k=<n>` — semantic CDE search, returns CDE name, variable, domain, definition, SNOMED
- `GET /v1/admin/metrics` — now includes `cde_graph.loaded` and `cde_graph.node_count`

### Files Added on Server
```
/workspace/WiseMind/ninds_cde_graph/
  cde_graph.pkl       (9.7 MB  — NetworkX DiGraph with embeddings)
  cde_faiss.index     (3.8 MB  — FAISS IndexFlatIP)
  cde_node_ids.json   (50  KB  — node ID list for index ↔ graph mapping)
  cde_flat.json       (1.3 MB  — flat JSON for quick lookups)
/workspace/WiseMind/ninds_cde_tbi.json   (TBI CDEs)
/workspace/WiseMind/ninds_cde_sci.json   (SCI CDEs)
```

### Why Graph + Embedding (vs. pure embedding)?
| Capability | Pure Embedding | Graph + Embedding |
|---|---|---|
| Semantic CDE lookup | ✓ | ✓ |
| Domain hierarchy queries | ✗ | ✓ |
| SNOMED cross-reference | ✗ | ✓ |
| "Core CDEs in Neurological Outcomes" | ✗ | ✓ |
| Multi-hop: TBI↔SCI shared terms | ✗ | ✓ |

---

## v1.6.x — 2026-04-12  *(RAG Quality Pipeline)*

> **Rollback:** `git checkout v1.5.1` on `backend` repo → reload Gunicorn (`kill -HUP 1` inside container)

---

### v1.6.5 — Multi-turn Query Understanding
- `_extract_context_entities()`: extracts medical acronyms/terms from last 3 conversation turns
- Appended to RAG query so follow-up questions inherit prior context automatically

### v1.6.4 — Hallucination Guard
- Empty RAG result → generation blocked; returns "근거 없음" message instead of hallucinating
- NLI faithfulness < 45% → streaming warning badge shown to user

### v1.6.3 — NLI Faithfulness Scoring + Monitoring
- Model: `cross-encoder/nli-deberta-v3-small` (GPU, ~280 MB, ~150 ms/query)
- `_compute_faithfulness()`: NLI entailment score averaged over answer sentences
- `_compute_confidence()`: hedge-phrase density + ColBERT retrieval score
- SQLite `query_logs`: records topic, faithfulness, confidence, retrieval score, response ms per query
- `GET /v1/admin/metrics?days=N`: aggregated stats + top topics + recent queries

### v1.6.1 — Thinking Mode Robustness
- Step 2 verdict uses multi-signal detection (string + JSON variant + natural language)
- Prevents silent failures when model format deviates from expected

### v1.6.0 — Topic-based RAG Page Range Filtering
- `greenberg_chapter_map.json`: 10 topics × chapter ranges × keyword lists (auto-generated from chunks)
- `_classify_topic()`: zero-latency keyword match → topic label
- `_topic_page_filter()`: ChromaDB where-clause `page_index ∈ [lo, hi]`
- Up to 80% search space reduction for topic-specific queries
- Graceful fallback to full search if where-clause not supported

---


## v1.4.2 — 2026-03-14

### Summary
Full RAG pipeline fix: all 7 debug-report fixes applied and verified. 11/11 test cases pass (up from 0%).

---

### New / Changed

#### Fix 6 — Expert GCS / Mild TBI Definition Override
- `definitions/manual_overrides.json` now loaded with **highest priority** (overrides XLSX and JSON).
- `definition_loader.py`: three-tier load order — `medical_terms.json` → `medical_terms.xlsx` → `manual_overrides.json` (gold standard).
- **Mild TBI** definition added as expert-reviewed override: GCS **14–15** per current clinical consensus (Greenberg p.988 defines 13–15, but expert consensus reclassifies GCS 13 as moderate).
- **TBI** definition updated: mild 14–15, moderate 9–13, severe ≤8.
- `system_prompt.txt`: definitions block explicitly overrides conflicting Greenberg values when marked expert-reviewed.

#### Fix 7 — Section-Aware Query Expansion
- `api_server.py`: `_CONTEXT_EXPANSIONS` dict + `_expand_query_with_context()` function.
- Clinical keyword fragments (e.g. `"intubat"`, `"marshall"`, `"subdural"`) expand the RAG query with chapter-specific terms, biasing ColBERT toward the correct section.
- Prevents cross-chapter false matches (e.g. "intubation" matching aneurysm postop instead of head trauma).

#### Fix 6b — Additional Definition Coverage (resolves B1–B3)
- **Marshall CT Classification** added to `manual_overrides.json` — all 6 categories (Diffuse I–IV, Evacuated, Non-evacuated).
- **SDH** surgical indications expanded: thickness >10 mm OR shift >5 mm; added `"subdural"` alias for single-word matching.
- **ICP** definition enriched: intracranial hypertension defined as ICP >22 mmHg (BTF 4th Ed., unit = mmHg not cm H₂O); all 5 clinical signs listed including papilledema.

#### Debug page (Settings)
- New **Debug** entry in Settings sidebar: **Settings → Debug**.
- Shows server-side debug info: API base URL, API key set, models count, Node version.
- Optional **Refresh router /models** button.

### Test Results (debug/test_rag_cases.py)

| ID | Category | Before | After |
|----|----------|--------|-------|
| A1 | Wrong retrieval — intubation | ❌ | ✅ |
| A2 | Wrong retrieval — temporal lobe | ❌ | ✅ |
| A3 | Wrong retrieval — artery of Percheron | ❌ | ✅ |
| A4 | Wrong retrieval — mild GCS | ❌ | ✅ |
| B1 | Table truncation — Marshall CT | ❌ | ✅ |
| B2 | Table truncation — SDH surgery | ❌ | ✅ |
| B3 | Table truncation — IC hypertension | ❌ | ✅ |
| C1 | Hallucination — craniopharyngioma | ❌ | ✅ |
| D1 | Correction — hyperventilation | ❌ | ✅ |
| E1 | Sanity — basal skull fracture | ✅ | ✅ |
| E2 | Sanity — mild TBI head CT | ✅ | ✅ |

**Pass rate: 11/11 (100%)**

---

## v1.4.0 — 2026-03-07

### Summary
Inline reference grounding: every citation in the AI response is now a clickable button that opens a side panel showing the exact source passage with keyword highlighting. Covers both Greenberg textbook (📖) and clinical guidelines (📋).

---

### New Features

#### Inline Citation Buttons
LLM responses now use sequential `[N]` citation markers instead of inline links:

- e.g. *"ICP > 22 mmHg triggers treatment [1]"* → clicking `[1]` opens the source
- Greenberg chunks show 📖 icon + page number
- Clinical guideline chunks show 📋 icon + document name
- Buttons appear as small blue pill-shaped badges inline with the text

#### Source Panel (Side Panel)
A new slide-in panel appears from the right when a citation is clicked:

- Shows source type, section title, and page number (for Greenberg)
- Displays the exact 800-character passage from the indexed chunk
- **Keyword auto-highlighting**: section and document title words are highlighted in yellow
- External URL link ("Open source document") for guideline PDFs
- Close via X button or backdrop click
- Panel does not interfere with the chat scroll state

#### Backend Changes
- `_format_rag_context`: unified sequential `[N]` numbering across Greenberg + guideline chunks
- `_build_source_metadata`: embeds full `content` (800 chars), `chunk_id`, and `ref_index` per source; structured data injected as `<!--wisemind-sources:BASE64-->` HTML comment for frontend parsing
- LLM system prompts (`STEP1_SYSTEM_PROMPT`, `STEP2_SYSTEM_PROMPT`, `system_prompt.txt`) updated to use `[N]` citation format

#### Frontend Changes (`ui/`)
- `marked.ts`: `WiseMindSource` type added; `processBlocks` / `processBlocksSync` accept `wisemindSources` for per-response rendering (cache-bypassed)
- `MarkdownRenderer.svelte`: new `wisemindSources` prop forwarded to marked
- `ChatMessage.svelte`: parses `<!--wisemind-sources:BASE64-->` from message content; routes cite-button clicks to `SourcePanel`
- `SourcePanel.svelte`: new component — slide-in panel with keyword highlight, close button, and optional source URL

---

## v1.3.2 — 2026-03-07

### Summary
RAG accuracy improvements: query expansion using medical ontology, middle layer guideline source attribution with PDF URLs, and ontology category normalization for richer definition injection.

---

### New Features

#### RAG Query Expansion
Medical abbreviations in the user query are automatically expanded before vector search using the ontology alias map:

- e.g. `"ICP management in TBI?"` → search query includes `"intracranial pressure traumatic brain injury"`
- Improves recall for abbreviation-heavy clinical queries
- Capped at 4 expansions to prevent query dilution
- **Definition injection** also scans the full conversation context (expanded query with prior turns), not just the current message — picks up terms referenced in earlier turns

#### Middle Layer Source Attribution
Each clinical guideline chunk now carries full source metadata:
- `source_id` (= `doc_id`) for unambiguous provenance
- `source_url` — direct link to the source PDF, loaded from `sources.json`
- Guideline citations in the response footer now render as clickable links:
  `[BTF Guidelines: Management of Severe TBI (4th Edition)](https://...)`

#### Ontology v2 — Category Normalization
`medical_terms.json` category distribution improved with keyword-rule reclassification:

| Category | Before | After |
|---|---|---|
| entity | 733 | 28 |
| term | 187 | 64 |
| condition | 315 | **584** |
| anatomy | 214 | **490** |
| procedure | 69 | **262** |
| imaging | 101 | **127** |
| scoring | 49 | **101** |

More specific categories improve definition injection priority and LLM context quality. The 92 remaining `entity`/`term` entries are genuinely ambiguous (journal names, composite concepts).

---

### Technical Details

| Component | Change |
|---|---|
| `api_server.py` | Added `_expand_query()` — ontology alias expansion before RAG search |
| `api_server.py` | `build_definitions_context` now uses expanded `rag_query` (full context) |
| `api_server.py` | `_build_source_metadata` renders guideline URLs as markdown links |
| `middle_layer_search.py` | Loads `sources.json` into `_sources_map`; enriches results with `source_id`, `source_url` |
| `definitions/medical_terms.json` | 827 terms reclassified from vague to specific categories |

---


## v1.3.1 — 2026-03-07

### Summary
Refactored "active conflict detection" to "source-faithful presentation": the system no longer explicitly labels conflicts, but naturally presents each source's perspective when multiple sources address the same clinical point.

---

### Changes

#### Source-Faithful Presentation (replaces Conflict Detection)
The v1.3.0 "Evidence Conflict" feature actively searched for disagreements and labeled them with `⚠️ Evidence Conflict`. Based on feedback, the goal is *transparency*, not judgment — when Greenberg and BTF Guidelines differ, the response naturally states both views side by side without a forced conflict label.

- **STEP1 / STEP2 / STEP3 prompts** (`api_server.py`): Removed `⚠️ CONFLICT RULE (CRITICAL)`; replaced with `SOURCE-FAITHFUL PRESENTATION` instruction. STEP2 review criterion updated from "Evidence conflicts" to "Source faithfulness."
- **Flash mode** (`system_prompt.txt`): Same replacement applied.

---

## v1.3.0 — 2026-03-07

### Summary
Focus on clinical accuracy: Greenberg retrieval is now scoped to neurotrauma and spinal cord chapters, conflicting evidence is always surfaced to the clinician, middle layer guideline citations appear reliably in every response, and all conversations are logged for future LLM fine-tuning.

---

### New Features

#### Greenberg Chapter Filter — Neurotrauma + Spine Only
RAG retrieval from Greenberg's Handbook is scoped to **Chapters 59–84** (p. 979–1413):

| Chapters | Content | Pages |
|---|---|---|
| Ch 60–67 | Head Trauma: TBI, concussion, skull fractures, hemorrhagic conditions, pediatric, long-term | 988–1119 |
| Ch 68–73 | Spinal Cord Injury: general, SCI management, C-spine, thoracolumbar, penetrating | 1125–1230 |
| Ch 74–84 | Spine degenerative and special conditions | 1213–1413 |
| Ch 59 | Tumors of the Spine and Spinal Cord | 979–983 |

Out-of-scope queries (e.g., glioma, epilepsy) automatically fall back to the full corpus — no broken answers. Fallback keyword search is also scoped to the same page range.

#### Evidence Conflict Detection
When two or more sources recommend **different** approaches to the same clinical situation, the system now:
- Presents **all conflicting perspectives** in a clearly marked `⚠️ Evidence Conflict` section, each with its source citation
- Never silently picks one view over another
- Appends: *"Clinical judgment required — consult your institution's protocol."*

This rule is applied in both Flash mode (`system_prompt.txt`) and Thinking mode (STEP1/STEP2/STEP3 prompts). The STEP2 review step explicitly checks whether the draft has omitted any conflicting evidence.

#### Middle Layer Guideline Citations Fixed
Middle layer results (BTF, AHA/ASA, CNS/AANS clinical guidelines) were being retrieved but silently dropped from LLM context due to `max_chunks=3` cutting off guidelines in favor of Greenberg results.

Fix: Greenberg and guideline chunks are now built into **separate context sections** — up to 4 Greenberg chunks + 3 guideline chunks are always included.

- Response footer now shows a separate **"📋 Clinical Guidelines & Research"** citation section
- LLM prompted to use `[Guidelines: <document title>]` format for guideline sources
- Chunk labels distinguish source: `[Reference N]` for Greenberg, `[Guideline Ref N: title]` for guidelines

#### Conversation Storage for LLM Training
Each non-streaming response is saved to `wisemind.conversations` in MongoDB:

```
{
  user_message, assistant_message,
  rag_sources,        // which chunks were used
  rag_quality,        // avg_score, sufficient flag
  figures_shown,      // image IDs included in response
  thinking_mode,      // "flash" or "thinking"
  model,
  multistep           // step1/step2/step3 results (thinking mode)
}
```

Enables future supervised fine-tuning with real clinical Q&A + RAG provenance data.

---

### Fixes

#### Image Relevance Threshold: 0.35 → 0.70
Raised `IMAGE_SCORE_THRESHOLD` to eliminate irrelevant image suggestions in responses. Images must now score ≥ 0.70 on BiomedCLIP similarity to appear in a response.

#### MongoDB numpy Type Serialization Bug
Fixed `Cannot encode numpy.bool_` error that prevented conversation documents from being saved. All numpy scalar types are now cast to Python-native types before MongoDB insert.

---

### Technical Changes

| File | Change |
|---|---|
| `backend/api_server.py` | Chapter filter constants + post-filter logic, conflict prompts in STEP1–3, conversation storage, numpy serialization fix, datetime import |
| `backend/system_prompt.txt` | Evidence Conflict rule added for Flash mode |
| `_format_rag_context()` | Layer-aware labels: `[Reference N]` vs `[Guideline Ref N]` |
| `_build_rag_context()` | Splits Greenberg and guideline chunks into separate context sections |
| `_build_source_metadata()` | Separate Greenberg / Guidelines citation sections in response footer |
| `_get_greenberg_chunks()` | Fallback search scoped to neurotrauma/spine page range |

---

### Test Results — 2026-03-07

| Test Case | Query | Result |
|---|---|---|
| TBI chapter filter | "ICP management threshold in severe TBI" | ✅ Filter applied: 3/5 chunks in range |
| SCI chapter filter | "methylprednisolone dosing for acute SCI" | ✅ Filter applied: 5/5 chunks in range |
| Out-of-scope fallback | "treatment for glioblastoma multiforme" | ✅ Filter skipped, full-corpus fallback |
| Evidence conflict | Methylprednisolone SCI | ✅ Conflicting NASCIS vs. current guidelines shown |
| Middle layer citation | "BTF guidelines for ICP monitoring" | ✅ `[Guidelines: BTF Guidelines: Management of Severe TBI]` cited |
| MongoDB storage | CPP target in TBI | ✅ Conversation saved with rag_sources and rag_quality |
| Image threshold | Multiple TBI queries | ✅ Images below 0.70 skipped in logs |

---

## v1.2.2 — 2026-02-XX
- Fix: professor-priority ontology edits preserved over CSV auto-imports
- Fix: middle layer FAISS indexing verified and confirmed on prod

## v1.2.1 — 2026-02-XX
- Fix: SCRIPT_DIR added to sys.path for Gunicorn worker module resolution
- Fix: thread-safe RAG singletons, preload-only flag for Gunicorn

## v1.2.0 — 2026-02-XX
- Feat: Middle Layer — 10 clinical guideline PDFs indexed (BTF, AHA/ASA, CNS/AANS; 4686 chunks)
- Feat: Ontology / Medical Term Definitions layer (1730 terms, professor-curated)
- Feat: Thumbs up/down feedback endpoint `/v1/feedback`
- Feat: Conversation context — last 3 turns included in RAG query expansion

## v1.1.0 — 2026-02-XX
- Feat: Flash / Thinking mode toggle (multi-step Draft → Review → Refine pipeline)
- Feat: Gunicorn + gevent workers (4 workers, 600 s timeout) for multi-user support

## v1.0.0 — 2026-02-XX
- Initial release: WiseMind backend with WiseFind multimodal RAG (ColBERT + BiomedCLIP + Knowledge Graph)
- Greenberg's Handbook of Neurosurgery 10th Ed indexed (21,429 chunks, 406 figures)

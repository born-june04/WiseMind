# WiseMind Release Notes

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

# WiseMind Release Notes

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

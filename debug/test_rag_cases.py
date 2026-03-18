#!/usr/bin/env python3
"""
WiseMind RAG Test Suite
Tests the 17 failing cases identified in the debug report against the API.

Usage:
    python test_rag_cases.py [--server http://localhost:5001] [--verbose]
"""

import argparse
import json
import re
import sys
import time

import requests


# ── Test cases from debug report (Category A–D) ──
TEST_CASES = [
    # Category A: Wrong Documents Retrieved
    {
        "id": "A1",
        "category": "wrong_retrieval",
        "question": "When should a patient be intubated in trauma",
        "expected_sections": ["head trauma", "intubation", "hyperventilation"],
        "unexpected_sections": ["aneurysm", "postoperative"],
        "expected_keywords": ["GCS", "airway", "intubat"],
        "description": "Should retrieve head trauma intubation guidelines, not aneurysm postop",
    },
    {
        "id": "A2",
        "category": "wrong_retrieval",
        "question": "What vessel supplies the anterior temporal lobe",
        "expected_keywords": ["middle cerebral", "MCA"],
        "unexpected_keywords": ["whiplash", "spine"],
        "should_refuse": True,  # If not in Greenberg, should say so
        "description": "Should cite MCA or state topic not in excerpts",
    },
    {
        "id": "A3",
        "category": "wrong_retrieval",
        "question": "What artery can cause bilateral thalamic and mesencephalic infarctions",
        "expected_keywords": ["Percheron", "artery of Percheron"],
        "should_refuse": True,
        "description": "Should mention artery of Percheron or refuse",
    },
    {
        "id": "A4",
        "category": "wrong_retrieval",
        "question": "What is a mild GCS score",
        "expected_keywords": ["14", "15"],
        "description": "Greenberg defines mild GCS as 14-15",
    },

    # Category B: Table/Structured Data Truncation
    {
        "id": "B1",
        "category": "truncation",
        "question": "What is the Marshall CT classification",
        "expected_keywords": ["Diffuse Injury I", "Diffuse Injury II", "Diffuse Injury III",
                              "Diffuse Injury IV", "evacuated", "non-evacuated"],
        "min_categories": 4,  # Should list at least 4 of 6 categories
        "description": "Should enumerate all 6 Marshall CT categories",
    },
    {
        "id": "B2",
        "category": "truncation",
        "question": "When should you operate on a subdural hematoma",
        "expected_keywords": ["10 mm", "5 mm", "midline shift", "thickness"],
        "description": "Should include specific surgical criteria",
    },
    {
        "id": "B3",
        "category": "truncation",
        "question": "What are signs of intra-cranial hypertension",
        "expected_keywords": ["22", "mmHg", "headache", "nausea", "papilledema"],
        "unexpected_keywords": ["25 cm H2O"],
        "description": "Should cite ICP > 22 mmHg (BTF), not 25 cm H2O",
    },

    # Category C: Hallucination
    {
        "id": "C1",
        "category": "hallucination",
        "question": "What is the embryological origin of craniopharyngiomas",
        "should_refuse": True,
        "description": "If not in excerpts, should refuse rather than guess",
    },

    # Category D: Conversation Context
    {
        "id": "D1",
        "category": "correction",
        "question": "What are the practice guidelines for hyperventilation in head injury",
        "expected_keywords": ["PaCO2", "30", "35", "prophylactic"],
        "description": "Should correctly cite hyperventilation guidelines",
    },

    # Category E: Should pass (sanity checks)
    {
        "id": "E1",
        "category": "sanity",
        "question": "What are signs of a basal skull fracture",
        "expected_keywords": ["raccoon", "Battle", "CSF", "rhinorrhea"],
        "description": "Known good case — should pass",
    },
    {
        "id": "E2",
        "category": "sanity",
        "question": "What is the practice guideline for the initial head CT with mild TBI",
        "expected_keywords": ["headache", "vomiting", "age", "60", "intoxication"],
        "description": "Known good case — ACEP criteria",
    },
]


def query_wisemind(server: str, question: str, timeout: int = 120) -> dict:
    """Send a question to the WiseMind API and return the response."""
    url = f"{server}/v1/chat/completions"
    payload = {
        "model": "wisemind-medgemma",
        "messages": [{"role": "user", "content": question}],
        "stream": False,
    }

    try:
        resp = requests.post(url, json=payload, timeout=timeout)
        resp.raise_for_status()
        data = resp.json()
        content = data.get("choices", [{}])[0].get("message", {}).get("content", "")

        # Extract metadata from wisemind-sources comment
        sources_match = re.search(r'<!--wisemind-sources:(.*?)-->', content)
        metadata = {}
        if sources_match:
            import base64
            try:
                metadata = json.loads(base64.b64decode(sources_match.group(1)).decode())
            except Exception:
                pass

        return {
            "content": content,
            "metadata": metadata,
            "status": "ok",
        }
    except requests.Timeout:
        return {"content": "", "metadata": {}, "status": "timeout"}
    except Exception as e:
        return {"content": "", "metadata": {}, "status": f"error: {e}"}


def evaluate_case(case: dict, response: dict) -> dict:
    """Evaluate whether a response passes the test case criteria."""
    content_lower = response["content"].lower()
    result = {"id": case["id"], "passed": True, "issues": []}

    # Check expected keywords
    for kw in case.get("expected_keywords", []):
        if kw.lower() not in content_lower:
            result["issues"].append(f"Missing expected keyword: '{kw}'")
            result["passed"] = False

    # Check unexpected keywords
    for kw in case.get("unexpected_keywords", []):
        if kw.lower() in content_lower:
            result["issues"].append(f"Found unexpected keyword: '{kw}'")
            result["passed"] = False

    # Check if model should refuse but didn't
    if case.get("should_refuse"):
        refusal_phrases = ["not covered", "do not directly address",
                           "cannot answer", "not contain", "not in the"]
        if not any(p in content_lower for p in refusal_phrases):
            # It answered without refusing — check if it's correct
            has_expected = all(kw.lower() in content_lower
                              for kw in case.get("expected_keywords", []))
            if not has_expected:
                result["issues"].append("Should have refused (topic not in excerpts) or given correct answer")
                result["passed"] = False

    # Check minimum category count (for classification questions)
    if "min_categories" in case:
        category_count = sum(1 for kw in case.get("expected_keywords", [])
                             if kw.lower() in content_lower)
        if category_count < case["min_categories"]:
            result["issues"].append(
                f"Only {category_count}/{case['min_categories']} categories found")
            result["passed"] = False

    return result


def main():
    parser = argparse.ArgumentParser(description="Test WiseMind RAG pipeline")
    parser.add_argument("--server", default="http://localhost:5001",
                        help="WiseMind API server URL")
    parser.add_argument("--verbose", action="store_true",
                        help="Print full responses")
    parser.add_argument("--cases", nargs="*", default=None,
                        help="Run specific case IDs (e.g., A1 B1)")
    args = parser.parse_args()

    cases = TEST_CASES
    if args.cases:
        cases = [c for c in TEST_CASES if c["id"] in args.cases]

    print(f"Testing {len(cases)} cases against {args.server}\n")
    print(f"{'ID':<5} {'Category':<18} {'Status':<8} {'Question':<50}")
    print("=" * 85)

    results = []
    passed = 0
    failed = 0

    for case in cases:
        q_short = case["question"][:47] + "..." if len(case["question"]) > 50 else case["question"]
        sys.stdout.write(f"{case['id']:<5} {case['category']:<18} {'...':<8} {q_short:<50}\r")
        sys.stdout.flush()

        t0 = time.time()
        response = query_wisemind(args.server, case["question"])
        elapsed = time.time() - t0

        if response["status"] != "ok":
            result = {"id": case["id"], "passed": False,
                      "issues": [f"API error: {response['status']}"]}
        else:
            result = evaluate_case(case, response)

        result["elapsed_s"] = round(elapsed, 1)
        results.append(result)

        status = "✅ PASS" if result["passed"] else "❌ FAIL"
        if result["passed"]:
            passed += 1
        else:
            failed += 1

        print(f"{case['id']:<5} {case['category']:<18} {status:<8} {q_short:<50} ({elapsed:.1f}s)")

        if not result["passed"] and args.verbose:
            for issue in result["issues"]:
                print(f"      ⚠ {issue}")
            print(f"      Response preview: {response['content'][:200]}...")
            print()

    print("=" * 85)
    print(f"Results: {passed} passed, {failed} failed out of {len(cases)} cases")
    print(f"Pass rate: {passed/len(cases)*100:.0f}%")

    # Save results
    with open("debug/test_results.json", "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nDetailed results saved to debug/test_results.json")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
WiseMind Feedback Analyzer
Connects to MongoDB and matches feedback entries to their Q&A pairs.

Usage:
    python analyze_feedback.py [--mongo-uri mongodb://localhost:27017]
"""

import argparse
import json
import sys
from datetime import datetime, timezone

def main():
    parser = argparse.ArgumentParser(description="Analyze WiseMind feedback data")
    parser.add_argument("--mongo-uri", default="mongodb://localhost:27017",
                        help="MongoDB connection URI")
    parser.add_argument("--output", default=None,
                        help="Output JSON file (default: stdout)")
    args = parser.parse_args()

    try:
        from pymongo import MongoClient
    except ImportError:
        print("ERROR: pymongo not installed. Run: pip install pymongo", file=sys.stderr)
        sys.exit(1)

    client = MongoClient(args.mongo_uri, serverSelectionTimeoutMS=5000)

    # ── 1. Fetch all feedback ──
    wisemind_db = client["wisemind"]
    feedback_col = wisemind_db["response_feedback"]
    feedbacks = list(feedback_col.find().sort("_id", -1))
    print(f"Found {len(feedbacks)} feedback entries", file=sys.stderr)

    # ── 2. Build feedback lookup ──
    feedback_by_msg = {}
    for fb in feedbacks:
        fb["_id"] = str(fb["_id"])
        feedback_by_msg[fb.get("message_id", "")] = fb

    # ── 3. Match to conversations ──
    chat_db = client["chat-ui"]
    results = []

    for conv in chat_db["conversations"].find():
        messages = conv.get("messages", [])
        for msg in messages:
            msg_id = msg.get("id", "")
            if msg_id in feedback_by_msg:
                fb = feedback_by_msg[msg_id]

                # Find the parent user message
                user_question = ""
                for m in messages:
                    if (m.get("id") in msg.get("ancestors", [])
                            and m.get("from") == "user"):
                        user_question = m.get("content", "")

                results.append({
                    "message_id": msg_id,
                    "rating": fb.get("rating"),
                    "comment": fb.get("comment", ""),
                    "timestamp": datetime.fromtimestamp(
                        fb.get("timestamp", 0), tz=timezone.utc
                    ).isoformat(),
                    "user_question": user_question[:300],
                    "assistant_response": msg.get("content", "")[:500],
                    "conversation_title": conv.get("title", "")[:100],
                })

    # Also check archive
    for conv in chat_db["conversations_archive"].find():
        messages = conv.get("messages", [])
        for msg in messages:
            msg_id = msg.get("id", "")
            if msg_id in feedback_by_msg and msg_id not in {r["message_id"] for r in results}:
                fb = feedback_by_msg[msg_id]
                user_question = ""
                for m in messages:
                    if (m.get("id") in msg.get("ancestors", [])
                            and m.get("from") == "user"):
                        user_question = m.get("content", "")
                results.append({
                    "message_id": msg_id,
                    "rating": fb.get("rating"),
                    "comment": fb.get("comment", ""),
                    "timestamp": datetime.fromtimestamp(
                        fb.get("timestamp", 0), tz=timezone.utc
                    ).isoformat(),
                    "user_question": user_question[:300],
                    "assistant_response": msg.get("content", "")[:500],
                    "conversation_title": conv.get("title", "")[:100],
                    "source": "archive",
                })

    # ── 4. Summary ──
    total = len(feedbacks)
    matched = len(results)
    positive = sum(1 for r in results if r["rating"] == 1)
    negative = sum(1 for r in results if r["rating"] == -1)
    with_comment = sum(1 for r in results if r["comment"])

    summary = {
        "summary": {
            "total_feedback": total,
            "matched_to_qa": matched,
            "unmatched": total - matched,
            "positive": positive,
            "negative": negative,
            "with_comments": with_comment,
            "negative_rate": f"{negative/total*100:.1f}%" if total else "N/A",
        },
        "cases": results,
    }

    output = json.dumps(summary, indent=2, ensure_ascii=False, default=str)

    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Results written to {args.output}", file=sys.stderr)
    else:
        print(output)

    # ── 5. Print readable summary ──
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"FEEDBACK ANALYSIS SUMMARY", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)
    print(f"Total feedback:   {total}", file=sys.stderr)
    print(f"Matched to Q&A:   {matched}", file=sys.stderr)
    print(f"Positive (👍):    {positive}", file=sys.stderr)
    print(f"Negative (👎):    {negative}", file=sys.stderr)
    print(f"Negative rate:    {negative/total*100:.1f}%" if total else "", file=sys.stderr)
    print(f"With comments:    {with_comment}", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)

    for r in results:
        icon = "👍" if r["rating"] == 1 else "👎"
        q = r["user_question"][:80]
        print(f"  {icon} Q: {q}", file=sys.stderr)


if __name__ == "__main__":
    main()

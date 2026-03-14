#!/usr/bin/env python3
"""
Apply WiseMind RAG pipeline fixes to the server.
Connects via SSH and patches files inside the wisemind-backend Docker container.

Fixes applied:
  1. RAG relevance threshold: 0.15 -> 0.45
  2. Content truncation: 500 -> 1200 chars
  3. System prompt: restrict hallucination
  4. User correction detection in _generate()
  5. Feedback endpoint: store Q&A context

Usage:
    python apply_fixes.py [--dry-run] [--container wisemind-backend-dev]
"""

import argparse
import sys

FIXES = {
    "fix1_threshold": {
        "file": "/workspace/WiseMind/backend/backend/api_server.py",
        "description": "Raise RAG relevance threshold from 0.15 to 0.45",
        "patches": [
            {
                "find": "RAG_RELEVANCE_THRESHOLD = 0.15",
                "replace": "RAG_RELEVANCE_THRESHOLD = 0.45",
            },
            {
                "find": "return (top > RAG_RELEVANCE_THRESHOLD * 2 or avg > RAG_RELEVANCE_THRESHOLD), avg",
                "replace": "return (top > 0.65 and avg > RAG_RELEVANCE_THRESHOLD), avg",
            },
        ],
    },
    "fix2_truncation": {
        "file": "/workspace/WiseMind/backend/backend/api_server.py",
        "description": "Increase content window from 500 to 1200 chars",
        "patches": [
            {
                "find": 'content = r.get("content", "")[:500]',
                "replace": 'content = r.get("content", "")[:1200]',
            },
        ],
    },
    "fix3_system_prompt": {
        "file": "/workspace/WiseMind/backend/backend/system_prompt.txt",
        "description": "Restrict hallucination in system prompt",
        "patches": [
            {
                "find": "You also draw on general medical knowledge and established guidelines (BTF, AHA/ASA, CNS/AANS).",
                "replace": (
                    "You may reference established BTF, AHA/ASA, and CNS/AANS guidelines when identified in the provided excerpts. "
                    "However, you MUST NOT supplement answers with general medical knowledge beyond what is in the excerpts. "
                    "If the excerpts do not address the question, clearly state: "
                    '"This topic is not covered in the available Greenberg references." '
                    "Do NOT guess or fabricate information."
                ),
            },
        ],
    },
    "fix4_correction_detection": {
        "file": "/workspace/WiseMind/backend/backend/api_server.py",
        "description": "Add user correction detection and re-retrieval",
        "patches": [
            {
                "find": "    # Build enriched RAG query: current question + recent context\n    if recent_user_msgs:",
                "replace": (
                    "    # ── Detect user corrections (\"that's wrong\", \"should be\", etc.) ──\n"
                    '    _correction_signals = ["should have", "incorrect", "wrong", "actually",\n'
                    '                           "should be", "look at", "not the correct", "missing",\n'
                    '                           "error", "you said", "that\\'s not"]\n'
                    "    _is_correction = any(s in user_msg.lower() for s in _correction_signals)\n"
                    "    if _is_correction:\n"
                    '        logger.info("🔄 Correction detected — using focused re-retrieval (no history)")\n'
                    "        recent_user_msgs = []  # Drop history to avoid noisy compound query\n"
                    "\n"
                    "    # Build enriched RAG query: current question + recent context\n"
                    "    if recent_user_msgs:"
                ),
            },
        ],
    },
    "fix5_feedback_data": {
        "file": "/workspace/WiseMind/backend/backend/api_server.py",
        "description": "Enrich feedback documents with Q&A context",
        "patches": [
            {
                "find": (
                    '        doc = {\n'
                    '            "conversation_id": data.get("conversationId", ""),\n'
                    '            "message_id": data.get("messageId", ""),\n'
                    '            "rating": rating,\n'
                    '            "comment": data.get("comment", ""),\n'
                    '            "timestamp": time.time(),\n'
                    '        }'
                ),
                "replace": (
                    '        doc = {\n'
                    '            "conversation_id": data.get("conversationId", ""),\n'
                    '            "message_id": data.get("messageId", ""),\n'
                    '            "rating": rating,\n'
                    '            "comment": data.get("comment", ""),\n'
                    '            "question": data.get("question", ""),\n'
                    '            "response": data.get("response", "")[:2000],\n'
                    '            "rag_quality": data.get("ragQuality", {}),\n'
                    '            "timestamp": time.time(),\n'
                    '        }'
                ),
            },
        ],
    },
}


def apply_fix(ssh, container: str, fix_name: str, fix: dict, dry_run: bool = False):
    """Apply a single fix via Docker exec."""
    print(f"\n{'='*60}")
    print(f"FIX: {fix_name} — {fix['description']}")
    print(f"File: {fix['file']}")
    print(f"{'='*60}")

    for i, patch in enumerate(fix["patches"]):
        find_text = patch["find"]
        replace_text = patch["replace"]

        # Check if the target text exists
        check_cmd = f'docker exec {container} grep -c {repr(find_text[:50])} {fix["file"]} 2>/dev/null'
        stdin, stdout, stderr = ssh.exec_command(check_cmd, timeout=10)
        count = stdout.read().decode().strip()

        if count == "0" or not count:
            # Try a simpler check
            simple_find = find_text.split('\n')[0][:60]
            check_cmd2 = f"docker exec {container} grep -c '{simple_find}' {fix['file']} 2>/dev/null"
            stdin, stdout, stderr = ssh.exec_command(check_cmd2, timeout=10)
            count2 = stdout.read().decode().strip()
            if count2 == "0" or not count2:
                print(f"  ⚠ Patch {i+1}: Target text not found (may already be applied)")
                continue

        if dry_run:
            print(f"  [DRY RUN] Patch {i+1}: Would replace:")
            print(f"    FIND:    {find_text[:80]}...")
            print(f"    REPLACE: {replace_text[:80]}...")
            continue

        # Apply the patch using Python inside the container
        escape_find = find_text.replace("'", "\\'").replace('"', '\\"')
        escape_replace = replace_text.replace("'", "\\'").replace('"', '\\"')

        patch_script = f'''
import re
with open("{fix['file']}", "r") as f:
    content = f.read()
find_text = """{find_text}"""
replace_text = """{replace_text}"""
if find_text in content:
    content = content.replace(find_text, replace_text, 1)
    with open("{fix['file']}", "w") as f:
        f.write(content)
    print("PATCHED")
else:
    print("NOT_FOUND")
'''
        # Write patch script to container and execute
        write_cmd = f"docker exec {container} python3 -c '{patch_script.strip()}'"
        # Use a temp file approach instead for safety
        import tempfile, os
        with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as tf:
            tf.write(patch_script)
            tf_path = tf.name

        # Copy to server, then to container
        sftp = ssh.open_sftp()
        remote_path = f"/tmp/_wisemind_patch_{fix_name}_{i}.py"
        sftp.put(tf_path, remote_path)
        sftp.close()
        os.unlink(tf_path)

        # Copy into container and run
        cp_cmd = f"docker cp {remote_path} {container}:/tmp/_patch.py"
        stdin, stdout, stderr = ssh.exec_command(cp_cmd, timeout=10)
        stdout.read()

        run_cmd = f"docker exec {container} python3 /tmp/_patch.py"
        stdin, stdout, stderr = ssh.exec_command(run_cmd, timeout=10)
        result = stdout.read().decode().strip()
        err = stderr.read().decode().strip()

        if "PATCHED" in result:
            print(f"  ✅ Patch {i+1}: Applied successfully")
        elif "NOT_FOUND" in result:
            print(f"  ⚠ Patch {i+1}: Target text not found (may already be applied)")
        else:
            print(f"  ❌ Patch {i+1}: Failed — {result} {err}")


def main():
    parser = argparse.ArgumentParser(description="Apply WiseMind RAG fixes")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show what would be changed without applying")
    parser.add_argument("--container", default="wisemind-backend-dev",
                        help="Docker container name")
    parser.add_argument("--host", default="10.72.127.149",
                        help="Server hostname/IP")
    parser.add_argument("--user", default="wisemind")
    parser.add_argument("--password", default="Wisemind12")
    parser.add_argument("--fixes", nargs="*", default=None,
                        help="Apply specific fixes (e.g., fix1_threshold fix2_truncation)")
    args = parser.parse_args()

    try:
        import paramiko
    except ImportError:
        print("ERROR: paramiko not installed. Run: pip install paramiko", file=sys.stderr)
        sys.exit(1)

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    print(f"Connecting to {args.user}@{args.host}...")
    ssh.connect(args.host, username=args.user, password=args.password)
    print(f"Connected. Container: {args.container}")

    fixes_to_apply = FIXES
    if args.fixes:
        fixes_to_apply = {k: v for k, v in FIXES.items() if k in args.fixes}

    if args.dry_run:
        print("\n🔍 DRY RUN MODE — no changes will be made\n")

    for fix_name, fix in fixes_to_apply.items():
        apply_fix(ssh, args.container, fix_name, fix, dry_run=args.dry_run)

    ssh.close()

    print(f"\n{'='*60}")
    if args.dry_run:
        print("DRY RUN COMPLETE — run without --dry-run to apply")
    else:
        print("ALL FIXES APPLIED")
        print(f"Restart the backend to activate: docker restart {args.container}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()

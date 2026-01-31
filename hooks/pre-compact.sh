#!/bin/bash
#
# PreCompact Hook - Auto-export, convert, and AUTOMATICALLY extract learnings
#
# This hook fires when Claude Code is about to compact the context window.
# It preserves the full session by:
# 1. Exporting the raw JSONL transcript
# 2. Converting to readable markdown
# 3. Spawning a BACKGROUND Claude process to extract and store learnings
#
# IMPORTANT: This is TRULY automatic - no reliance on Claude "seeing instructions"
#
# Install: cp pre-compact.sh ~/.claude/hooks/PreCompact.sh
#          chmod +x ~/.claude/hooks/PreCompact.sh

set -euo pipefail

# Configuration
DAEMON_HOST="${CLAUDE_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
TRANSCRIPTS_DIR="${HOME}/.claude/transcripts"
EXTRACTION_LOG_DIR="${HOME}/.claude/extraction-logs"

# Read input from stdin
INPUT=$(cat)

# Extract session info
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sessionId','unknown'))" 2>/dev/null || echo "unknown")
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcriptPath',''))" 2>/dev/null || echo "")
PROJECT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    echo "No transcript found, skipping" >&2
    exit 0
fi

# Create output directories
SESSION_DIR="${TRANSCRIPTS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR"
mkdir -p "$EXTRACTION_LOG_DIR"

# 1. Copy raw transcript
cp "$TRANSCRIPT_PATH" "${SESSION_DIR}/transcript.jsonl"
echo "✓ Exported transcript to ${SESSION_DIR}" >&2

# 2. Convert to markdown
python3 - "$SESSION_DIR" << 'CONVERT_SCRIPT'
import json
import sys
from pathlib import Path
from datetime import datetime

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
jsonl_path = session_dir / "transcript.jsonl"
md_path = session_dir / "transcript.md"

messages = []
session_id = session_dir.name
project_path = ""

with open(jsonl_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)

            if entry.get('sessionId'):
                session_id = entry['sessionId']
            if entry.get('cwd'):
                project_path = entry['cwd']

            role = entry.get('type') or entry.get('role')

            if role == 'user':
                content = entry.get('message', {}).get('content') or entry.get('content') or entry.get('text') or ''
                if isinstance(content, str) and content.strip():
                    messages.append({'role': 'user', 'content': content})

            elif role == 'assistant':
                assistant_content = ''
                thinking_content = ''

                content = entry.get('message', {}).get('content') or entry.get('content')

                if isinstance(content, list):
                    for block in content:
                        if block.get('type') == 'thinking':
                            thinking_content += block.get('thinking', '')
                        elif block.get('type') == 'text':
                            assistant_content += block.get('text', '')
                elif isinstance(content, str):
                    assistant_content = content

                if entry.get('thinking'):
                    thinking_content = entry['thinking']

                if thinking_content.strip() or assistant_content.strip():
                    messages.append({
                        'role': 'assistant',
                        'thinking': thinking_content.strip() or None,
                        'content': assistant_content.strip()
                    })

        except json.JSONDecodeError:
            continue

# Write markdown
with open(md_path, 'w') as f:
    f.write(f"# Session Transcript\n\n")
    f.write(f"**Session ID**: {session_id}\n")
    f.write(f"**Project**: {project_path}\n")
    f.write(f"**Exported**: {datetime.now().isoformat()}\n\n")
    f.write("---\n\n")

    for msg in messages:
        if msg['role'] == 'user':
            f.write(f"## User\n\n{msg['content']}\n\n")
        elif msg['role'] == 'assistant':
            f.write("## Assistant\n\n")
            if msg.get('thinking'):
                f.write(f"<thinking>\n{msg['thinking']}\n</thinking>\n\n")
            if msg.get('content'):
                f.write(f"{msg['content']}\n\n")
        f.write("---\n\n")

print(f"Converted {len(messages)} messages", file=sys.stderr)
CONVERT_SCRIPT

echo "✓ Converted to markdown" >&2

# 3. Write metadata
cat > "${SESSION_DIR}/metadata.json" << METADATA
{
    "session_id": "${SESSION_ID}",
    "project_path": "${PROJECT_PATH}",
    "exported_at": "$(date -Iseconds)",
    "transcript_path": "${SESSION_DIR}/transcript.md",
    "daemon_url": "${DAEMON_URL}",
    "status": "extraction_started"
}
METADATA

# 4. Check if daemon is available before attempting extraction
if ! curl -s --max-time 2 "${DAEMON_URL}/health" > /dev/null 2>&1; then
    echo "⚠️  Memory daemon not available at ${DAEMON_URL}, skipping extraction" >&2
    # Update metadata to reflect skipped extraction
    python3 -c "
import json
with open('${SESSION_DIR}/metadata.json', 'r+') as f:
    data = json.load(f)
    data['status'] = 'extraction_skipped_daemon_unavailable'
    f.seek(0)
    json.dump(data, f, indent=2)
    f.truncate()
"
    exit 0
fi

echo "✓ Daemon available, spawning background extraction" >&2

# 5. Create the extraction prompt
EXTRACTION_PROMPT=$(cat << 'PROMPT_END'
You are a learning extractor. Read the transcript and extract valuable learnings to store in a semantic memory database.

TRANSCRIPT PATH: __TRANSCRIPT_PATH__
SESSION ID: __SESSION_ID__
DAEMON URL: __DAEMON_URL__

INSTRUCTIONS:
1. Read the transcript file
2. Identify valuable learnings (see types below)
3. For EACH learning, store it by running a curl command to the daemon

LEARNING TYPES:
- WORKING_SOLUTION: Commands, code, or approaches that worked
- GOTCHA: Traps, counterintuitive behaviors, "watch out for this"
- PATTERN: Recurring architectural decisions or workflows
- DECISION: Explicit design choices with reasoning
- FAILURE: What didn't work and why
- PREFERENCE: User's stated preferences

STORAGE FORMAT (run this for each learning):
curl -X POST __DAEMON_URL__/store -H "Content-Type: application/json" -d '{"type": "TYPE", "content": "the learning content", "context": "brief context", "confidence": 0.9, "session_source": "__SESSION_ID__"}'

RULES:
- Be specific - include actual commands, paths, error messages
- Confidence 0.95+ for explicitly confirmed, 0.85+ for strong evidence
- Skip generic programming knowledge
- Skip incomplete thoughts and debugging noise
- Focus on user-specific infrastructure, preferences, workflows
- Extract 5-15 learnings per session (quality over quantity)

After extraction, update the metadata file status to "extraction_complete".

START by reading the transcript, then extract and store learnings.
PROMPT_END
)

# Replace placeholders
EXTRACTION_PROMPT="${EXTRACTION_PROMPT//__TRANSCRIPT_PATH__/${SESSION_DIR}/transcript.md}"
EXTRACTION_PROMPT="${EXTRACTION_PROMPT//__SESSION_ID__/${SESSION_ID}}"
EXTRACTION_PROMPT="${EXTRACTION_PROMPT//__DAEMON_URL__/${DAEMON_URL}}"

# 6. Spawn background Claude process for extraction
# Use nohup to ensure it survives the hook completing
LOG_FILE="${EXTRACTION_LOG_DIR}/${SESSION_ID}-$(date +%Y%m%d-%H%M%S).log"

(
    echo "=== Extraction started at $(date) ===" >> "$LOG_FILE"
    echo "Session: ${SESSION_ID}" >> "$LOG_FILE"
    echo "Transcript: ${SESSION_DIR}/transcript.md" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"

    # Run Claude in print mode with the extraction prompt
    # --dangerously-skip-permissions allows curl commands without prompts
    # --allowedTools restricts to only what's needed
    if claude -p \
        --allowedTools "Bash(curl:*) Read" \
        --dangerously-skip-permissions \
        "$EXTRACTION_PROMPT" >> "$LOG_FILE" 2>&1; then

        echo "" >> "$LOG_FILE"
        echo "=== Extraction completed successfully at $(date) ===" >> "$LOG_FILE"

        # Update metadata
        python3 -c "
import json
try:
    with open('${SESSION_DIR}/metadata.json', 'r+') as f:
        data = json.load(f)
        data['status'] = 'extraction_complete'
        data['extraction_log'] = '$LOG_FILE'
        f.seek(0)
        json.dump(data, f, indent=2)
        f.truncate()
except Exception as e:
    print(f'Failed to update metadata: {e}')
"
    else
        echo "" >> "$LOG_FILE"
        echo "=== Extraction FAILED at $(date) ===" >> "$LOG_FILE"

        # Update metadata with failure
        python3 -c "
import json
try:
    with open('${SESSION_DIR}/metadata.json', 'r+') as f:
        data = json.load(f)
        data['status'] = 'extraction_failed'
        data['extraction_log'] = '$LOG_FILE'
        f.seek(0)
        json.dump(data, f, indent=2)
        f.truncate()
except Exception as e:
    print(f'Failed to update metadata: {e}')
"
    fi
) &

# Disown the background process so it's not killed when hook exits
disown

echo "✓ Background extraction spawned (log: ${LOG_FILE})" >&2
echo "" >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "PreCompact: Transcript exported and extraction running in background" >&2
echo "═══════════════════════════════════════════════════════════════" >&2

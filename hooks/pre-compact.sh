#!/bin/bash
#
# PreCompact Hook - Auto-export, convert, chunk, and embed transcripts
#
# This hook fires when Claude Code is about to compact the context window.
# It preserves the full session by:
# 1. Exporting the raw JSONL transcript
# 2. Converting to readable markdown
# 3. Chunking the transcript into segments
# 4. Embedding each chunk for future semantic search
#
# This enables "fork detection" - finding past sessions that dealt with
# similar problems so you can resume from relevant context.
#
# Install: cp pre-compact.sh ~/.claude/hooks/PreCompact.sh
#          chmod +x ~/.claude/hooks/PreCompact.sh

set -euo pipefail

# Configuration
DAEMON_HOST="${CLAUDE_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
TRANSCRIPTS_DIR="${HOME}/.claude/transcripts"
CHUNK_SIZE=4000  # ~4KB chunks to fit in embedding context

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

# Create output directory
SESSION_DIR="${TRANSCRIPTS_DIR}/${SESSION_ID}"
mkdir -p "$SESSION_DIR"

# 1. Copy raw transcript
cp "$TRANSCRIPT_PATH" "${SESSION_DIR}/transcript.jsonl"
echo "✓ Exported transcript" >&2

# 2. Convert to markdown
python3 << 'CONVERT_SCRIPT'
import json
import sys
from pathlib import Path
from datetime import datetime

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
jsonl_path = session_dir / "transcript.jsonl"
md_path = session_dir / "transcript.md"

messages = []
session_id = "unknown"
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
            f.write(f"## 👤 User\n\n{msg['content']}\n\n")
        elif msg['role'] == 'assistant':
            f.write("## 🤖 Assistant\n\n")
            if msg.get('thinking'):
                f.write(f"<details>\n<summary>💭 Thinking</summary>\n\n{msg['thinking']}\n\n</details>\n\n")
            if msg.get('content'):
                f.write(f"{msg['content']}\n\n")
        f.write("---\n\n")

print(f"Converted {len(messages)} messages", file=sys.stderr)
CONVERT_SCRIPT
echo "✓ Converted to markdown" >&2

# 3. Chunk the transcript
python3 << 'CHUNK_SCRIPT'
import json
import sys
from pathlib import Path

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
md_path = session_dir / "transcript.md"
chunks_path = session_dir / "chunks.json"
chunk_size = int(sys.argv[2]) if len(sys.argv) > 2 else 4000

content = md_path.read_text()

# Split by message boundaries (---) first, then by size
sections = content.split("\n---\n")
chunks = []
current_chunk = ""

for section in sections:
    section = section.strip()
    if not section:
        continue
    
    # If adding this section would exceed chunk size, save current and start new
    if len(current_chunk) + len(section) > chunk_size and current_chunk:
        chunks.append(current_chunk.strip())
        current_chunk = section
    else:
        current_chunk += "\n---\n" + section if current_chunk else section

# Don't forget the last chunk
if current_chunk.strip():
    chunks.append(current_chunk.strip())

# Save chunks
with open(chunks_path, 'w') as f:
    json.dump({
        'session_id': session_dir.name,
        'chunk_count': len(chunks),
        'chunks': chunks
    }, f, indent=2)

print(f"Created {len(chunks)} chunks", file=sys.stderr)
CHUNK_SCRIPT
echo "✓ Chunked transcript" >&2

# 4. Embed chunks and store in daemon
python3 << 'EMBED_SCRIPT'
import json
import sys
import requests
from pathlib import Path

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
daemon_url = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1:8741"
chunks_path = session_dir / "chunks.json"

# Check daemon health
try:
    resp = requests.get(f"{daemon_url}/health", timeout=2)
    if resp.status_code != 200:
        print("Daemon not healthy, skipping embedding", file=sys.stderr)
        sys.exit(0)
except:
    print("Daemon not reachable, skipping embedding", file=sys.stderr)
    sys.exit(0)

# Load chunks
with open(chunks_path) as f:
    data = json.load(f)

session_id = data['session_id']
chunks = data['chunks']

# Store each chunk
stored = 0
for i, chunk in enumerate(chunks):
    try:
        resp = requests.post(
            f"{daemon_url}/chunks/store",
            json={
                'session_id': session_id,
                'chunk_index': i,
                'content': chunk
            },
            timeout=10
        )
        if resp.status_code == 200:
            stored += 1
    except Exception as e:
        print(f"Failed to store chunk {i}: {e}", file=sys.stderr)

print(f"Embedded {stored}/{len(chunks)} chunks", file=sys.stderr)
EMBED_SCRIPT
echo "✓ Embedded chunks" >&2

# 5. Write metadata
python3 << 'META_SCRIPT'
import json
import sys
from pathlib import Path
from datetime import datetime

session_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
session_id = sys.argv[2] if len(sys.argv) > 2 else "unknown"
project_path = sys.argv[3] if len(sys.argv) > 3 else ""

chunks_path = session_dir / "chunks.json"
chunk_count = 0
if chunks_path.exists():
    with open(chunks_path) as f:
        chunk_count = json.load(f).get('chunk_count', 0)

metadata = {
    'session_id': session_id,
    'project_path': project_path,
    'compacted_at': datetime.now().isoformat(),
    'chunk_count': chunk_count,
    'files': ['transcript.jsonl', 'transcript.md', 'chunks.json']
}

with open(session_dir / "metadata.json", 'w') as f:
    json.dump(metadata, f, indent=2)

print(f"Wrote metadata", file=sys.stderr)
META_SCRIPT
echo "✓ Wrote metadata" >&2

echo "" >&2
echo "Session preserved to: ${SESSION_DIR}" >&2

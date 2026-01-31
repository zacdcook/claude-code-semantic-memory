#!/bin/bash
#
# PreToolUse Hook - Injects relevant memories during Claude's iteration
#
# This hook fires before every tool invocation. It:
# 1. Extracts Claude's thinking block (most recent reasoning)
# 2. Queries the memory daemon for relevant learnings
# 3. Injects matches to help Claude mid-task
#
# This catches context drift - when Claude's thinking has moved away
# from the original prompt, new relevant memories may surface.
#
# Install: cp pre-tool-use.sh ~/.claude/hooks/PreToolUse.sh
#          chmod +x ~/.claude/hooks/PreToolUse.sh

set -euo pipefail

# Configuration
DAEMON_HOST="${CLAUDE_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
HEALTH_TIMEOUT=0.5
RECALL_TIMEOUT=2.5
STATE_FILE="${HOME}/.claude/memory-injection-state.json"

# Read input from stdin
INPUT=$(cat)

# Only inject on read-only tools (don't slow down writes)
TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('toolName',''))" 2>/dev/null || echo "")

case "$TOOL_NAME" in
    Read|Grep|Glob|Task|WebSearch|WebFetch)
        # Continue with memory injection
        ;;
    *)
        # Skip memory injection for write tools
        exit 0
        ;;
esac

# Extract session ID
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sessionId',''))" 2>/dev/null || echo "unknown")

# Extract thinking block from the conversation
# Priority: thinking block > assistant message
# Use last 8000 chars (most recent reasoning)
THINKING=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    messages = data.get('messages', [])
    
    # Find the last assistant message
    for msg in reversed(messages):
        if msg.get('role') == 'assistant':
            content = msg.get('content', [])
            if isinstance(content, list):
                # Look for thinking block first
                for block in content:
                    if block.get('type') == 'thinking':
                        text = block.get('thinking', '')
                        print(text[-8000:] if len(text) > 8000 else text)
                        sys.exit(0)
                # Fall back to text content
                for block in content:
                    if block.get('type') == 'text':
                        text = block.get('text', '')
                        print(text[-8000:] if len(text) > 8000 else text)
                        sys.exit(0)
            elif isinstance(content, str):
                print(content[-8000:] if len(content) > 8000 else content)
                sys.exit(0)
            break
except:
    pass
" 2>/dev/null || echo "")

if [ -z "$THINKING" ]; then
    exit 0
fi

# Hash-based deduplication: don't re-query if thinking hasn't changed
THINKING_HASH=$(echo "$THINKING" | md5sum | cut -d' ' -f1)

if [ -f "$STATE_FILE" ]; then
    # Use environment variables to safely pass values to Python
    LAST_HASH=$(STATE_FILE="$STATE_FILE" SESSION_ID="$SESSION_ID" python3 -c "
import json, os
try:
    with open(os.environ['STATE_FILE']) as f:
        state = json.load(f)
    print(state.get(os.environ['SESSION_ID'], {}).get('hash', ''))
except:
    print('')
" 2>/dev/null || echo "")
    
    if [ "$THINKING_HASH" = "$LAST_HASH" ]; then
        # Same thinking, skip re-query
        exit 0
    fi
fi

# Check daemon health (quick timeout)
if ! curl -s --max-time "$HEALTH_TIMEOUT" "${DAEMON_URL}/health" > /dev/null 2>&1; then
    exit 0
fi

# Query for relevant memories based on thinking
RESPONSE=$(curl -s --max-time "$RECALL_TIMEOUT" \
    -X POST "${DAEMON_URL}/recall" \
    -H "Content-Type: application/json" \
    -d "{\"query\": $(echo "$THINKING" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")}" 2>/dev/null || echo '{"memories":[]}')

# Extract memories
MEMORIES=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    memories = data.get('memories', [])
    print(json.dumps(memories))
except:
    print('[]')
" 2>/dev/null || echo "[]")

COUNT=$(echo "$MEMORIES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

# Update state file with new hash - use environment variables for safe passing
mkdir -p "$(dirname "$STATE_FILE")"
STATE_FILE="$STATE_FILE" SESSION_ID="$SESSION_ID" THINKING_HASH="$THINKING_HASH" python3 -c "
import json, os
state_file = os.environ['STATE_FILE']
session_id = os.environ['SESSION_ID']
thinking_hash = os.environ['THINKING_HASH']
try:
    with open(state_file) as f:
        state = json.load(f)
except:
    state = {}

state[session_id] = {'hash': thinking_hash}

with open(state_file, 'w') as f:
    json.dump(state, f)
" 2>/dev/null || true

if [ "$COUNT" -eq 0 ] || [ "$MEMORIES" = "null" ] || [ "$MEMORIES" = "[]" ]; then
    exit 0
fi

# Format as XML for injection
# IMPORTANT: Use stdin to pass JSON - shell interpolation breaks on special chars
FORMATTED=$(echo "$MEMORIES" | python3 -c "
import sys, json
memories = json.load(sys.stdin)
print('<recalled-learnings source=\"thinking-injection\">')
for m in memories:
    mtype = m.get('type', 'UNKNOWN')
    sim = m.get('similarity', 0)
    content = m.get('content', '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    print(f'<memory type=\"{mtype}\" similarity=\"{sim}\">{content}</memory>')
print('</recalled-learnings>')
" 2>/dev/null || echo "")

if [ -z "$FORMATTED" ]; then
    exit 0
fi

# Output for Claude Code hook system
# CRITICAL: hookEventName is REQUIRED for additionalContext to be processed by Claude Code
# IMPORTANT: Use stdin to pass formatted content - shell interpolation breaks on special chars
echo "$FORMATTED" | python3 -c "
import sys, json
formatted = sys.stdin.read()
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'additionalContext': formatted
    }
}))
"

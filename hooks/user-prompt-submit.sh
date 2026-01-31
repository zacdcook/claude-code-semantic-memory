#!/bin/bash
#
# UserPromptSubmit Hook - Injects relevant memories on every prompt
#
# This hook fires mechanically on every user message. It:
# 1. Extracts the user's prompt
# 2. Queries the memory daemon for relevant learnings
# 3. Injects matches as XML into Claude's context
#
# Install: cp user-prompt-submit.sh ~/.claude/hooks/UserPromptSubmit.sh
#          chmod +x ~/.claude/hooks/UserPromptSubmit.sh

set -euo pipefail

# Configuration
DAEMON_HOST="${CLAUDE_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
HEALTH_TIMEOUT=0.5
RECALL_TIMEOUT=2

# Read input from stdin
INPUT=$(cat)

# FIXED: Claude Code sends "prompt" not "userPrompt"
QUERY=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

if [ -z "$QUERY" ]; then
    exit 0
fi

# Check daemon health (quick timeout)
if ! curl -s --max-time "$HEALTH_TIMEOUT" "${DAEMON_URL}/health" > /dev/null 2>&1; then
    # Daemon not available, continue without memory
    exit 0
fi

# Query for relevant memories
RESPONSE=$(curl -s --max-time "$RECALL_TIMEOUT" \
    -X POST "${DAEMON_URL}/recall" \
    -H "Content-Type: application/json" \
    -d "{\"query\": $(echo "$QUERY" | jq -Rs .)}" 2>/dev/null || echo '{"memories":[]}')

# Extract memories
MEMORIES=$(echo "$RESPONSE" | jq -r '.memories // []')
COUNT=$(echo "$MEMORIES" | jq 'length')

if [ "$COUNT" -eq 0 ] || [ "$MEMORIES" = "null" ]; then
    exit 0
fi

# Format as XML for injection
format_memories() {
    echo "<recalled-learnings>"
    echo "$MEMORIES" | jq -r '.[] | "<memory type=\"\(.type)\" similarity=\"\(.similarity)\">\(.content)</memory>"'
    echo "</recalled-learnings>"
}

FORMATTED=$(format_memories)

# Output for Claude Code hook system
# CRITICAL: hookEventName is REQUIRED for additionalContext to be processed by Claude Code
jq -n --arg ctx "$FORMATTED" '{
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": $ctx
    }
}'

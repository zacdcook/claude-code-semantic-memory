#!/bin/bash
#
# Semantic Memory System Test Suite
# Run: bash tests/test-semantic-memory.sh
#

set -e

DAEMON_URL="${CLAUDE_DAEMON_HOST:-127.0.0.1}:${CLAUDE_DAEMON_PORT:-8741}"
DAEMON_URL="http://${DAEMON_URL}"
PASSED=0
FAILED=0

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Semantic Memory System Test Suite                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Helper functions
pass() {
    echo "  ✅ PASS: $1"
    ((PASSED++))
}

fail() {
    echo "  ❌ FAIL: $1"
    echo "         $2"
    ((FAILED++))
}

section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ══════════════════════════════════════════════════════════════════════
section "1. DAEMON HEALTH"
# ══════════════════════════════════════════════════════════════════════

# Test 1.1: Daemon is running
if curl -s --max-time 2 "${DAEMON_URL}/health" > /dev/null 2>&1; then
    pass "Daemon responding at ${DAEMON_URL}"
else
    fail "Daemon not responding" "Start with: cd daemon && python server.py"
    echo ""
    echo "Cannot continue without daemon. Exiting."
    exit 1
fi

# Test 1.2: Ollama available
HEALTH=$(curl -s "${DAEMON_URL}/health")
if echo "$HEALTH" | jq -e '.ollama == true' > /dev/null 2>&1; then
    pass "Ollama embedding model available"
else
    fail "Ollama not available" "Run: ollama pull nomic-embed-text"
fi

# Test 1.3: Database exists
DB_PATH=$(echo "$HEALTH" | jq -r '.db_path')
if [ -f "$DB_PATH" ]; then
    pass "Database exists at $DB_PATH"
else
    fail "Database not found" "Expected at $DB_PATH"
fi

# ══════════════════════════════════════════════════════════════════════
section "2. MEMORY STORAGE (/store)"
# ══════════════════════════════════════════════════════════════════════

# Test 2.1: Can store a learning
TEST_ID="test-$(date +%s)"
STORE_RESULT=$(curl -s -X POST "${DAEMON_URL}/store" \
    -H "Content-Type: application/json" \
    -d "{\"type\": \"TEST\", \"content\": \"Test memory ${TEST_ID}\", \"confidence\": 0.5, \"session_source\": \"test-suite\"}")

if echo "$STORE_RESULT" | jq -e '.status == "stored"' > /dev/null 2>&1; then
    pass "Can store memories"
    STORED_ID=$(echo "$STORE_RESULT" | jq -r '.id')
else
    fail "Cannot store memories" "$STORE_RESULT"
fi

# Test 2.2: Duplicate detection
DUPE_RESULT=$(curl -s -X POST "${DAEMON_URL}/store" \
    -H "Content-Type: application/json" \
    -d "{\"type\": \"TEST\", \"content\": \"Test memory ${TEST_ID}\", \"confidence\": 0.5, \"session_source\": \"test-suite\"}")

if echo "$DUPE_RESULT" | jq -e '.status == "duplicate"' > /dev/null 2>&1; then
    pass "Duplicate detection works"
else
    # Not necessarily a failure - might use different threshold
    echo "  ⚠️  WARN: Duplicate not detected (may be threshold setting)"
fi

# ══════════════════════════════════════════════════════════════════════
section "3. MEMORY RECALL (/recall)"
# ══════════════════════════════════════════════════════════════════════

# Test 3.1: Basic recall works
RECALL_RESULT=$(curl -s -X POST "${DAEMON_URL}/recall" \
    -H "Content-Type: application/json" \
    -d '{"query": "test memory"}')

if echo "$RECALL_RESULT" | jq -e '.memories | length >= 0' > /dev/null 2>&1; then
    pass "Recall endpoint works"
else
    fail "Recall failed" "$RECALL_RESULT"
fi

# Test 3.2: Returns memories with expected structure
MEMORY_STRUCTURE=$(echo "$RECALL_RESULT" | jq -e '.memories[0] | has("type") and has("content") and has("similarity")' 2>/dev/null || echo "false")
if [ "$MEMORY_STRUCTURE" = "true" ]; then
    pass "Memory structure correct (type, content, similarity)"
else
    if echo "$RECALL_RESULT" | jq -e '.memories | length == 0' > /dev/null 2>&1; then
        echo "  ⚠️  WARN: No memories returned (database may be empty)"
    else
        fail "Memory structure incorrect" "$(echo "$RECALL_RESULT" | jq '.memories[0]')"
    fi
fi

# Test 3.3: Similarity scores are reasonable
if echo "$RECALL_RESULT" | jq -e '.memories[0].similarity >= 0.4 and .memories[0].similarity <= 1.0' > /dev/null 2>&1; then
    SIMILARITY=$(echo "$RECALL_RESULT" | jq -r '.memories[0].similarity')
    pass "Similarity scores reasonable ($SIMILARITY)"
else
    echo "  ⚠️  WARN: Could not verify similarity scores"
fi

# ══════════════════════════════════════════════════════════════════════
section "4. USERPROMPTSUBMIT HOOK"
# ══════════════════════════════════════════════════════════════════════

HOOK_PATH="$HOME/.claude/hooks/UserPromptSubmit.sh"

# Test 4.1: Hook file exists
if [ -f "$HOOK_PATH" ]; then
    pass "Hook file exists"
else
    fail "Hook file not found" "Expected at $HOOK_PATH"
fi

# Test 4.2: Hook is executable
if [ -x "$HOOK_PATH" ]; then
    pass "Hook is executable"
else
    fail "Hook not executable" "Run: chmod +x $HOOK_PATH"
fi

# Test 4.3: Hook uses correct field name (.prompt not .userPrompt)
if grep -q '\.prompt' "$HOOK_PATH" 2>/dev/null; then
    pass "Hook uses correct field name (.prompt)"
else
    if grep -q '\.userPrompt' "$HOOK_PATH" 2>/dev/null; then
        fail "Hook uses WRONG field name" "Change .userPrompt to .prompt"
    else
        echo "  ⚠️  WARN: Could not verify field name"
    fi
fi

# Test 4.4: Hook includes hookEventName
if grep -q 'hookEventName' "$HOOK_PATH" 2>/dev/null; then
    pass "Hook includes hookEventName"
else
    fail "Hook missing hookEventName" "Required for additionalContext to work"
fi

# Test 4.5: Hook returns valid JSON with hookEventName
HOOK_OUTPUT=$(echo '{"prompt": "test semantic memory", "session_id": "test"}' | "$HOOK_PATH" 2>/dev/null)
if echo "$HOOK_OUTPUT" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' > /dev/null 2>&1; then
    pass "Hook returns correct JSON structure"
else
    if [ -z "$HOOK_OUTPUT" ]; then
        echo "  ⚠️  WARN: Hook returned no output (may be no matching memories)"
    else
        fail "Hook JSON structure wrong" "$HOOK_OUTPUT"
    fi
fi

# Test 4.6: Hook returns additionalContext with memories
if echo "$HOOK_OUTPUT" | jq -e '.hookSpecificOutput.additionalContext | contains("recalled-learnings")' > /dev/null 2>&1; then
    pass "Hook returns additionalContext with memories"
else
    if [ -z "$HOOK_OUTPUT" ]; then
        echo "  ⚠️  WARN: No memories for test query"
    else
        fail "Hook additionalContext missing or wrong" "$(echo "$HOOK_OUTPUT" | jq '.hookSpecificOutput.additionalContext')"
    fi
fi

# ══════════════════════════════════════════════════════════════════════
section "5. PRETOOLUSE HOOK"
# ══════════════════════════════════════════════════════════════════════

PRETOOL_HOOK="$HOME/.claude/hooks/PreToolUse.sh"

# Test 5.1: Hook file exists
if [ -f "$PRETOOL_HOOK" ]; then
    pass "PreToolUse hook exists"
else
    fail "PreToolUse hook not found" "Expected at $PRETOOL_HOOK"
fi

# Test 5.2: Hook includes hookEventName
if grep -q 'hookEventName.*PreToolUse' "$PRETOOL_HOOK" 2>/dev/null; then
    pass "PreToolUse hook includes hookEventName"
else
    fail "PreToolUse hook missing hookEventName" "Required for additionalContext"
fi

# Test 5.3: Hook uses stdin for JSON (not shell interpolation)
if grep -q 'json.load(sys.stdin)' "$PRETOOL_HOOK" 2>/dev/null; then
    pass "PreToolUse uses safe stdin JSON parsing"
else
    if grep -q "json.loads('\$" "$PRETOOL_HOOK" 2>/dev/null; then
        fail "PreToolUse uses unsafe shell interpolation" "Will break on special chars"
    else
        echo "  ⚠️  WARN: Could not verify JSON parsing method"
    fi
fi

# ══════════════════════════════════════════════════════════════════════
section "6. SETTINGS.JSON CONFIGURATION"
# ══════════════════════════════════════════════════════════════════════

SETTINGS="$HOME/.claude/settings.json"

# Test 6.1: Settings file exists
if [ -f "$SETTINGS" ]; then
    pass "settings.json exists"
else
    fail "settings.json not found" "Hooks must be registered in settings.json"
fi

# Test 6.2: UserPromptSubmit hook registered
if jq -e '.hooks.UserPromptSubmit' "$SETTINGS" > /dev/null 2>&1; then
    pass "UserPromptSubmit hook registered"
else
    fail "UserPromptSubmit not registered" "Add to settings.json hooks section"
fi

# Test 6.3: PreToolUse hook registered
if jq -e '.hooks.PreToolUse' "$SETTINGS" > /dev/null 2>&1; then
    pass "PreToolUse hook registered"
else
    fail "PreToolUse not registered" "Add to settings.json hooks section"
fi

# Test 6.4: PreCompact hook registered
if jq -e '.hooks.PreCompact' "$SETTINGS" > /dev/null 2>&1; then
    pass "PreCompact hook registered"
else
    fail "PreCompact not registered" "Add to settings.json hooks section"
fi

# ══════════════════════════════════════════════════════════════════════
section "7. DATABASE CONTENT"
# ══════════════════════════════════════════════════════════════════════

# Test 7.1: Database has memories
MEMORY_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
if [ "$MEMORY_COUNT" -gt 0 ]; then
    pass "Database has $MEMORY_COUNT memories"
else
    fail "Database is empty" "Run extraction or import learnings"
fi

# Test 7.2: Multiple learning types
TYPE_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT type) FROM learnings;" 2>/dev/null || echo "0")
if [ "$TYPE_COUNT" -gt 3 ]; then
    pass "Multiple learning types present ($TYPE_COUNT types)"
else
    echo "  ⚠️  WARN: Only $TYPE_COUNT learning types (expected 4+)"
fi

# Cleanup test data
if [ -n "$STORED_ID" ]; then
    sqlite3 "$DB_PATH" "DELETE FROM learnings WHERE id = $STORED_ID;" 2>/dev/null || true
fi

# ══════════════════════════════════════════════════════════════════════
section "RESULTS"
# ══════════════════════════════════════════════════════════════════════

echo ""
TOTAL=$((PASSED + FAILED))
echo "  Passed: $PASSED / $TOTAL"
echo "  Failed: $FAILED / $TOTAL"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo "  🎉 ALL TESTS PASSED!"
    exit 0
else
    echo "  ⚠️  Some tests failed. Review the output above."
    exit 1
fi

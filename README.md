# Claude Code Semantic Memory System

A persistent memory system for Claude Code that extracts learnings from past sessions and injects relevant context on every prompt.

## The Problem

Claude Code sessions are stateless by default. Every time context compacts or you start a new session, Claude forgets:
- Solutions you already discovered together
- Gotchas and traps you identified
- Your infrastructure details and preferences
- Decisions you made and why

This leads to repeated mistakes, redundant conversations, and lost productivity.

## The Solution

This system gives Claude **persistent memory** across sessions:

1. **Convert** your `.jsonl` transcripts to readable markdown
2. **Extract** learnings using Claude sub-agents that process transcripts
3. **Embed** learnings with a local embedding model (nomic-embed-text)
4. **Inject** relevant memories via Claude Code hooks that fire on every prompt

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Your Prompt    │────►│  Hook Fires     │────►│  Query Daemon   │
│                 │     │  (mechanical)   │     │  (cosine sim)   │
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Claude sees    │◄────│  Inject as XML  │◄────│  Top 3 memories │
│  context + mem  │     │  in context     │     │  (≥0.45 sim)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

---

## Quick Start

### Prerequisites

- [Node.js](https://nodejs.org/) (for transcript conversion)
- [Ollama](https://ollama.com/) (for local embeddings)
- Python 3.8+ (for the memory daemon)
- Claude Code CLI

### 1. Install Dependencies

```bash
# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Pull the embedding model
ollama pull nomic-embed-text

# Clone this repo
git clone https://github.com/zacdcook/claude-code-semantic-memory.git
cd claude-code-semantic-memory
```

### 2. Convert Your Transcripts

Claude Code stores session transcripts as `.jsonl` files in `~/.claude/projects/`. Convert them to readable markdown:

```bash
node scripts/jsonl-to-markdown.js ~/.claude/projects/ ./converted-transcripts/
```

This extracts user messages, assistant messages (including thinking blocks), and system prompts. Tool calls and results are stripped for cleaner extraction.

### 3. Extract Learnings

Start a new Claude Code session and use the extraction prompt:

```bash
claude
```

Then paste the contents of `prompts/extract-learnings.md`. Claude will:

1. List all `.md` files in your converted transcripts folder
2. Dispatch sub-agents in parallel to process batches
3. Each sub-agent extracts structured learnings
4. Store learnings via the daemon's `/store` endpoint
5. Output to `~/extracted-learnings.jsonl`

### 4. Start the Memory Daemon

```bash
cd daemon
pip install -r requirements.txt
python server.py
```

The daemon runs on port 8741 and provides:
- `POST /store` - Embed and store a learning
- `POST /recall` - Query for relevant memories
- `GET /health` - Health check

### 5. Import Your Learnings

```bash
python scripts/import-learnings.py ~/extracted-learnings.jsonl
```

### 6. Install the Hooks

Copy all hooks to your Claude Code hooks directory:

```bash
# Session initialization
cp hooks/session-start.sh ~/.claude/hooks/SessionStart.sh

# Memory injection on prompts
cp hooks/user-prompt-submit.sh ~/.claude/hooks/UserPromptSubmit.sh

# Memory injection during iteration
cp hooks/pre-tool-use.sh ~/.claude/hooks/PreToolUse.sh

# Auto-export on compaction
cp hooks/pre-compact.sh ~/.claude/hooks/PreCompact.sh

# Make executable
chmod +x ~/.claude/hooks/*.sh
```

Now:
- Every prompt automatically queries memory and injects relevant learnings
- During iteration, Claude's thinking is analyzed for additional relevant memories
- When context compacts, the transcript is exported and a sub-agent extracts learnings

---

## Architecture

### Hook Lifecycle

```
SESSION START
════════════
┌─────────────────┐
│  SessionStart   │ → Check daemon health
│                 │ → Warn about orphaned transcripts
└────────┬────────┘
         │
ACTIVE WORK (repeats for each user message)
════════════
         ▼
┌─────────────────┐
│UserPromptSubmit │ → Embed user's prompt
│                 │ → Query daemon /recall
│                 │ → Inject top 3 memories
└────────┬────────┘
         │
         ▼  (fires before EACH tool)
┌─────────────────┐
│  PreToolUse     │ → Extract Claude's thinking
│                 │ → Query for new relevant memories
│                 │ → Inject if thinking has drifted
└────────┬────────┘
         │
CONTEXT COMPACTION (when context window fills)
════════════════════
         ▼
┌─────────────────┐
│  PreCompact     │ → Export transcript to disk
│                 │ → Convert JSONL to markdown
│                 │ → Output sub-agent dispatch instructions
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Sub-Agent      │ → Read exported transcript
│  (Task tool)    │ → Extract learnings
│                 │ → Store via daemon /store endpoint
└─────────────────┘
```

### Sub-Agent Extraction on Compaction

When context compacts, the PreCompact hook exports the transcript and outputs instructions for Claude to dispatch a sub-agent. The sub-agent:

1. Reads the exported markdown transcript
2. Extracts learnings (solutions, gotchas, patterns, etc.)
3. Stores each learning via the daemon's `/store` endpoint

This keeps everything within Claude Code - no external API calls needed. The sub-agent uses the Task tool to run without blocking.

### Learning Types

| Type | Description | Example |
|------|-------------|---------|
| `WORKING_SOLUTION` | Confirmed working commands/patterns | "Use `Import-Clixml` for PowerShell credentials over Tailscale" |
| `GOTCHA` | Traps and counterintuitive behaviors | "Git Bash strips `$` variables before PowerShell sees them" |
| `PATTERN` | Recurring architectural decisions | "Check HOSTNAME in hooks to determine daemon URL" |
| `DECISION` | Explicit design choices with reasoning | "Using nomic-embed-text for 8K token context" |
| `FAILURE` | What didn't work and why | "SSH-based PS remoting fails due to TTY requirements" |
| `PREFERENCE` | User's stated preferences | "Query memory before asking clarifying questions" |

### Why These Design Choices

| Decision | Why |
|----------|-----|
| **Hooks over CLAUDE.md** | Hooks fire deterministically; CLAUDE.md instructions are suggestions Claude may skip under cognitive load |
| **nomic-embed-text over MiniLM** | 8K token context vs 256 tokens — MiniLM truncates 75% of longer conversation turns |
| **0.45 similarity threshold** | Permissive enough to catch semantically related content, not so low it floods with noise |
| **Sub-agent extraction** | Uses Claude Code's own capabilities; no external API keys or local LLMs needed |

### Database Schema

```sql
CREATE TABLE learnings (
    id INTEGER PRIMARY KEY,
    type TEXT NOT NULL,
    content TEXT NOT NULL,
    context TEXT,
    embedding BLOB NOT NULL,
    confidence REAL DEFAULT 0.9,
    session_source TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_learnings_type ON learnings(type);
```

---

## File Structure

```
claude-code-semantic-memory/
├── README.md
├── scripts/
│   ├── jsonl-to-markdown.js    # Convert transcripts
│   └── import-learnings.py     # Import JSONL to database
├── prompts/
│   └── extract-learnings.md    # Prompt for sub-agent extraction
├── daemon/
│   ├── server.py               # Flask API server
│   ├── requirements.txt
│   └── config.json             # Similarity thresholds, model config
├── hooks/
│   ├── session-start.sh        # Check daemon, warn orphans
│   ├── user-prompt-submit.sh   # Memory injection on prompts
│   ├── pre-tool-use.sh         # Memory injection during iteration
│   └── pre-compact.sh          # Auto-export and dispatch sub-agent
└── examples/
    └── sample-learnings.jsonl  # Example output format
```

---

## Configuration

Edit `daemon/config.json`:

```json
{
  "embeddingModel": "nomic-embed-text",
  "minSimilarity": 0.45,
  "maxResults": 3,
  "duplicateThreshold": 0.92,
  "timeoutMs": 2500,
  "port": 8741
}
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `embeddingModel` | `nomic-embed-text` | Ollama model for embeddings (768 dimensions) |
| `minSimilarity` | `0.45` | Minimum cosine similarity to return a memory |
| `maxResults` | `3` | Maximum memories to inject per query |
| `duplicateThreshold` | `0.92` | Similarity threshold for deduplication |
| `timeoutMs` | `2500` | Max time to wait for embedding |
| `port` | `8741` | Daemon port |

---

## Advanced Usage

### Multi-Machine Setup

If you run Claude Code on a laptop but want embeddings on a GPU desktop:

1. Run the daemon on your desktop
2. Connect both machines via Tailscale (or any VPN)
3. Set `CLAUDE_DAEMON_HOST` environment variable on your laptop:

```bash
export CLAUDE_DAEMON_HOST=100.95.72.101  # Desktop's Tailscale IP
```

The hook will query the remote daemon instead of localhost.

---

## Troubleshooting

### Hook not firing
- Check hook is executable: `chmod +x ~/.claude/hooks/*.sh`
- Verify daemon is running: `curl http://localhost:8741/health`

### No memories returned
- Check similarity threshold isn't too high
- Verify learnings were imported: `curl http://localhost:8741/stats`
- Try a more specific query

### Slow embedding
- Ensure Ollama is using GPU: `ollama ps` should show CUDA
- Reduce batch sizes if running out of memory

---

## Credits

- [Ollama](https://ollama.com/) — Local embedding infrastructure
- [nomic-embed-text](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5) — Embedding model with 8K context

---

## License

MIT

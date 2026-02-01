#!/usr/bin/env python3
"""
Semantic Memory Daemon for Claude Code

A Flask server that provides:
- POST /store - Embed and store a learning
- POST /recall - Query for relevant memories by cosine similarity
- GET /health - Health check

Requires Ollama running with nomic-embed-text model.
"""

import json
import sqlite3
import time
from pathlib import Path
from flask import Flask, request, jsonify
import numpy as np
import requests

app = Flask(__name__)

# Load config
CONFIG_PATH = Path(__file__).parent / "config.json"
with open(CONFIG_PATH) as f:
    CONFIG = json.load(f)

DB_PATH = Path(__file__).parent / "semantic-memory.db"
OLLAMA_URL = "http://localhost:11434/api/embeddings"

def migrate_db():
    """Add new columns to existing database if needed."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    # Get existing columns
    cursor.execute("PRAGMA table_info(learnings)")
    existing_cols = {row[1] for row in cursor.fetchall()}

    # New columns to add (column_name, type, default)
    new_columns = [
        ("source_type", "TEXT", None),
        ("scope", "TEXT", None),
        ("tags", "TEXT", None),
        ("related_files", "TEXT", None),
        ("verified_at", "TIMESTAMP", None),
        ("superseded_by", "INTEGER", None),
        ("contradiction_count", "INTEGER", "0"),
        ("derived_from", "INTEGER", None),
    ]

    for col_name, col_type, default in new_columns:
        if col_name not in existing_cols:
            default_clause = f" DEFAULT {default}" if default else ""
            cursor.execute(f"ALTER TABLE learnings ADD COLUMN {col_name} {col_type}{default_clause}")
            print(f"  Added column: {col_name}")

    conn.commit()
    conn.close()

def init_db():
    """Initialize the database schema."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Learnings table - curated, distilled knowledge
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS learnings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            type TEXT NOT NULL,
            content TEXT NOT NULL,
            context TEXT,
            embedding BLOB NOT NULL,
            confidence REAL DEFAULT 0.9,
            session_source TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            -- Metadata for trust decisions
            source_type TEXT,           -- user_explicit, user_preference, observed, inferred
            scope TEXT,                 -- permanent, may_change, temporary
            tags TEXT,                  -- JSON array of categories
            related_files TEXT,         -- JSON array of file paths
            -- Future: lifecycle tracking
            verified_at TIMESTAMP,
            superseded_by INTEGER,
            contradiction_count INTEGER DEFAULT 0,
            derived_from INTEGER
        )
    """)
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_learnings_type ON learnings(type)")
    
    conn.commit()
    conn.close()

def embed(text: str) -> list[float]:
    """Generate embedding using Ollama."""
    try:
        resp = requests.post(
            OLLAMA_URL,
            json={"model": CONFIG["embeddingModel"], "prompt": text},
            timeout=CONFIG["timeoutMs"] / 1000
        )
        resp.raise_for_status()
        return resp.json()["embedding"]
    except Exception as e:
        raise RuntimeError(f"Embedding failed: {e}")

def cosine_similarity(a: list[float], b: list[float]) -> float:
    """Calculate cosine similarity between two vectors."""
    a_np = np.array(a)
    b_np = np.array(b)
    return float(np.dot(a_np, b_np) / (np.linalg.norm(a_np) * np.linalg.norm(b_np)))

@app.route("/health", methods=["GET"])
def health():
    """Health check endpoint."""
    try:
        # Check Ollama is running
        resp = requests.get("http://localhost:11434/api/tags", timeout=2)
        ollama_ok = resp.status_code == 200
    except:
        ollama_ok = False
    
    return jsonify({
        "status": "ok" if ollama_ok else "degraded",
        "ollama": ollama_ok,
        "model": CONFIG["embeddingModel"],
        "db_path": str(DB_PATH)
    })

@app.route("/store", methods=["POST"])
def store():
    """Store a new learning with its embedding."""
    data = request.json
    
    required = ["type", "content"]
    if not all(k in data for k in required):
        return jsonify({"error": f"Missing required fields: {required}"}), 400
    
    try:
        embedding = embed(data["content"])
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    # Check for duplicates
    cursor.execute("SELECT id, embedding FROM learnings")
    for row in cursor.fetchall():
        existing_embedding = json.loads(row[1])
        sim = cosine_similarity(embedding, existing_embedding)
        if sim >= CONFIG["duplicateThreshold"]:
            conn.close()
            return jsonify({
                "status": "duplicate",
                "existing_id": row[0],
                "similarity": sim
            })
    
    cursor.execute("""
        INSERT INTO learnings (type, content, context, embedding, confidence, session_source,
                               source_type, scope, tags, related_files)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        data["type"],
        data["content"],
        data.get("context"),
        json.dumps(embedding),
        data.get("confidence", 0.9),
        data.get("session_source"),
        data.get("source_type"),
        data.get("scope"),
        json.dumps(data.get("tags")) if data.get("tags") else None,
        json.dumps(data.get("related_files")) if data.get("related_files") else None
    ))
    
    learning_id = cursor.lastrowid
    conn.commit()
    conn.close()
    
    return jsonify({"status": "stored", "id": learning_id})

@app.route("/recall", methods=["POST"])
def recall():
    """Query for relevant memories."""
    data = request.json
    
    if "query" not in data:
        return jsonify({"error": "Missing 'query' field"}), 400
    
    try:
        query_embedding = embed(data["query"])
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    
    min_similarity = data.get("minSimilarity", CONFIG["minSimilarity"])
    max_results = data.get("maxResults", CONFIG["maxResults"])
    
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
        SELECT id, type, content, context, embedding, confidence,
               created_at, session_source, source_type, scope, tags, related_files
        FROM learnings
    """)

    results = []
    for row in cursor.fetchall():
        stored_embedding = json.loads(row[4])
        sim = cosine_similarity(query_embedding, stored_embedding)

        if sim >= min_similarity:
            results.append({
                "id": row[0],
                "type": row[1],
                "content": row[2],
                "context": row[3],
                "confidence": row[5],
                "similarity": round(sim, 4),
                # Trust metadata
                "created_at": row[6],
                "session_source": row[7],
                "source_type": row[8],
                "scope": row[9],
                "tags": json.loads(row[10]) if row[10] else None,
                "related_files": json.loads(row[11]) if row[11] else None
            })
    
    conn.close()
    
    # Sort by similarity and limit
    results.sort(key=lambda x: x["similarity"], reverse=True)
    results = results[:max_results]
    
    return jsonify({"memories": results, "count": len(results)})

@app.route("/stats", methods=["GET"])
def stats():
    """Get database statistics."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    cursor.execute("SELECT COUNT(*) FROM learnings")
    total = cursor.fetchone()[0]
    
    cursor.execute("SELECT type, COUNT(*) FROM learnings GROUP BY type")
    by_type = dict(cursor.fetchall())
    
    conn.close()
    
    return jsonify({
        "total_learnings": total,
        "by_type": by_type
    })

if __name__ == "__main__":
    init_db()
    migrate_db()  # Add new columns to existing DB if needed
    print(f"Memory daemon starting on port {CONFIG['port']}")
    print(f"Database: {DB_PATH}")
    print(f"Model: {CONFIG['embeddingModel']}")
    app.run(host="0.0.0.0", port=CONFIG["port"])

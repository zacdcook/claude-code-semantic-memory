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
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
        INSERT INTO learnings (type, content, context, embedding, confidence, session_source)
        VALUES (?, ?, ?, ?, ?, ?)
    """, (
        data["type"],
        data["content"],
        data.get("context"),
        json.dumps(embedding),
        data.get("confidence", 0.9),
        data.get("session_source")
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
    cursor.execute("SELECT id, type, content, context, embedding, confidence FROM learnings")
    
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
                "similarity": round(sim, 4)
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
    print(f"Memory daemon starting on port {CONFIG['port']}")
    print(f"Database: {DB_PATH}")
    print(f"Model: {CONFIG['embeddingModel']}")
    app.run(host="0.0.0.0", port=CONFIG["port"])

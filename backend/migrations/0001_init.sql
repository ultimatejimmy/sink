-- Migration: 0001_init.sql
-- Create users and progress tables for KOReader Kosync

CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,
    sync_key TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS progress (
    username TEXT NOT NULL,
    document_hash TEXT NOT NULL,
    percentage REAL NOT NULL,
    progress TEXT NOT NULL,
    device TEXT NOT NULL,
    device_id TEXT,
    timestamp INTEGER NOT NULL,
    title TEXT,
    authors TEXT,
    book_key TEXT,
    PRIMARY KEY (username, document_hash),
    FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_progress_username ON progress(username);
CREATE INDEX IF NOT EXISTS idx_progress_user_book ON progress(username, book_key);

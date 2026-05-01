import Foundation
import GRDB

final class Database {
    static let shared = Database()

    private(set) var pool: DatabasePool!
    private init() {}

    func bootstrap() {
        do {
            let url = AppPaths.dbURL
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL;")
                try db.execute(sql: "PRAGMA foreign_keys = ON;")
            }
            pool = try DatabasePool(path: url.path, configuration: config)
            try Schema.migrator().migrate(pool)
            AppLogger.storage.info("db ready at \(url.path, privacy: .public)")
        } catch {
            AppLogger.storage.error("db bootstrap failed: \(error.localizedDescription)")
        }
    }
}

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        // m.eraseDatabaseOnSchemaChange = true
        #endif

        m.registerMigration("v1.frames") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS frames (
                  id              INTEGER PRIMARY KEY AUTOINCREMENT,
                  captured_at     INTEGER NOT NULL,
                  display_id      TEXT NOT NULL,
                  display_label   TEXT,
                  image_path      TEXT NOT NULL,
                  image_phash     TEXT,
                  width INTEGER, height INTEGER, bytes INTEGER,
                  dedup_of_id     INTEGER REFERENCES frames(id),
                  analysis_status TEXT NOT NULL DEFAULT 'pending'
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_frames_time ON frames(captured_at);")
            try db.execute(sql: "CREATE INDEX idx_frames_status ON frames(analysis_status);")
        }

        m.registerMigration("v1.analyses") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS analyses (
                  frame_id        INTEGER PRIMARY KEY REFERENCES frames(id) ON DELETE CASCADE,
                  provider        TEXT NOT NULL,
                  model           TEXT NOT NULL,
                  analyzed_at     INTEGER NOT NULL,
                  summary TEXT, app TEXT, window_title TEXT, url TEXT, activity_type TEXT,
                  key_text TEXT, tags_json TEXT, entities_json TEXT, numbers_json TEXT,
                  todo_candidates_json TEXT,
                  raw_response TEXT,
                  tokens_in INTEGER, tokens_out INTEGER, latency_ms INTEGER,
                  cost_usd REAL
                );
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE analyses_fts USING fts5(
                  summary, key_text, tags, app, window_title, url,
                  content='analyses', content_rowid='frame_id', tokenize='unicode61'
                );
            """)
            try db.execute(sql: """
                CREATE TRIGGER analyses_ai AFTER INSERT ON analyses BEGIN
                  INSERT INTO analyses_fts(rowid, summary, key_text, tags, app, window_title, url)
                  VALUES (new.frame_id, new.summary, new.key_text, new.tags_json, new.app, new.window_title, new.url);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER analyses_ad AFTER DELETE ON analyses BEGIN
                  INSERT INTO analyses_fts(analyses_fts, rowid, summary, key_text, tags, app, window_title, url)
                  VALUES ('delete', old.frame_id, old.summary, old.key_text, old.tags_json, old.app, old.window_title, old.url);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER analyses_au AFTER UPDATE ON analyses BEGIN
                  INSERT INTO analyses_fts(analyses_fts, rowid, summary, key_text, tags, app, window_title, url)
                  VALUES ('delete', old.frame_id, old.summary, old.key_text, old.tags_json, old.app, old.window_title, old.url);
                  INSERT INTO analyses_fts(rowid, summary, key_text, tags, app, window_title, url)
                  VALUES (new.frame_id, new.summary, new.key_text, new.tags_json, new.app, new.window_title, new.url);
                END;
            """)
        }

        m.registerMigration("v1.todos") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS todos (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  text TEXT NOT NULL,
                  source_frame_id INTEGER REFERENCES frames(id),
                  detected_at INTEGER NOT NULL,
                  due_at INTEGER,
                  status TEXT NOT NULL DEFAULT 'open',
                  notes TEXT
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_todos_status ON todos(status);")
        }

        m.registerMigration("v1.reports") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS reports (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  kind TEXT NOT NULL,
                  range_start INTEGER NOT NULL,
                  range_end INTEGER NOT NULL,
                  generated_at INTEGER NOT NULL,
                  provider TEXT, model TEXT,
                  markdown TEXT NOT NULL,
                  meta_json TEXT
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_reports_range ON reports(range_start, range_end);")
        }

        m.registerMigration("v1.scheduled_tasks") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS scheduled_tasks (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL,
                  cron TEXT NOT NULL,
                  prompt TEXT NOT NULL,
                  output_kind TEXT NOT NULL,
                  enabled INTEGER NOT NULL DEFAULT 1,
                  last_run_at INTEGER, last_status TEXT
                );
            """)
        }

        m.registerMigration("v3.drop_legacy_triggers") { db in
            // 旧版工具可能在同名 DB 里留下 analyses_after_insert/update/delete 等 trigger
            // 它们引用 analyses_fts.tags（不存在的列），会让 INSERT/UPDATE analyses 报错
            try db.execute(sql: "DROP TRIGGER IF EXISTS analyses_after_insert;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS analyses_after_update;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS analyses_after_delete;")
        }

        m.registerMigration("v2.fix_fts_column_names") { db in
            // analyses_fts content= 模式下，列名必须等于 analyses 表列名；
            // v1 用 "tags" 与 analyses.tags_json 不匹配 → SELECT/MATCH 报 "no such column: T.tags"
            try db.execute(sql: "DROP TRIGGER IF EXISTS analyses_ai;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS analyses_au;")
            try db.execute(sql: "DROP TRIGGER IF EXISTS analyses_ad;")
            try db.execute(sql: "DROP TABLE IF EXISTS analyses_fts;")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE analyses_fts USING fts5(
                  summary, key_text, tags_json, app, window_title, url,
                  content='analyses', content_rowid='frame_id', tokenize='unicode61'
                );
            """)
            try db.execute(sql: """
                CREATE TRIGGER analyses_ai AFTER INSERT ON analyses BEGIN
                  INSERT INTO analyses_fts(rowid, summary, key_text, tags_json, app, window_title, url)
                  VALUES (new.frame_id, new.summary, new.key_text, new.tags_json, new.app, new.window_title, new.url);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER analyses_ad AFTER DELETE ON analyses BEGIN
                  INSERT INTO analyses_fts(analyses_fts, rowid, summary, key_text, tags_json, app, window_title, url)
                  VALUES ('delete', old.frame_id, old.summary, old.key_text, old.tags_json, old.app, old.window_title, old.url);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER analyses_au AFTER UPDATE ON analyses BEGIN
                  INSERT INTO analyses_fts(analyses_fts, rowid, summary, key_text, tags_json, app, window_title, url)
                  VALUES ('delete', old.frame_id, old.summary, old.key_text, old.tags_json, old.app, old.window_title, old.url);
                  INSERT INTO analyses_fts(rowid, summary, key_text, tags_json, app, window_title, url)
                  VALUES (new.frame_id, new.summary, new.key_text, new.tags_json, new.app, new.window_title, new.url);
                END;
            """)
            try db.execute(sql: """
                INSERT INTO analyses_fts(rowid, summary, key_text, tags_json, app, window_title, url)
                SELECT frame_id, summary, key_text, tags_json, app, window_title, url FROM analyses;
            """)
        }

        return m
    }
}

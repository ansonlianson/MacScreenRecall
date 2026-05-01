import Foundation
import GRDB

enum FrameRepository {
    static func insert(_ row: inout FrameRow) throws {
        try Database.shared.pool.write { db in
            try row.insert(db)
        }
    }

    static func updateStatus(_ id: Int64, status: FrameAnalysisStatus) {
        do {
            try Database.shared.pool.write { db in
                try db.execute(sql: "UPDATE frames SET analysis_status = ? WHERE id = ?",
                               arguments: [status.rawValue, id])
            }
        } catch {
            AppLogger.storage.error("updateStatus failed: \(error.localizedDescription)")
        }
    }

    /// 启动时把上次崩溃残留的 'analyzing' 改回 'pending'，方便 worker 重试。
    static func recoverOrphans() {
        do {
            try Database.shared.pool.write { db in
                try db.execute(sql: "UPDATE frames SET analysis_status='pending' WHERE analysis_status='analyzing';")
            }
        } catch {
            AppLogger.storage.error("recoverOrphans failed: \(error.localizedDescription)")
        }
    }

    /// 把 failed 改回 pending（用户在 UI 点 "重试 failed"）
    @discardableResult
    static func requeueFailed(olderThanMs: Int64? = nil) -> Int {
        do {
            return try Database.shared.pool.write { db in
                if let cutoff = olderThanMs {
                    try db.execute(sql: "UPDATE frames SET analysis_status='pending' WHERE analysis_status='failed' AND captured_at >= ?", arguments: [cutoff])
                } else {
                    try db.execute(sql: "UPDATE frames SET analysis_status='pending' WHERE analysis_status='failed'")
                }
                return db.changesCount
            }
        } catch {
            AppLogger.storage.error("requeueFailed failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// 按 captured_at 升序拿一个 pending 帧并把它改成 analyzing（事务内 atomic）
    static func claimNextPending() throws -> FrameRow? {
        try Database.shared.pool.write { db in
            guard let row = try FrameRow
                .filter(sql: "analysis_status='pending'")
                .order(sql: "captured_at ASC")
                .fetchOne(db) else { return nil }
            try db.execute(sql: "UPDATE frames SET analysis_status='analyzing' WHERE id=?",
                           arguments: [row.id ?? -1])
            return row
        }
    }

    static func backlogCount() throws -> Int {
        try Database.shared.pool.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM frames WHERE analysis_status IN ('pending','analyzing')") ?? 0
        }
    }

    static func failedCount() throws -> Int {
        try Database.shared.pool.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM frames WHERE analysis_status='failed'") ?? 0
        }
    }

    static func todayCount() throws -> Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        return try Database.shared.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM frames WHERE captured_at >= ?",
                             arguments: [startMs]) ?? 0
        }
    }

    static func pendingCount() throws -> Int {
        try Database.shared.pool.read { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM frames WHERE analysis_status IN ('pending','analyzing','failed')") ?? 0
        }
    }

    static func recentForToday(limit: Int = 200) throws -> [(FrameRow, AnalysisRow?)] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        return try Database.shared.pool.read { db in
            let frames = try FrameRow
                .filter(sql: "captured_at >= ?", arguments: [startMs])
                .order(sql: "captured_at DESC")
                .limit(limit)
                .fetchAll(db)
            var out: [(FrameRow, AnalysisRow?)] = []
            for f in frames {
                let a: AnalysisRow? = try AnalysisRow
                    .filter(sql: "frame_id = ?", arguments: [f.id ?? -1])
                    .fetchOne(db)
                out.append((f, a))
            }
            return out
        }
    }
}

enum AnalysisRepository {
    static func upsert(_ row: AnalysisRow) throws {
        try Database.shared.pool.write { db in
            try row.save(db)
        }
    }

    static func recentSummaries(limit: Int = 5) throws -> [String] {
        try Database.shared.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT summary FROM analyses
                WHERE summary IS NOT NULL AND summary != ''
                ORDER BY analyzed_at DESC LIMIT ?
                """, arguments: [limit])
        }
    }
}

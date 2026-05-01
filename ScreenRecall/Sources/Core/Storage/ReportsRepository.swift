import Foundation
import GRDB

struct ReportRow: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "reports"
    var id: Int64?
    var kind: String
    var rangeStart: Int64
    var rangeEnd: Int64
    var generatedAt: Int64
    var provider: String?
    var model: String?
    var markdown: String
    var metaJson: String?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case rangeStart = "range_start"
        case rangeEnd = "range_end"
        case generatedAt = "generated_at"
        case provider, model, markdown
        case metaJson = "meta_json"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct TodoRow: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    static let databaseTableName = "todos"
    var id: Int64?
    var text: String
    var sourceFrameId: Int64?
    var detectedAt: Int64
    var dueAt: Int64?
    var status: String
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case id, text
        case sourceFrameId = "source_frame_id"
        case detectedAt = "detected_at"
        case dueAt = "due_at"
        case status, notes
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum ReportsRepository {
    @discardableResult
    static func upsert(_ row: ReportRow) throws -> Int64 {
        try Database.shared.pool.write { db in
            var r = row
            try r.insert(db)
            return r.id ?? 0
        }
    }

    static func list(kind: String? = nil, limit: Int = 60) throws -> [ReportRow] {
        try Database.shared.pool.read { db in
            if let k = kind {
                return try ReportRow
                    .filter(sql: "kind = ?", arguments: [k])
                    .order(sql: "range_start DESC")
                    .limit(limit)
                    .fetchAll(db)
            } else {
                return try ReportRow
                    .order(sql: "range_start DESC")
                    .limit(limit)
                    .fetchAll(db)
            }
        }
    }

    static func find(id: Int64) throws -> ReportRow? {
        try Database.shared.pool.read { db in
            try ReportRow.filter(sql: "id = ?", arguments: [id]).fetchOne(db)
        }
    }

    static func dailyForDate(_ date: Date) throws -> ReportRow? {
        let cal = Calendar.current
        let start = Int64(cal.startOfDay(for: date).timeIntervalSince1970 * 1000)
        let end = Int64(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date))!.timeIntervalSince1970 * 1000)
        return try Database.shared.pool.read { db in
            try ReportRow
                .filter(sql: "kind='daily' AND range_start = ? AND range_end = ?",
                        arguments: [start, end])
                .order(sql: "generated_at DESC")
                .fetchOne(db)
        }
    }
}

enum TodosRepository {
    @discardableResult
    static func insert(_ row: TodoRow) throws -> Int64 {
        try Database.shared.pool.write { db in
            var r = row
            try r.insert(db)
            return r.id ?? 0
        }
    }

    static func list(status: String? = nil) throws -> [TodoRow] {
        try Database.shared.pool.read { db in
            if let s = status {
                return try TodoRow
                    .filter(sql: "status = ?", arguments: [s])
                    .order(sql: "detected_at DESC")
                    .fetchAll(db)
            } else {
                return try TodoRow
                    .order(sql: "detected_at DESC")
                    .fetchAll(db)
            }
        }
    }

    static func setStatus(id: Int64, status: String) {
        do {
            try Database.shared.pool.write { db in
                try db.execute(sql: "UPDATE todos SET status=? WHERE id=?",
                               arguments: [status, id])
            }
        } catch {
            AppLogger.storage.error("todo setStatus failed: \(error.localizedDescription)")
        }
    }

    /// 取最近 N 天已存在的 todos 文本，用于去重。
    static func recentTexts(days: Int = 7) throws -> Set<String> {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Int64(days) * 86_400_000
        return try Database.shared.pool.read { db in
            let rows = try String.fetchAll(db,
                sql: "SELECT text FROM todos WHERE detected_at >= ?",
                arguments: [cutoff])
            return Set(rows)
        }
    }
}

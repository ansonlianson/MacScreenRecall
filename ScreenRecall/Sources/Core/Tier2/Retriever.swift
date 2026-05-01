import Foundation
import GRDB

struct RetrievedHit: Identifiable {
    var id: Int64 { frame.id ?? 0 }
    let frame: FrameRow
    let analysis: AnalysisRow
}

enum Retriever {
    /// 关键字搜索（用于检索 Tab 顶部的搜索框）
    static func search(query rawQuery: String, limit: Int = 50) throws -> [RetrievedHit] {
        let q = sanitizeFTS(rawQuery)
        guard !q.isEmpty else { return [] }
        return try Database.shared.pool.read { db in
            let sql = """
            SELECT a.frame_id
            FROM analyses_fts
            JOIN analyses a ON a.frame_id = analyses_fts.rowid
            WHERE analyses_fts MATCH ?
            ORDER BY a.analyzed_at DESC
            LIMIT ?
            """
            let frameIds = try Int64.fetchAll(db, sql: sql, arguments: [q, limit])
            return try fetchHits(db: db, frameIds: frameIds)
        }
    }

    /// 按 AskPlan 检索：FTS 关键字 + 时间窗 + status='done'
    static func retrieve(plan: AskPlan, limit: Int = 20) throws -> [RetrievedHit] {
        let kwQuery = sanitizeFTS(plan.keywords.joined(separator: " "))
        return try Database.shared.pool.read { db in
            var ids: [Int64]
            if !kwQuery.isEmpty {
                ids = try Int64.fetchAll(db, sql: """
                    SELECT a.frame_id
                    FROM analyses_fts
                    JOIN analyses a ON a.frame_id = analyses_fts.rowid
                    JOIN frames  f ON f.id = a.frame_id
                    WHERE analyses_fts MATCH ?
                      AND f.captured_at BETWEEN ? AND ?
                      AND f.analysis_status = 'done'
                    ORDER BY f.captured_at DESC
                    LIMIT ?
                    """, arguments: [kwQuery, plan.rangeStartMs, plan.rangeEndMs, limit])
            } else {
                ids = try Int64.fetchAll(db, sql: """
                    SELECT id FROM frames
                    WHERE captured_at BETWEEN ? AND ? AND analysis_status='done'
                    ORDER BY captured_at DESC
                    LIMIT ?
                    """, arguments: [plan.rangeStartMs, plan.rangeEndMs, limit])
            }
            return try fetchHits(db: db, frameIds: ids)
        }
    }

    private static func fetchHits(db: GRDB.Database, frameIds: [Int64]) throws -> [RetrievedHit] {
        guard !frameIds.isEmpty else { return [] }
        var hits: [RetrievedHit] = []
        for id in frameIds {
            guard let f: FrameRow = try FrameRow.filter(sql: "id = ?", arguments: [id]).fetchOne(db),
                  let a: AnalysisRow = try AnalysisRow.filter(sql: "frame_id = ?", arguments: [id]).fetchOne(db)
            else { continue }
            hits.append(RetrievedHit(frame: f, analysis: a))
        }
        return hits
    }

    /// 把用户的 raw 关键字串安全地转成 FTS5 表达式，避免 special char 报错。
    /// 策略：取出每个 token，包裹成 "token"，OR 连接。
    private static func sanitizeFTS(_ raw: String) -> String {
        let tokens = raw
            .replacingOccurrences(of: "[\"'()*?!]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty && $0.count <= 32 }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}

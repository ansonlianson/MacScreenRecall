import Foundation
import GRDB

struct RetrievedHit: Identifiable {
    var id: Int64 { frame.id ?? 0 }
    let frame: FrameRow
    let analysis: AnalysisRow
}

/// 检索诊断信息（用于 UI 显示"FTS 命中 N / Embedding 命中 M"）
struct RetrieveDiagnostics {
    var keywords: [String] = []
    var ftsExpression: String = ""
    var ftsHitCount: Int = 0
    var embeddingHitCount: Int = 0
    var fellBackToWindow: Bool = false   // true 表示 FTS 0 命中走时间窗兜底
}

enum Retriever {
    /// 关键字搜索（用于检索 Tab 顶部的搜索框）
    static func search(query rawQuery: String, limit: Int = 50) throws -> [RetrievedHit] {
        let tokens = CJKTokenizer.tokenize(rawQuery, minLength: 2)
        let (longEnough, shortOnes) = tokens.split(by: { $0.count >= 3 })
        return try Database.shared.pool.read { db in
            var ids: [Int64] = []
            if !longEnough.isEmpty {
                let expr = CJKTokenizer.ftsExpression(from: longEnough)
                ids = try Int64.fetchAll(db, sql: """
                    SELECT a.frame_id FROM analyses_fts
                    JOIN analyses a ON a.frame_id = analyses_fts.rowid
                    WHERE analyses_fts MATCH ?
                    ORDER BY a.analyzed_at DESC LIMIT ?
                    """, arguments: [expr, limit])
            }
            // 短 token (1-2 字符) 走 LIKE 兜底（trigram 不索引）
            if ids.isEmpty && !shortOnes.isEmpty {
                ids = try likeFallback(db: db, tokens: shortOnes, limit: limit, sinceMs: nil, untilMs: nil)
            }
            return try fetchHits(db: db, frameIds: ids)
        }
    }

    /// 按 AskPlan 检索：FTS 关键字 + 时间窗 + status='done'，返回带诊断信息
    static func retrieve(plan: AskPlan, limit: Int = 20) throws -> (hits: [RetrievedHit], diag: RetrieveDiagnostics) {
        var diag = RetrieveDiagnostics()
        // 优先用 LLM 给出的 keywords；不足时再 tokenize 原问题
        var tokens = plan.keywords.flatMap { CJKTokenizer.tokenize($0, minLength: 2) }
        if tokens.isEmpty {
            tokens = CJKTokenizer.tokenize(plan.rawQuestion, minLength: 2)
        }
        diag.keywords = tokens
        let (longEnough, shortOnes) = tokens.split(by: { $0.count >= 3 })
        let expr = CJKTokenizer.ftsExpression(from: longEnough)
        diag.ftsExpression = expr

        let hits = try Database.shared.pool.read { db -> [RetrievedHit] in
            var ids: [Int64] = []
            if !expr.isEmpty {
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
                    """, arguments: [expr, plan.rangeStartMs, plan.rangeEndMs, limit])
            }
            // FTS 0 命中且有短 token：用 LIKE 兜底
            if ids.isEmpty && !shortOnes.isEmpty {
                ids = try likeFallback(db: db, tokens: shortOnes, limit: limit,
                                       sinceMs: plan.rangeStartMs, untilMs: plan.rangeEndMs)
            }
            // 仍 0 命中：退化为时间窗最近 N 帧（让 Tier-2 自己挑）
            if ids.isEmpty {
                ids = try Int64.fetchAll(db, sql: """
                    SELECT id FROM frames
                    WHERE captured_at BETWEEN ? AND ? AND analysis_status='done'
                    ORDER BY captured_at DESC
                    LIMIT ?
                    """, arguments: [plan.rangeStartMs, plan.rangeEndMs, limit])
            }
            return try fetchHits(db: db, frameIds: ids)
        }
        diag.ftsHitCount = hits.count
        diag.fellBackToWindow = !expr.isEmpty && hits.isEmpty == false && hits.count > 0 && diag.ftsExpression.isEmpty
        // 简单标记：if expr 为空 且 仍有 hits → fell back
        if expr.isEmpty && !hits.isEmpty {
            diag.fellBackToWindow = true
        }
        return (hits, diag)
    }

    /// LIKE 兜底：手工 OR 多个 LIKE，覆盖 1-2 字符的中文 token
    private static func likeFallback(db: GRDB.Database, tokens: [String], limit: Int,
                                     sinceMs: Int64?, untilMs: Int64?) throws -> [Int64] {
        guard !tokens.isEmpty else { return [] }
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        for t in tokens {
            clauses.append("(a.summary LIKE ? OR a.key_text LIKE ? OR a.window_title LIKE ? OR a.app LIKE ? OR a.url LIKE ? OR a.tags_json LIKE ?)")
            let like = "%\(t)%"
            args.append(contentsOf: [like, like, like, like, like, like])
        }
        var where_ = "(\(clauses.joined(separator: " OR ")))"
        if let s = sinceMs, let u = untilMs {
            where_ += " AND f.captured_at BETWEEN ? AND ?"
            args.append(s); args.append(u)
        }
        where_ += " AND f.analysis_status='done'"
        args.append(limit)
        let sql = """
            SELECT a.frame_id
            FROM analyses a JOIN frames f ON f.id = a.frame_id
            WHERE \(where_)
            ORDER BY f.captured_at DESC
            LIMIT ?
            """
        return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
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
}

private extension Array {
    /// 按谓词把数组拆成两份：满足的与不满足的
    func split(by predicate: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = []
        var no: [Element] = []
        for e in self {
            if predicate(e) { yes.append(e) } else { no.append(e) }
        }
        return (yes, no)
    }
}

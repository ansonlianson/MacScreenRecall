import Foundation
import GRDB

/// 一次性 / 周期性清理任务。
enum CleanupService {
    /// 删掉历史 `analysis_status='skipped'` 帧的 JPEG 文件 + DB 行（v0.2.0 之前留下的）。
    /// 返回 (删了多少行, 释放多少字节)。后台静默执行；可重复调用。
    @discardableResult
    static func purgeLegacySkippedFrames() async -> (rows: Int, bytes: Int64) {
        let paths: [(Int64, String, Int)]
        do {
            paths = try await Database.shared.pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, image_path, COALESCE(bytes, 0) as bytes
                    FROM frames WHERE analysis_status='skipped'
                    """).map { ($0["id"] as Int64, $0["image_path"] as String, $0["bytes"] as Int) }
            }
        } catch {
            AppLogger.storage.error("purgeLegacySkippedFrames scan failed: \(error.localizedDescription)")
            return (0, 0)
        }
        guard !paths.isEmpty else { return (0, 0) }
        AppLogger.storage.info("purging \(paths.count) legacy skipped frames…")

        var freed: Int64 = 0
        let fm = FileManager.default
        for (_, path, bytes) in paths {
            if fm.fileExists(atPath: path), (try? fm.removeItem(atPath: path)) != nil {
                freed += Int64(bytes)
            }
        }
        let ids = paths.map { $0.0 }
        do {
            try await Database.shared.pool.write { db in
                // SQLite 单次 IN(...) 上限够用（< 1k 通常，分批更稳）
                let chunks = stride(from: 0, to: ids.count, by: 500).map {
                    Array(ids[$0..<min($0 + 500, ids.count)])
                }
                for chunk in chunks {
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let sql = "DELETE FROM frames WHERE id IN (\(placeholders))"
                    try db.execute(sql: sql, arguments: StatementArguments(chunk))
                }
            }
        } catch {
            AppLogger.storage.error("purge DB delete failed: \(error.localizedDescription)")
        }
        AppLogger.storage.info("purged legacy skipped: rows=\(paths.count) freed=\(freed) bytes")
        return (paths.count, freed)
    }
}

import Foundation
import GRDB

/// 文本嵌入器：把文本转向量。两个实现：
/// - AppleNLEmbedder（默认零依赖）
/// - OpenAICompatibleEmbedder（用户配置 ModelProfile kind=embedding 后启用）
protocol Embedder: Sendable {
    var name: String { get }   // 写入 analysis_embeddings.embedder 用作版本/区分
    var dim: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// 嵌入向量入库行
struct EmbeddingRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "analysis_embeddings"
    var frameId: Int64
    var embedder: String
    var dim: Int
    var vector: Data
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case frameId = "frame_id"
        case embedder
        case dim
        case vector
        case createdAt = "created_at"
    }
}

actor EmbeddingService {
    static let shared = EmbeddingService()
    private init() {}

    private var workerTask: Task<Void, Never>?
    private var pending: [(frameId: Int64, text: String)] = []
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        workerTask = Task { [weak self] in await self?.runLoop() }
        // 启动时回填一次
        Task { [weak self] in await self?.backfillMissing() }
    }

    func enqueue(frameId: Int64, text: String) {
        guard !text.isEmpty else { return }
        pending.append((frameId, text))
    }

    /// 当前激活的 embedder（按 settings 选择）
    @MainActor
    private static func currentEmbedder() -> Embedder {
        if let profile = SettingsStore.shared.embeddingProfile() {
            let key = KeychainStore.get(forProfileId: profile.id)
            return OpenAICompatibleEmbedder(profile: profile, apiKey: key)
        }
        return AppleNLEmbedder.shared
    }

    private func runLoop() async {
        while !Task.isCancelled {
            // 批量取一组
            let batch = Array(pending.prefix(8))
            if batch.isEmpty {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            pending.removeFirst(min(8, pending.count))
            await processBatch(batch)
        }
    }

    private func processBatch(_ batch: [(frameId: Int64, text: String)]) async {
        let embedder = await EmbeddingService.currentEmbedder()
        let texts = batch.map { $0.text }
        do {
            let vectors = try await embedder.embed(texts)
            guard vectors.count == batch.count else { return }
            try await Database.shared.pool.write { db in
                for (i, item) in batch.enumerated() {
                    let v = vectors[i]
                    let blob = Self.packFloats(v)
                    let row = EmbeddingRow(
                        frameId: item.frameId,
                        embedder: embedder.name,
                        dim: embedder.dim,
                        vector: blob,
                        createdAt: Int64(Date().timeIntervalSince1970 * 1000)
                    )
                    try row.save(db)
                }
            }
            AppLogger.tier2.info("embedded \(batch.count) frames via \(embedder.name)")
        } catch {
            DebugFile.write("embedding batch failed: \(error.localizedDescription)")
        }
    }

    /// 启动时扫缺少 embedding 的 done 帧 → 入队回填
    func backfillMissing(limit: Int = 1000) async {
        do {
            let rows = try await Database.shared.pool.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT a.frame_id, COALESCE(a.summary,'') || ' | ' || COALESCE(a.key_text,'') || ' | ' || COALESCE(a.tags_json,'') AS txt
                    FROM analyses a
                    LEFT JOIN analysis_embeddings e ON e.frame_id = a.frame_id
                    JOIN frames f ON f.id = a.frame_id
                    WHERE e.frame_id IS NULL AND f.analysis_status='done'
                      AND length(COALESCE(a.summary,'')) > 0
                    ORDER BY a.frame_id DESC
                    LIMIT ?
                    """, arguments: [limit])
            }
            for r in rows {
                let id: Int64 = r["frame_id"]
                let txt: String = r["txt"]
                pending.append((id, txt))
            }
            if !rows.isEmpty {
                AppLogger.tier2.info("embedding backfill queued \(rows.count) frames")
            }
        } catch {
            AppLogger.tier2.error("backfill scan failed: \(error.localizedDescription)")
        }
    }

    func backlog() -> Int { pending.count }

    /// 余弦排序检索：把库内向量加载到内存（最多 N 条）做余弦排序，返回 top-K frame_id + score
    func searchSimilar(query: String, sinceMs: Int64, untilMs: Int64, topK: Int = 20) async throws -> [(Int64, Float)] {
        let embedder = await EmbeddingService.currentEmbedder()
        let qvec = try await embedder.embed([query]).first ?? []
        guard !qvec.isEmpty else { return [] }

        let rows = try await Database.shared.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.frame_id, e.vector, e.dim
                FROM analysis_embeddings e
                JOIN frames f ON f.id = e.frame_id
                WHERE f.captured_at BETWEEN ? AND ? AND e.embedder = ?
                """, arguments: [sinceMs, untilMs, embedder.name])
        }
        let qNorm = Self.l2(qvec)
        guard qNorm > 0 else { return [] }
        var scored: [(Int64, Float)] = []
        for r in rows {
            let id: Int64 = r["frame_id"]
            let vBlob: Data = r["vector"]
            let dim: Int = r["dim"]
            guard dim == qvec.count else { continue }
            let v = Self.unpackFloats(vBlob)
            let dot = Self.dot(qvec, v)
            let vN = Self.l2(v)
            guard vN > 0 else { continue }
            scored.append((id, dot / (qNorm * vN)))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0 }
    }

    // MARK: - byte helpers

    static func packFloats(_ arr: [Float]) -> Data {
        var data = Data(capacity: arr.count * 4)
        for v in arr {
            var x = v.bitPattern.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpackFloats(_ data: Data) -> [Float] {
        let n = data.count / 4
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let bits = raw.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                out[i] = Float(bitPattern: bits)
            }
        }
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    static func l2(_ a: [Float]) -> Float {
        var s: Float = 0
        for v in a { s += v * v }
        return s.squareRoot()
    }
}

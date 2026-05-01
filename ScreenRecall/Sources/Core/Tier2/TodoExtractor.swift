import Foundation
import GRDB

private struct CandidateRow {
    var frameId: Int64
    var capturedAt: Int64
    var text: String
    var context: String
}

enum TodoExtractor {
    /// 从指定窗内的 todo_candidates_json 抽取 → 去重 → Tier-2 二次审核 → 入 todos 表。
    /// 返回新增数量。
    @discardableResult
    static func extract(rangeStart: Int64? = nil, rangeEnd: Int64? = nil) async throws -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let start = rangeStart ?? Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        let end = rangeEnd ?? now

        let candidates = try fetchCandidates(start: start, end: end)
        if candidates.isEmpty { return 0 }

        let existing = (try? TodosRepository.recentTexts(days: 7)) ?? []
        let deduped = dedupe(candidates: candidates, existing: existing)
        if deduped.isEmpty { return 0 }

        let secondary = await MainActor.run { SettingsStore.shared.settings.todos.secondaryReview }
        let approved: [CandidateRow]
        if secondary {
            approved = await reviewByLLM(candidates: deduped)
        } else {
            approved = deduped
        }

        var inserted = 0
        for c in approved {
            do {
                _ = try TodosRepository.insert(TodoRow(
                    id: nil, text: c.text, sourceFrameId: c.frameId,
                    detectedAt: c.capturedAt, dueAt: nil, status: "open", notes: c.context
                ))
                inserted += 1
            } catch {
                AppLogger.tier2.error("todo insert failed: \(error.localizedDescription)")
            }
        }
        AppLogger.tier2.info("TodoExtractor: candidates=\(candidates.count) deduped=\(deduped.count) approved=\(approved.count) inserted=\(inserted)")
        return inserted
    }

    private static func fetchCandidates(start: Int64, end: Int64) throws -> [CandidateRow] {
        try Database.shared.pool.read { db in
            var out: [CandidateRow] = []
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.frame_id, f.captured_at, a.todo_candidates_json
                FROM analyses a JOIN frames f ON f.id = a.frame_id
                WHERE f.captured_at BETWEEN ? AND ? AND f.analysis_status='done'
                AND a.todo_candidates_json IS NOT NULL AND a.todo_candidates_json != '[]'
                ORDER BY f.captured_at ASC
                """, arguments: [start, end])
            for row in rows {
                let frameId: Int64 = row["frame_id"]
                let capturedAt: Int64 = row["captured_at"]
                let json: String? = row["todo_candidates_json"]
                guard let data = json?.data(using: .utf8),
                      let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
                for item in arr {
                    if let t = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty, t.count >= 4 {
                        out.append(CandidateRow(
                            frameId: frameId, capturedAt: capturedAt,
                            text: t, context: (item["context"] as? String) ?? ""
                        ))
                    }
                }
            }
            return out
        }
    }

    /// 去重：同文本/编辑距离 ≤ 阈值；与既有 todos 文本重合的也跳过
    private static func dedupe(candidates: [CandidateRow], existing: Set<String>) -> [CandidateRow] {
        var seen: [String] = []
        var out: [CandidateRow] = []
        let threshold = 6
        for c in candidates {
            let key = c.text
            if existing.contains(key) { continue }
            if seen.contains(where: { editDistance($0, key) <= threshold }) { continue }
            seen.append(key)
            out.append(c)
        }
        return out
    }

    /// Tier-2 二次审核：批量过滤掉非用户本人 / 文章引述 / 错误识别的 candidate
    private static func reviewByLLM(candidates: [CandidateRow]) async -> [CandidateRow] {
        guard !candidates.isEmpty else { return [] }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        let listing = candidates.enumerated().map { idx, c -> String in
            let t = Date(timeIntervalSince1970: TimeInterval(c.capturedAt) / 1000)
            return "[\(idx + 1)] \(f.string(from: t)) — \(c.text) ｜ ctx: \(c.context)"
        }.joined(separator: "\n")

        let system = """
        你是 TODO 审核员。下面是从屏幕截图中识别出的"可能待办"。请判断哪些是**用户本人需要去做的事**（非他人/非文章引用/非系统提示）。
        只输出 JSON：{"approved_indices": [int, ...]}（1-indexed，candidates 列表里的下标）。
        判断标准：
        - 必须是动作型/待办型语句（"打电话/写报告/修复/部署/购买/联系..."）
        - 排除：他人发给用户的请求"你能不能..."（虽相关但不一定是 TODO）
        - 排除：文章/教程里的引述
        - 排除：系统/UI 提示文字
        宁缺毋滥；不确定就不批准。
        """
        let user = "candidates：\n\(listing)"

        let bundle = await MainActor.run { () -> (ModelProfile, String?)? in
            guard let p = SettingsStore.shared.tier2Profile() else { return nil }
            return (p, KeychainStore.get(forProfileId: p.id))
        }
        guard let (profile, apiKey) = bundle else { return candidates }
        let provider = ProviderFactory.make(profile: profile, apiKey: apiKey)
        let req = LLMRequest(
            system: system,
            messages: [LLMMessage(role: .user, text: user)],
            images: [],
            model: profile.model,
            temperature: 0.0,
            maxTokens: 800,
            timeout: 60,
            responseFormat: .json,
            disableThinking: false
        )
        do {
            let resp = try await provider.complete(req)
            guard let parsed = JSONExtractor.extract(from: resp.text),
                  let idxs = parsed["approved_indices"] as? [Int] else { return [] }
            return idxs.compactMap { i in
                let zeroBased = i - 1
                return (0..<candidates.count).contains(zeroBased) ? candidates[zeroBased] : nil
            }
        } catch {
            AppLogger.tier2.error("Todo review LLM failed: \(error.localizedDescription) — fallback to no-review")
            return candidates
        }
    }

    /// 简易编辑距离（动态规划），用于近似去重
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let A = Array(a), B = Array(b)
        let m = A.count, n = B.count
        if m == 0 { return n }; if n == 0 { return m }
        var dp = Array(0...n)
        for i in 1...m {
            var prev = dp[0]; dp[0] = i
            for j in 1...n {
                let temp = dp[j]
                let cost = A[i - 1] == B[j - 1] ? 0 : 1
                dp[j] = min(dp[j] + 1, dp[j - 1] + 1, prev + cost)
                prev = temp
            }
        }
        return dp[n]
    }
}

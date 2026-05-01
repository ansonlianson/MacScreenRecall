import Foundation
import AppKit

actor Tier1Pipeline {
    static let shared = Tier1Pipeline()
    private init() {}

    private var lastPHashByDisplay: [String: String] = [:]
    private var lastFrameIdByDisplay: [String: Int64] = [:]
    private var workers: [Task<Void, Never>] = []
    private var workerCount: Int = 0
    private var started = false

    // MARK: - lifecycle

    func startWorkers() async {
        guard !started else { return }
        started = true
        FrameRepository.recoverOrphans()
        await reconcileWorkers()
    }

    /// 根据 settings.tier1Concurrency 调整 worker 数量（热生效）。
    func reconcileWorkers() async {
        let target = max(1, min(4, await MainActor.run { SettingsStore.shared.settings.tier1Concurrency }))
        if target == workerCount { return }
        DebugFile.write("Tier1 reconcile workers \(workerCount) → \(target)")
        // 简化：把全部停掉再起 target 个
        for w in workers { w.cancel() }
        workers.removeAll()
        for i in 0..<target {
            workers.append(Task { [weak self] in
                await self?.workerLoop(idx: i)
            })
        }
        workerCount = target
    }

    // MARK: - ingest (capture → row)

    func ingest(frame: CapturedFrame) async {
        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        guard let url = saveImageToDisk(jpeg: frame.jpegData, capturedAt: now, displayId: frame.displayId) else {
            AppLogger.tier1.error("save image failed")
            return
        }

        // 背压：积压超过阈值时仍入库 pending（让 worker 慢慢消化），不丢图，不阻塞采集。
        let backlog = (try? FrameRepository.backlogCount()) ?? 0
        let maxBacklog = await MainActor.run { SettingsStore.shared.settings.capture.maxBacklog }
        if backlog > maxBacklog {
            DebugFile.write("Tier1 backpressure: backlog=\(backlog) > \(maxBacklog), still inserting pending")
        }

        var dedupOf: Int64? = nil
        let dedupThreshold = await MainActor.run { SettingsStore.shared.settings.capture.dedupPHashDistance }
        if let prev = lastPHashByDisplay[frame.displayId],
           let prevId = lastFrameIdByDisplay[frame.displayId],
           let dist = PHashUtil.hammingHex(prev, frame.phash),
           dist <= dedupThreshold {
            dedupOf = prevId
        }

        var row = FrameRow(
            id: nil, capturedAt: ms,
            displayId: frame.displayId, displayLabel: frame.displayLabel,
            imagePath: url.path, imagePhash: frame.phash,
            width: frame.pixelWidth, height: frame.pixelHeight, bytes: frame.jpegData.count,
            dedupOfId: dedupOf,
            analysisStatus: dedupOf != nil ? FrameAnalysisStatus.skipped.rawValue : FrameAnalysisStatus.pending.rawValue
        )
        do {
            try FrameRepository.insert(&row)
        } catch {
            AppLogger.tier1.error("frame insert failed: \(error.localizedDescription)")
            return
        }
        guard let frameId = row.id else { return }

        lastPHashByDisplay[frame.displayId] = frame.phash
        lastFrameIdByDisplay[frame.displayId] = frameId

        await refreshCounters()
        if dedupOf != nil {
            AppLogger.tier1.info("frame \(frameId) deduped of \(dedupOf!)")
        }
    }

    // MARK: - workers

    private func workerLoop(idx: Int) async {
        DebugFile.write("Tier1 worker[\(idx)] start")
        while !Task.isCancelled {
            // 1. claim a pending frame
            let claimed: FrameRow?
            do { claimed = try FrameRepository.claimNextPending() }
            catch { claimed = nil; AppLogger.tier1.error("claim failed: \(error.localizedDescription)") }

            guard let row = claimed, let frameId = row.id else {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }

            // 2. load image
            guard let jpeg = try? Data(contentsOf: URL(fileURLWithPath: row.imagePath)) else {
                AppLogger.tier1.error("frame \(frameId) image missing on disk")
                FrameRepository.updateStatus(frameId, status: .failed)
                continue
            }

            // 3. analyze
            await analyze(frameId: frameId, jpeg: jpeg)
            await refreshCounters()
        }
        DebugFile.write("Tier1 worker[\(idx)] exit")
    }

    private func analyze(frameId: Int64, jpeg: Data) async {
        let bundle = await MainActor.run { () -> (ModelProfile, String?, String)? in
            guard let p = SettingsStore.shared.tier1Profile() else { return nil }
            let key = KeychainStore.get(forProfileId: p.id)
            return (p, key, PromptLoader.tier1System)
        }
        guard let (profile, apiKey, prompt) = bundle else {
            FrameRepository.updateStatus(frameId, status: .failed)
            DebugFile.write("frame \(frameId) FAILED: 未配置 Tier-1 模型")
            await MainActor.run { AppState.shared.lastError = "未配置 Tier-1 模型，请到设置 → 模型管理添加" }
            return
        }
        let provider = ProviderFactory.make(profile: profile, apiKey: apiKey)

        let request = LLMRequest(
            system: prompt,
            messages: [LLMMessage(role: .user, text: "请分析这张截图并按 schema 输出 JSON。")],
            images: [jpeg],
            model: profile.model,
            temperature: 0.2,
            maxTokens: profile.maxTokens,
            timeout: TimeInterval(profile.timeoutSec),
            responseFormat: .json,
            disableThinking: true
        )

        do {
            let resp = try await provider.complete(request)
            let parsed = JSONExtractor.extract(from: resp.text) ?? [:]
            if parsed.isEmpty {
                DebugFile.write("frame \(frameId) JSON parse empty (raw len=\(resp.text.count))")
            }
            let analysis = AnalysisRow(
                frameId: frameId,
                provider: provider.name,
                model: profile.model,
                analyzedAt: Int64(Date().timeIntervalSince1970 * 1000),
                summary: parsed["summary"] as? String,
                app: parsed["app"] as? String,
                windowTitle: parsed["window_title"] as? String,
                url: parsed["url"] as? String,
                activityType: parsed["activity_type"] as? String,
                keyText: parsed["key_text"] as? String,
                tagsJson: jsonString(parsed["tags"]),
                entitiesJson: jsonString(parsed["entities"]),
                numbersJson: jsonString(parsed["visible_numbers"]),
                todoCandidatesJson: jsonString(parsed["todo_candidates"]),
                rawResponse: resp.text,
                tokensIn: resp.tokensIn, tokensOut: resp.tokensOut,
                latencyMs: resp.latencyMs, costUsd: resp.costUSD
            )
            try AnalysisRepository.upsert(analysis)
            FrameRepository.updateStatus(frameId, status: .done)

            await MainActor.run {
                AppState.shared.lastAnalyzedAt = Date()
                AppState.shared.lastError = nil
                if let s = analysis.summary, !s.isEmpty {
                    var rs = AppState.shared.recentSummaries
                    rs.insert(s, at: 0)
                    AppState.shared.recentSummaries = Array(rs.prefix(20))
                }
            }
            AppLogger.tier1.info("frame \(frameId) analyzed in \(resp.latencyMs)ms tokens=\(resp.tokensOut ?? -1)")
        } catch {
            FrameRepository.updateStatus(frameId, status: .failed)
            AppLogger.tier1.error("frame \(frameId) analyze failed: \(error.localizedDescription)")
            DebugFile.write("Tier1 frame \(frameId) FAILED: \(error.localizedDescription)")
            await MainActor.run {
                AppState.shared.lastError = "Tier-1 失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - helpers

    private func refreshCounters() async {
        let n = (try? FrameRepository.todayCount()) ?? 0
        let p = (try? FrameRepository.backlogCount()) ?? 0
        await MainActor.run {
            AppState.shared.todayFrameCount = n
            AppState.shared.pendingAnalysisCount = p
        }
    }

    private func saveImageToDisk(jpeg: Data, capturedAt: Date, displayId: String) -> URL? {
        let cal = Calendar.current
        let comp = cal.dateComponents([.year, .month, .day], from: capturedAt)
        let dir = AppPaths.framesDir
            .appendingPathComponent(String(format: "%04d", comp.year ?? 0))
            .appendingPathComponent(String(format: "%02d", comp.month ?? 0))
            .appendingPathComponent(String(format: "%02d", comp.day ?? 0))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = Int64(capturedAt.timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("\(ts)_\(displayId).jpg")
        do {
            try jpeg.write(to: url)
            return url
        } catch {
            AppLogger.storage.error("write image failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func jsonString(_ obj: Any?) -> String? {
        guard let obj else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

enum JSONExtractor {
    static func extract(from text: String) -> [String: Any]? {
        if let d = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return obj
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index? = nil
        for i in text[start...].indices {
            let c = text[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
        }
        guard let e = end else { return nil }
        let slice = String(text[start...e])
        if let d = slice.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return obj
        }
        return nil
    }
}

enum PromptLoader {
    static var tier1System: String {
        if let url = Bundle.main.url(forResource: "tier1.system", withExtension: "txt"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return defaultPrompt
    }
    private static let defaultPrompt = """
    你是 macOS 截图分析助手。看到一张屏幕截图，请只输出 JSON，包含字段：
    summary, app, window_title, url, activity_type,
    entities[], visible_numbers[], key_text, tags[], todo_candidates[]
    不要输出 Markdown 代码块或解释。
    """
}

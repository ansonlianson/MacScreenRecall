import Foundation
import GRDB

struct SelfCheckResult {
    var screenRecording: Bool = false
    var notification: Bool = false
    var dbReachable: Bool = false
    var diskFreeBytes: Int64 = 0
    var framesDirBytes: Int64 = 0
    var tier1Provider: String = ""
    var tier1Reachable: Bool? = nil
    var tier1Latency: Int? = nil
    var tier2Provider: String = ""
    var tier2Reachable: Bool? = nil
    var tier2Latency: Int? = nil
    var lastHourSuccessRate: Double = 1.0   // 0..1
    var lastHourTotal: Int = 0
    var lastHourDone: Int = 0
}

enum SelfCheckService {
    static func run() async -> SelfCheckResult {
        var r = SelfCheckResult()
        r.screenRecording = await PermissionsService.shared.checkScreenCapture()
        r.notification = await PermissionsService.shared.checkNotifications()
        r.dbReachable = (Database.shared.pool != nil)
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: AppPaths.supportDir.path),
           let free = attrs[.systemFreeSize] as? NSNumber {
            r.diskFreeBytes = free.int64Value
        }
        r.framesDirBytes = directorySize(at: AppPaths.framesDir)

        let (s, k1, k2) = await MainActor.run {
            (SettingsStore.shared.settings, KeychainStore.get(.tier1ApiKey), KeychainStore.get(.tier2ApiKey))
        }
        r.tier1Provider = s.tier1.provider.displayName
        r.tier2Provider = s.tier2.provider.displayName

        async let p1 = ping(settings: s.tier1, apiKey: k1)
        async let p2 = ping(settings: s.tier2, apiKey: k2)
        let (a, b) = await (p1, p2)
        r.tier1Reachable = a.0; r.tier1Latency = a.1
        r.tier2Reachable = b.0; r.tier2Latency = b.1

        let (total, done) = lastHourCounts()
        r.lastHourTotal = total
        r.lastHourDone = done
        r.lastHourSuccessRate = total == 0 ? 1 : Double(done) / Double(total)
        return r
    }

    private static func ping(settings: ProviderSettings, apiKey: String?) async -> (Bool, Int?) {
        let provider = ProviderFactory.make(settings: settings, apiKey: apiKey)
        let start = Date()
        let req = LLMRequest(
            system: nil,
            messages: [LLMMessage(role: .user, text: "ok?")],
            images: [],
            model: settings.model,
            temperature: 0.0,
            maxTokens: 32,
            timeout: 15,
            responseFormat: .text,
            disableThinking: true
        )
        do {
            _ = try await provider.complete(req)
            return (true, Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            AppLogger.app.error("ping \(provider.name) failed: \(error.localizedDescription)")
            return (false, nil)
        }
    }

    private static func lastHourCounts() -> (total: Int, done: Int) {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        do {
            return try Database.shared.pool.read { db in
                let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM frames WHERE captured_at >= ? AND analysis_status NOT IN ('skipped')", arguments: [cutoff]) ?? 0
                let done = try Int.fetchOne(db, sql: "SELECT count(*) FROM frames WHERE captured_at >= ? AND analysis_status='done'", arguments: [cutoff]) ?? 0
                return (total, done)
            }
        } catch {
            return (0, 0)
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in it {
            if let s = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(s)
            }
        }
        return total
    }
}

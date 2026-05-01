import Foundation
import GRDB

struct FrameRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "frames"

    var id: Int64?
    var capturedAt: Int64
    var displayId: String
    var displayLabel: String?
    var imagePath: String
    var imagePhash: String?
    var width: Int?
    var height: Int?
    var bytes: Int?
    var dedupOfId: Int64?
    var analysisStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case displayId = "display_id"
        case displayLabel = "display_label"
        case imagePath = "image_path"
        case imagePhash = "image_phash"
        case width, height, bytes
        case dedupOfId = "dedup_of_id"
        case analysisStatus = "analysis_status"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct AnalysisRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "analyses"

    var frameId: Int64
    var provider: String
    var model: String
    var analyzedAt: Int64
    var summary: String?
    var app: String?
    var windowTitle: String?
    var url: String?
    var activityType: String?
    var keyText: String?
    var tagsJson: String?
    var entitiesJson: String?
    var numbersJson: String?
    var todoCandidatesJson: String?
    var rawResponse: String?
    var tokensIn: Int?
    var tokensOut: Int?
    var latencyMs: Int?
    var costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case frameId = "frame_id"
        case provider, model
        case analyzedAt = "analyzed_at"
        case summary, app
        case windowTitle = "window_title"
        case url
        case activityType = "activity_type"
        case keyText = "key_text"
        case tagsJson = "tags_json"
        case entitiesJson = "entities_json"
        case numbersJson = "numbers_json"
        case todoCandidatesJson = "todo_candidates_json"
        case rawResponse = "raw_response"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case latencyMs = "latency_ms"
        case costUsd = "cost_usd"
    }
}

enum FrameAnalysisStatus: String {
    case pending, analyzing, done, failed, skipped
}

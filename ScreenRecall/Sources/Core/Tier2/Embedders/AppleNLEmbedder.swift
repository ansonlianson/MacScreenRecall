import Foundation
import NaturalLanguage

/// Apple 原生 sentence embedding。零依赖；中英文走对应 NLEmbedding。
/// 维度由系统决定，常见 300/512。
final class AppleNLEmbedder: Embedder {
    static let shared = AppleNLEmbedder()
    private init() {}

    var name: String { "apple-nl-v1" }
    var dim: Int { _dim }
    private var _dim: Int = 300   // 首次 embed 后更新为实际值

    private let zh = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)
    private let en = NLEmbedding.sentenceEmbedding(for: .english)

    func embed(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        for t in texts {
            let v = embedOne(t)
            if v.isEmpty {
                out.append([])
            } else {
                if _dim != v.count { _dim = v.count }
                out.append(v)
            }
        }
        // 如果有空向量，填零保证 batch 长度一致
        let target = out.map { $0.count }.max() ?? 0
        if target > 0 {
            for i in 0..<out.count where out[i].isEmpty {
                out[i] = [Float](repeating: 0, count: target)
            }
        }
        return out
    }

    private func embedOne(_ text: String) -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lang = predominantLanguage(trimmed)
        let model: NLEmbedding? = (lang == .english) ? en : zh
        if let m = model, let vec = m.vector(for: trimmed) {
            return vec.map { Float($0) }
        }
        // sentence embedding 在 macOS 上对部分语言不存在 → fallback 到 token embedding 平均
        let tokenModel = NLEmbedding.wordEmbedding(for: lang) ?? NLEmbedding.wordEmbedding(for: .english)
        guard let m = tokenModel else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        var sum: [Double] = []
        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let token = String(trimmed[range])
            if let v = m.vector(for: token) {
                if sum.isEmpty { sum = [Double](repeating: 0, count: v.count) }
                if sum.count == v.count {
                    for i in 0..<v.count { sum[i] += v[i] }
                    count += 1
                }
            }
            return true
        }
        guard count > 0 else { return [] }
        return sum.map { Float($0 / Double(count)) }
    }

    private func predominantLanguage(_ s: String) -> NLLanguage {
        let recog = NLLanguageRecognizer()
        recog.processString(s)
        return recog.dominantLanguage ?? .english
    }
}

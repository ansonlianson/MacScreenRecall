import Foundation
import CoreFoundation

/// 中英混合分词，用于 FTS5 查询构造与 keyword 抽取。
/// 内部用 CFStringTokenizer + 中文 locale，能正确分出中文词、英文 token、数字。
enum CJKTokenizer {
    /// 分词输入，返回 ≥minLength 的 token 数组（保持原顺序，去重）。
    static func tokenize(_ text: String, minLength: Int = 2) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cfString = trimmed as CFString
        let range = CFRangeMake(0, CFStringGetLength(cfString))
        let locale = NSLocale(localeIdentifier: "zh_CN") as CFLocale
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfString,
            range,
            kCFStringTokenizerUnitWordBoundary,
            locale
        )
        var out: [String] = []
        var seen = Set<String>()
        var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while type != [] {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if tokenRange.length > 0 {
                let nsRange = NSRange(location: tokenRange.location, length: tokenRange.length)
                if let r = Range(nsRange, in: trimmed) {
                    let token = String(trimmed[r])
                    let cleaned = token
                        .trimmingCharacters(in: CharacterSet.punctuationCharacters)
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if cleaned.count >= minLength,
                       !cleaned.isEmpty,
                       !isStopWord(cleaned),
                       !seen.contains(cleaned) {
                        out.append(cleaned)
                        seen.insert(cleaned)
                    }
                }
            }
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return out
    }

    /// 把 token 列表转成 FTS5 trigram MATCH 表达式，用 OR 连接。
    /// trigram 模式下不需要双引号包裹，但加了也无害；为了对纯英文/数字稳妥，仍保留。
    static func ftsExpression(from tokens: [String]) -> String {
        let escaped = tokens.compactMap { tok -> String? in
            // FTS5 双引号转义：把内部 " 替换成 ""
            let safe = tok.replacingOccurrences(of: "\"", with: "\"\"")
            // 长度超过 64 截断（trigram 不需要超长 token）
            let trimmed = safe.count > 64 ? String(safe.prefix(64)) : safe
            return trimmed.isEmpty ? nil : "\"\(trimmed)\""
        }
        return escaped.joined(separator: " OR ")
    }

    // 中英常见疑问/连接停用词，避免污染 FTS 查询。
    private static let stopWords: Set<String> = [
        "什么", "哪里", "哪个", "怎么", "如何", "为何", "为什么",
        "请", "帮", "查", "我", "你", "他", "她", "它", "的", "了", "在", "是",
        "和", "与", "或", "等", "上", "下", "里", "里面", "上面", "下面",
        "今天", "昨天", "明天", "刚才", "最近", "过去", "之前", "之后",
        "the", "a", "an", "is", "are", "was", "were", "of", "to", "and", "or",
        "for", "in", "on", "at", "by", "with", "i", "me", "my", "you", "your",
        "what", "where", "when", "how", "why", "which", "who"
    ]

    private static func isStopWord(_ s: String) -> Bool {
        return stopWords.contains(s.lowercased())
    }
}

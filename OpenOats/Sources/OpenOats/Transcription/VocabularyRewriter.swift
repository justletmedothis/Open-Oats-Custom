import Foundation

/// Rewrites recognized-text aliases to their preferred spellings using the
/// user's custom vocabulary — one rule per line in the form
/// "Preferred: alias1, alias2" (the same format the cloud backends send as
/// custom spelling). Lines without ":" are bare hotwords with no rewrite rule
/// and are ignored here. Matching is case-insensitive on word boundaries.
///
/// Used as a post-ASR pass for engines with no hotword/boost API of their own
/// (Apple Speech).
struct VocabularyRewriter: Sendable {
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let replacement: String
    }

    private let rules: [Rule]

    init(_ vocabulary: String) {
        var built: [Rule] = []
        for line in vocabulary.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(":") else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let preferred = parts[0].trimmingCharacters(in: .whitespaces)
            guard !preferred.isEmpty else { continue }
            for alias in parts[1].split(separator: ",") {
                let aliasTrimmed = alias.trimmingCharacters(in: .whitespaces)
                guard !aliasTrimmed.isEmpty,
                      aliasTrimmed.caseInsensitiveCompare(preferred) != .orderedSame else { continue }
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: aliasTrimmed) + "\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                built.append(Rule(
                    regex: regex,
                    replacement: NSRegularExpression.escapedTemplate(for: preferred)
                ))
            }
        }
        rules = built
    }

    var isEmpty: Bool { rules.isEmpty }

    func rewrite(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.replacement
            )
        }
        return result
    }
}

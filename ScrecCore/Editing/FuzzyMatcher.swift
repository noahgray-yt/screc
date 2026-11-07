import Foundation

/// Fuzzy matching for the ⌘K command palette (ARCHITECTURE §11): the query's characters must appear in
/// order in the text. Bonuses for matches at the start, at word starts and in a row; small penalty for gaps.
public enum FuzzyMatcher {
    /// Score of `query` against `text`, or nil if it does not match. Higher is better.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        let original = Array(text)
        var qi = 0, score = 0, lastMatch = -2
        for (i, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            var s = 1
            if i == 0 { s += 15 }
            let prev: Character? = i > 0 ? original[i - 1] : nil
            if let prev, prev == " " || prev == "-" || prev == "/" || prev == "›" || (prev.isLowercase && original[i].isUppercase) { s += 10 }
            if lastMatch == i - 1 { s += 5 } else if lastMatch >= 0 { s -= min(i - lastMatch - 1, 3) }
            score += s
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        // Prefer shorter texts when scores tie.
        return score * 100 - t.count
    }

    /// Best score over a label and its synonyms.
    public static func bestScore(_ query: String, label: String, synonyms: [String]) -> Int? {
        ([label] + synonyms).compactMap { score(query, in: $0) }.max()
    }
}

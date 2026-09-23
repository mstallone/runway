import SwiftUI

/// Compact replacement for unavailable metric rows. Available usage and local spend stay visible
/// below it; the provider header carries the warning or connect glyph. Manual actions can request
/// Keychain approval, while notices that require waiting omit the action.
struct ProviderErrorCardView: View {
    struct Copy: Equatable {
        var title: String
        var description: String
    }

    /// `.warning` offers Refresh; `.connect` offers Connect for a credential that exists but simply
    /// hasn't been loaded into this process yet — nothing is broken and nothing was denied.
    enum Style {
        case warning
        case connect
    }

    let message: String
    let isRefreshing: Bool
    /// The share-card export sets this false: a Refresh button in a static PNG is dead chrome, and
    /// the exported card already strips interactive elements (grips, spinners, toggles).
    var showsRefreshAction: Bool = true
    var style: Style = .warning
    let onRefresh: () -> Void

    var body: some View {
        let copy = Self.copy(for: message)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(copy.title)
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsRefreshAction {
                    Button(style == .connect ? "Connect" : "Refresh", action: onRefresh)
                        .controlSize(.small)
                        .disabled(isRefreshing)
                }
            }
            Text(copy.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Provider error strings follow a "Short statement. Guidance." shape ("Claude Code login
    /// found. Connect to load it; if macOS asks, choose Always Allow…"), so the first sentence
    /// becomes the title — title-cased, since it renders as one — and the rest the description. A
    /// message without that shape (an HTTP failure line) keeps a generic title so a long sentence
    /// never renders as bold headline text.
    static func copy(for message: String) -> Copy {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: ". ") {
            let title = String(trimmed[..<range.lowerBound])
            let description = String(trimmed[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !description.isEmpty {
                return Copy(title: titleCased(title), description: description)
            }
        }
        return Copy(title: "Can't Load Usage", description: trimmed)
    }

    /// Words kept lowercase mid-title (articles, short prepositions, conjunctions). The first and
    /// last words always capitalize, per standard title-case conventions.
    private static let lowercaseTitleWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "of", "on", "or", "the", "to", "with",
    ]

    /// Title-cases a sentence-case error statement ("Claude Code login found" → "Claude Code Login
    /// Found") so derived headings follow the same title rule as hardcoded ones. Words already
    /// carrying capitals past their first letter (macOS, product names) and code-quoted words
    /// (`claude`) pass through untouched.
    static func titleCased(_ statement: String) -> String {
        let words = statement.split(separator: " ")
        return words.enumerated().map { index, word in
            let text = String(word)
            if text.contains("`") || text.dropFirst().contains(where: \.isUppercase) {
                return text
            }
            let isEdgeWord = index == 0 || index == words.count - 1
            if !isEdgeWord, Self.lowercaseTitleWords.contains(text.lowercased()) {
                return text.lowercased()
            }
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        .joined(separator: " ")
    }
}

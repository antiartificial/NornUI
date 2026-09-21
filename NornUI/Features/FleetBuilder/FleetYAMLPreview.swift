import SwiftUI

/// Highlights generated YAML without changing its whitespace or copyable contents.
struct FleetYAMLPreview: View {
    let source: String
    @State private var highlighted = AttributedString()

    var body: some View {
        Text(highlighted)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .task(id: source) { highlighted = Self.highlight(source) }
    }

    private static let tokens = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|#[^\n]*|\b[A-Za-z_][A-Za-z0-9_.-]*(?=[ \t]*:)|\b(?:true|false|null)\b|(?<![\w.-])-?\b[0-9]+(?:\.[0-9]+)?\b(?![\w.-])"#
    )

    static func highlight(_ source: String) -> AttributedString {
        var text = AttributedString(source)
        for match in tokens.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source),
                  let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            let token = String(source[range])
            let color: Color
            if token.hasPrefix("#") { color = .secondary }
            else if token.hasPrefix("\"") || token.hasPrefix("'") { color = .green }
            else if ["true", "false", "null"].contains(token) { color = .purple }
            else if token.first?.isNumber == true || token.hasPrefix("-") { color = .orange }
            else { color = .blue }
            text[lower..<upper].foregroundColor = color
        }
        return text
    }
}

import Foundation

/// One node of the Telegraph "content" DOM: either bare text or an element
/// (`{tag, attrs?, children?}`). Mirrors the JSON shape `telegra.ph/api`
/// expects for `createPage`/`editPage`.
public enum TelegraphNode: Equatable, Sendable {
    case text(String)
    indirect case element(tag: String, attrs: [String: String] = [:], children: [TelegraphNode] = [])

    public var tag: String? {
        if case let .element(tag, _, _) = self { return tag }
        return nil
    }

    public var children: [TelegraphNode] {
        if case let .element(_, _, children) = self { return children }
        return []
    }
}

extension TelegraphNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag, attrs, children
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(), let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try .element(
            tag: container.decode(String.self, forKey: .tag),
            attrs: container.decodeIfPresent([String: String].self, forKey: .attrs) ?? [:],
            children: container.decodeIfPresent([TelegraphNode].self, forKey: .children) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case let .element(tag, attrs, children):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tag, forKey: .tag)
            if !attrs.isEmpty {
                try container.encode(attrs, forKey: .attrs)
            }
            if !children.isEmpty {
                try container.encode(children, forKey: .children)
            }
        }
    }
}

extension TelegraphNode {
    /// UTF-8 byte size of the serialized node array — what Telegraph's 64 KB
    /// content cap is measured against.
    public static func serializedByteCount(_ nodes: [TelegraphNode]) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(nodes).count) ?? 0
    }
}

import Foundation
import Testing

@testable import TubeFoldKit

// Markdown parsing into Telegraph nodes.
@Suite struct TelegraphMarkdownTests {
    @Test func headingsMapToH3AndH4() {
        #expect(TelegraphMarkdown.markdownToNodes("# Title") == [.element(tag: "h3", children: [.text("Title")])])
        #expect(TelegraphMarkdown.markdownToNodes("## Title") == [.element(tag: "h3", children: [.text("Title")])])
        #expect(TelegraphMarkdown.markdownToNodes("### Sub") == [.element(tag: "h4", children: [.text("Sub")])])
        #expect(TelegraphMarkdown.markdownToNodes("#### Sub") == [.element(tag: "h4", children: [.text("Sub")])])
    }

    @Test func unorderedAndOrderedLists() {
        let ul = TelegraphMarkdown.markdownToNodes("- one\n- two")
        #expect(ul == [.element(tag: "ul", children: [
            .element(tag: "li", children: [.text("one")]),
            .element(tag: "li", children: [.text("two")]),
        ])])

        let ol = TelegraphMarkdown.markdownToNodes("1. one\n2. two")
        #expect(ol == [.element(tag: "ol", children: [
            .element(tag: "li", children: [.text("one")]),
            .element(tag: "li", children: [.text("two")]),
        ])])
    }

    @Test func inlineFormatting() {
        let nodes = TelegraphMarkdown.markdownToNodes("Plain **bold** and *italic* and `code` and [text](https://e.com).")
        #expect(nodes == [.element(tag: "p", children: [
            .text("Plain "),
            .element(tag: "strong", children: [.text("bold")]),
            .text(" and "),
            .element(tag: "em", children: [.text("italic")]),
            .text(" and "),
            .element(tag: "code", children: [.text("code")]),
            .text(" and "),
            .element(tag: "a", attrs: ["href": "https://e.com"], children: [.text("text")]),
            .text("."),
        ])])
    }

    @Test func horizontalRuleAndCodeFence() {
        #expect(TelegraphMarkdown.markdownToNodes("---") == [.element(tag: "hr")])
        let fenced = TelegraphMarkdown.markdownToNodes("```\nline1\nline2\n```")
        #expect(fenced == [.element(tag: "pre", children: [.text("line1\nline2")])])
    }

    @Test func blockquote() {
        let nodes = TelegraphMarkdown.markdownToNodes("> quoted line one\n> quoted line two")
        #expect(nodes == [.element(tag: "blockquote", children: [.text("quoted line one quoted line two")])])
    }

    @Test func stripFrontMatter() {
        let doc = "---\ntitle: \"X\"\n---\n\n# Body\n\nText."
        let stripped = TelegraphMarkdown.stripFrontMatter(doc)
        #expect(stripped == "# Body\n\nText.")
        #expect(TelegraphMarkdown.stripFrontMatter("no front matter") == "no front matter")
    }

    @Test func frontMatterValue() {
        let doc = "---\ntitle: \"A \\\"quoted\\\" title\"\nduration_seconds: 90\nmodel: \"codex gpt-5.4\"\n---\n\nBody."
        #expect(TelegraphMarkdown.frontMatterValue(doc, key: "title") == "A \"quoted\" title")
        #expect(TelegraphMarkdown.frontMatterValue(doc, key: "duration_seconds") == "90")
        #expect(TelegraphMarkdown.frontMatterValue(doc, key: "model") == "codex gpt-5.4")
        #expect(TelegraphMarkdown.frontMatterValue(doc, key: "missing") == "")
        #expect(TelegraphMarkdown.frontMatterValue("no front matter", key: "title") == "")
    }

    @Test func noH1OrH2TagsEmitted() {
        let nodes = TelegraphMarkdown.markdownToNodes("# A\n## B\n### C")
        let tags = nodes.compactMap(\.tag)
        #expect(!tags.contains("h1"))
        #expect(!tags.contains("h2"))
        #expect(tags == ["h3", "h3", "h4"])
    }

    @Test func leadingTitleIsDropped() {
        #expect(TelegraphMarkdown.stripLeadingTitle("# Title\n\nBody.") == "Body.")
        #expect(TelegraphMarkdown.stripLeadingTitle("## Section\n\nBody.") == "## Section\n\nBody.")
        #expect(TelegraphMarkdown.stripLeadingTitle("Body only.") == "Body only.")
    }

    @Test func nestedInlineInsideLink() {
        let nodes = TelegraphMarkdown.inlineNodes("[**bold label**](https://e.com)")
        #expect(nodes == [.element(
            tag: "a",
            attrs: ["href": "https://e.com"],
            children: [.element(tag: "strong", children: [.text("bold label")])]
        )])
    }

    @Test func codeSpanWinsOverOtherInline() {
        let nodes = TelegraphMarkdown.inlineNodes("`**not bold**`")
        #expect(nodes == [.element(tag: "code", children: [.text("**not bold**")])])
    }

    @Test func nodeJSONRoundTrip() throws {
        let nodes: [TelegraphNode] = [
            .text("hello"),
            .element(tag: "p", children: [.text("x"), .element(tag: "a", attrs: ["href": "https://e.com"], children: [.text("l")])]),
            .element(tag: "hr"),
        ]
        let encoder = JSONEncoder()
        let data = try encoder.encode(nodes)
        let decoded = try JSONDecoder().decode([TelegraphNode].self, from: data)
        #expect(decoded == nodes)
        #expect(TelegraphNode.serializedByteCount(nodes) > 0)
    }
}

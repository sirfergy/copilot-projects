import assert from "node:assert/strict";
import test from "node:test";

import { bindings, documentShim, loadFragments, plain } from "./support/fragments.mjs";

const MARKDOWN_NAMES = [
  "MARKDOWN_MAX_LENGTH",
  "MARKDOWN_MAX_LINES",
  "MARKDOWN_INLINE_MAX_NODES",
  "MARKDOWN_INLINE_SEARCH_WINDOW",
  "normalizeMarkdownLineEndings",
  "markdownWithinRenderingLimits",
  "splitMarkdownTableRow",
  "markdownTableAlignments",
  "parseMarkdownBlocks",
  "markdownAnchor",
  "appendMarkdownInline",
  "boundedIndexOf",
];

function markdown() {
  const { document, FakeNode } = documentShim();
  const context = loadFragments(["markdown"], { document });
  return { ...bindings(context, MARKDOWN_NAMES), FakeNode };
}

test("markdownWithinRenderingLimits rejects oversized and pipe-heavy input", () => {
  const { markdownWithinRenderingLimits, MARKDOWN_MAX_LENGTH, MARKDOWN_MAX_LINES } = markdown();

  assert.equal(markdownWithinRenderingLimits("plain text"), true);
  assert.equal(markdownWithinRenderingLimits("a".repeat(MARKDOWN_MAX_LENGTH)), true);
  assert.equal(markdownWithinRenderingLimits("a".repeat(MARKDOWN_MAX_LENGTH + 1)), false);
  assert.equal(markdownWithinRenderingLimits("x\n".repeat(MARKDOWN_MAX_LINES)), false);
  // A table bomb is bounded by the pipe budget even though it is short enough
  // and has few enough lines to pass the other two limits.
  assert.equal(markdownWithinRenderingLimits("|".repeat(1001)), false);
  assert.equal(markdownWithinRenderingLimits("|".repeat(1000)), true);
});

test("markdownWithinRenderingLimits counts CRLF input as one line per row", () => {
  const { markdownWithinRenderingLimits, normalizeMarkdownLineEndings } = markdown();

  assert.equal(normalizeMarkdownLineEndings("a\r\nb\rc"), "a\nb\nc");
  // Without normalization a CRLF document would be counted twice over and
  // could fall off the line limit at half its real line count.
  assert.equal(markdownWithinRenderingLimits("x\r\n".repeat(400)), true);
});

test("splitMarkdownTableRow honours escaped pipes and strips edge cells", () => {
  const { splitMarkdownTableRow } = markdown();

  assert.deepStrictEqual(plain(splitMarkdownTableRow("| a | b |")), ["a", "b"]);
  assert.deepStrictEqual(plain(splitMarkdownTableRow("a | b")), ["a", "b"]);
  assert.deepStrictEqual(plain(splitMarkdownTableRow(String.raw`| a \| b | c |`)), ["a | b", "c"]);
});

test("markdownTableAlignments only accepts well-formed delimiter rows", () => {
  const { markdownTableAlignments } = markdown();

  assert.deepStrictEqual(plain(markdownTableAlignments("| --- | :--- | ---: | :---: |")), [
    "left",
    "left",
    "right",
    "center",
  ]);
  assert.equal(markdownTableAlignments("| -- | --- |"), null, "two dashes is not a delimiter row");
  assert.equal(markdownTableAlignments("| --x | --- |"), null);
  assert.equal(markdownTableAlignments("no pipes here"), null);
});

test("parseMarkdownBlocks keeps fenced code verbatim and closes on a matching fence", () => {
  const { parseMarkdownBlocks } = markdown();

  const blocks = plain(
    parseMarkdownBlocks(
      ["````js", "# not a heading", "```", "still code", "````", "after"].join("\n")
    )
  );
  const code = blocks.find((block) => block.type === "code");
  assert.ok(code, "expected a code block");
  assert.equal(code.text, "# not a heading\n```\nstill code");
  assert.ok(
    blocks.some((block) => block.type !== "code" && JSON.stringify(block).includes("after")),
    "content after the closing fence is parsed outside the code block"
  );
});

test("parseMarkdownBlocks recognises headings and list items", () => {
  const { parseMarkdownBlocks } = markdown();

  const blocks = plain(parseMarkdownBlocks(["## Title", "", "- one", "- two"].join("\n")));
  const heading = blocks.find((block) => block.type === "heading");
  assert.ok(heading, "expected a heading block");
  assert.equal(heading.level, 2);
  const list = blocks.find((block) => block.type === "list");
  assert.ok(list, "expected a list block");
  assert.equal(list.items.length, 2);
});

test("markdownAnchor rejects every non-http(s) scheme", () => {
  const { markdownAnchor } = markdown();

  for (const href of [
    "javascript:alert(1)",
    "data:text/html,<script>",
    "vbscript:msgbox(1)",
    "file:///etc/passwd",
    "not a url",
  ]) {
    assert.equal(markdownAnchor(href, "label"), null, `${href} must not become a link`);
  }

  const anchor = markdownAnchor("https://github.com/copilot", "Copilot");
  assert.equal(anchor.tagName, "a");
  assert.equal(anchor.href, "https://github.com/copilot");
  assert.equal(anchor.rel, "noopener noreferrer");
  assert.equal(anchor.target, "_blank");
  assert.equal(anchor.textContent, "Copilot");
});

test("appendMarkdownInline bounds DOM amplification from repeated markers", () => {
  const { appendMarkdownInline, MARKDOWN_INLINE_MAX_NODES, FakeNode } = markdown();

  const parent = new FakeNode("div");
  appendMarkdownInline(parent, "*".repeat(20000));
  assert.ok(
    parent.countNodes() <= MARKDOWN_INLINE_MAX_NODES + 2,
    `expected a bounded node count, got ${parent.countNodes()}`
  );
});

test("boundedIndexOf never scans past the search window", () => {
  const { boundedIndexOf, MARKDOWN_INLINE_SEARCH_WINDOW } = markdown();

  const haystack = `${"a".repeat(MARKDOWN_INLINE_SEARCH_WINDOW + 10)}](`;
  assert.equal(boundedIndexOf(haystack, "](", 0), -1, "a hit beyond the window is not reported");
  assert.equal(
    boundedIndexOf(haystack, "](", MARKDOWN_INLINE_SEARCH_WINDOW + 10),
    MARKDOWN_INLINE_SEARCH_WINDOW + 10
  );
  assert.equal(boundedIndexOf("abc", "c", 3), -1, "a start past the end returns -1");
});

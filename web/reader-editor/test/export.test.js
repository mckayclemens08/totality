import { test } from "node:test";
import assert from "node:assert/strict";
import { exportModel, frontMatter } from "../src/exportModel.js";
import { plainEngine, cleanItems, citedKeys, styles } from "../src/cite.js";

const thesis = `---
title: "Why teachers leave rural schools"
author:
  - Ana Ortiz
  - Sam Reyes
date: May 2027
csl: apa
---

# Why teachers leave {#sec:why}

Turnover is *less* about **pay** than about how a school is run [@ingersoll2001, p. 501].[^1] As
[[Retention notes|our notes]] put it, the \`exit survey\` says the same, see
[the survey](https://example.org/survey) and @sec:why.^[Asked in spring.]

> A school is its leadership.

1. Pay
2. Isolation
   - Distance to town
- [x] Coded the interviews

| District | Left |
|---|---|
| North | 12 |

![Turnover by district](turnover.png){#fig:turnover}

\\newpage

\`\`\`
raw <b>code</b>
\`\`\`

Line one\\
line two

[^1]: Ingersoll's *analysis* of the national survey.
[^unused]: Never referred to.`;

const library = cleanItems([
  { id: "ingersoll2001", type: "article-journal", title: "Teacher Turnover and Teacher Shortages",
    author: [{ family: "Ingersoll", given: "Richard M." }], issued: { "date-parts": [[2001]] } },
]);
const engine = plainEngine(library);
const model = exportModel(thesis, {
  citation: (keys, locatorText, narrative) => engine.citation(keys, locatorText, narrative, "apa"),
  bibliography: () => ({ heading: styles.apa.heading, entries: engine.bibliography(citedKeys(thesis), "apa") }),
});

const words = (runs) => runs.map((run) => run.text).join("");

test("front matter gives the title page its title, authors and date", () => {
  assert.deepEqual(model.meta, { title: "Why teachers leave rural schools", author: "Ana Ortiz, Sam Reyes", date: "May 2027" });
  assert.deepEqual(frontMatter("No front matter here."), {});
  assert.deepEqual(frontMatter("---\nscript: <x>\ntitle: 'Plain'\n---\n"), { title: "Plain" });
});

test("headings lose their marks and labels", () => {
  assert.deepEqual(model.blocks[0], { t: "h", level: 1, runs: [{ text: "Why teachers leave" }] });
});

test("a paragraph keeps its emphasis, and citations, links and notes are already words", () => {
  const paragraph = model.blocks[1];
  assert.equal(paragraph.t, "p");
  assert.equal(words(paragraph.runs),
    "Turnover is less about pay than about how a school is run (Ingersoll, 2001, p. 501). As our notes put it, the exit survey says the same, see the survey and “Why teachers leave”.");
  assert.deepEqual(paragraph.runs.find((r) => r.text === "less"), { text: "less", i: true });
  assert.deepEqual(paragraph.runs.find((r) => r.text === "pay"), { text: "pay", b: true });
  assert.deepEqual(paragraph.runs.find((r) => r.text === "exit survey"), { text: "exit survey", code: true });
  assert.deepEqual(paragraph.runs.find((r) => r.text === "the survey"), { text: "the survey", href: "https://example.org/survey" });
  assert.deepEqual(paragraph.runs.filter((r) => r.note).map((r) => r.note), [1, 2]);
});

test("notes are numbered as they're referred to, and one never referred to is left out", () => {
  assert.deepEqual(model.notes.map((n) => [n.number, words(n.blocks[0].runs)]), [
    [1, "Ingersoll's analysis of the national survey."],
    [2, "Asked in spring."],
  ]);
});

test("quotes, nested lists, tasks and tables keep their shape", () => {
  const [quote, ordered, tasks, table] = model.blocks.slice(2, 6);
  assert.equal(quote.t, "quote");
  assert.equal(words(quote.blocks[0].runs), "A school is its leadership.");
  assert.equal(ordered.ordered, true);
  assert.equal(ordered.start, 1);
  assert.deepEqual(ordered.items.map((item) => words(item.blocks[0].runs)), ["Pay", "Isolation"]);
  assert.equal(ordered.items[1].blocks[1].t, "list");
  assert.equal(words(ordered.items[1].blocks[1].items[0].blocks[0].runs), "Distance to town");
  assert.equal(tasks.items[0].task, true);
  assert.equal(words(tasks.items[0].blocks[0].runs), "Coded the interviews");
  assert.deepEqual(table.header.map(words), ["District", "Left"]);
  assert.deepEqual(table.rows.map((row) => row.map(words)), [["North", "12"]]);
});

test("a lone image is a numbered figure, a page break is kept, and code stays raw text", () => {
  const [figure, pagebreak, code, lines] = model.blocks.slice(6, 10);
  assert.deepEqual(figure, { t: "figure", alt: "Turnover by district", number: 1, src: "turnover.png" });
  assert.deepEqual(pagebreak, { t: "pagebreak" });
  assert.deepEqual(code, { t: "code", text: "raw <b>code</b>" });
  assert.deepEqual(lines.runs, [{ text: "Line one" }, { text: "", br: true }, { text: "line two" }]);
  assert.equal(model.blocks.length, 10);
});

test("the bibliography lists what's cited", () => {
  assert.equal(model.bibliography.heading, "References");
  assert.equal(model.bibliography.entries.length, 1);
  assert.match(model.bibliography.entries[0], /^Ingersoll/);
});

test("markup in a doc stays text, and only web and mail links survive", () => {
  const hostile = exportModel("<script>alert(1)</script> and [x](javascript:alert(1)) &amp; [y](file:///etc/passwd)", {
    citation: () => "", bibliography: () => ({ heading: "", entries: [] }),
  });
  const runs = hostile.blocks.flatMap((b) => b.runs || []);
  assert.ok(runs.every((run) => !run.href));
  assert.ok(words(runs).includes("&"));
});

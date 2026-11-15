import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { citeprocEngine, cslLocator, styleFiles } from "../src/citeproc.js";
import { cleanItems } from "../src/cite.js";

const read = (name) => readFileSync(new URL(`../csl/${name}`, import.meta.url), "utf8");
const sources = {
  styles: Object.fromEntries(Object.entries(styleFiles).map(([short, file]) => [short, read(`${file}.csl`)])),
  locale: read("locales-en-US.xml"),
};
const library = cleanItems([
  {
    id: "ingersoll2001", type: "article-journal",
    title: "Teacher turnover and teacher shortages: An organizational analysis",
    "container-title": "American Educational Research Journal", volume: "38", issue: "3", page: "499-534",
    author: [{ family: "Ingersoll", given: "Richard M." }], issued: { "date-parts": [[2001]] },
    DOI: "10.3102/00028312038003499",
  },
  {
    id: "bourdieu1984", type: "book", title: "Distinction: A social critique of the judgement of taste",
    publisher: "Harvard University Press", "publisher-place": "Cambridge, MA",
    author: [{ family: "Bourdieu", given: "Pierre" }, { family: "Nice", given: "Richard" }], issued: { "date-parts": [[1984]] },
  },
]);
const engine = citeprocEngine(library, sources);

test("locators become CSL labels", () => {
  assert.deepEqual(cslLocator("p. 501"), { locator: "501", label: "page" });
  assert.deepEqual(cslLocator("ch. 2"), { locator: "2", label: "chapter" });
  assert.deepEqual(cslLocator("12–14"), { locator: "12–14", label: "page" });
  assert.deepEqual(cslLocator("emphasis added"), { suffix: ", emphasis added" });
});

test("APA citations and bibliography come from the real style", () => {
  const keys = [{ key: "ingersoll2001", suppressAuthor: false }];
  assert.equal(engine.citation(keys, "p. 501", false, "apa"), "(Ingersoll, 2001, p. 501)");
  assert.equal(engine.citation(keys, "", true, "apa"), "Ingersoll (2001)");
  assert.equal(engine.citation([{ key: "ingersoll2001", suppressAuthor: true }], "", false, "apa"), "(2001)");
  const entries = engine.bibliography(["ingersoll2001", "bourdieu1984"], "apa");
  assert.equal(entries.length, 2);
  assert.ok(entries[0].startsWith("Bourdieu, P., & Nice, R. (1984)."), entries[0]);
  assert.ok(entries[1].includes("https://doi.org/10.3102/00028312038003499"), entries[1]);
});

test("MLA and Chicago follow their own forms", () => {
  const keys = [{ key: "ingersoll2001", suppressAuthor: false }];
  assert.equal(engine.citation(keys, "p. 501", false, "mla"), "(Ingersoll 501)");
  assert.equal(engine.citation(keys, "p. 501", false, "chicago"), "(Ingersoll 2001, 501)");
  assert.ok(engine.bibliography(["ingersoll2001"], "mla")[0].startsWith("Ingersoll, Richard M. “Teacher Turnover"));
});

test("an unknown key falls back to the plain form instead of failing", () => {
  assert.equal(engine.citation([{ key: "nobody2020", suppressAuthor: false }], "", false, "apa"), "(?nobody2020)");
  assert.deepEqual(engine.bibliography(["nobody2020"], "apa"), []);
});

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync("src/tokens.css", "utf8");
const swift = readFileSync("../../Sources/TotalityUI/Tokens.swift", "utf8");
const lum = (hex) => {
  const c = [0, 2, 4].map((i) => parseInt(hex.slice(1 + i, 3 + i), 16) / 255)
    .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

test("every theme's colours match the app's tokens and meet AA", () => {
  const blocks = [...css.matchAll(/:root[^{]*\{([^}]*)\}/g)].map((m) => m[1]);
  assert.equal(blocks.length, 6);
  for (const b of blocks) {
    const v = Object.fromEntries([...b.matchAll(/--([a-z-]+): (#[0-9a-f]{6})/g)].map((m) => [m[1], m[2]]));
    for (const hex of Object.values(v)) assert.ok(swift.toLowerCase().includes("0x" + hex.slice(1)), `${hex} not in Tokens.swift`);
    assert.ok(ratio(v["text-primary"], v.surface) >= 4.5);
    assert.ok(ratio(v["text-secondary"], v.surface) >= 4.5);
    assert.ok(ratio(v["text-secondary"], v.bg) >= 4.5);
    assert.ok(ratio(v["accent-on"], v.accent) >= 4.5);
  }
});

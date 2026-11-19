// Makes docs/reader-web-vectors.json with the website's own code: docs created and saved the way the website
// does it. Swift's ReaderWebEditVectorsTests opens every one in the real ReaderVault.
// Run `node test/make-reader-vectors.mjs` after changing how the website writes notes. Nonces and IDs are fixed.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

await build({ entryPoints: ["test/support/reader.ts"], bundle: true, format: "esm", outfile: "dist-test/reader-support.mjs", platform: "node", logLevel: "silent" });
const R = await import("../dist-test/reader-support.mjs");

export function makeWebVectors() {
  const phone = JSON.parse(readFileSync("../../docs/reader-vectors.json", "utf8"));
  const root = R.fromHex(phone.rootKey, 32);
  const owner = "0f1e2d3c-4b5a-4968-8778-695a4b3c2d1e";
  let n = 0;
  R.setIDMaker(() => `D0C00000-0000-4000-8000-${String(++n).padStart(12, "0")}`);
  const now = Date.UTC(2026, 10, 19, 14, 5);
  const items = [];
  const seal = (raw, text, wordTarget = null) => {
    const id = String(raw.id).toLowerCase();
    const k = items.length * 2 + 1;
    const s = R.sealNote(raw, text, owner, R.objectKeyFromRoot(root, "metadata", id), R.objectKeyFromRoot(root, "content", id), [new Uint8Array(24).fill(k), new Uint8Array(24).fill(k + 1)]);
    items.push({ id, owner, meta: Buffer.from(s.meta).toString("base64"), body: Buffer.from(s.body).toString("base64"), hash: s.hash, bodyHash: s.bodyHash, blob: s.blob,
      title: raw.title, text, mime: raw.mime, byteCount: raw.byteCount, wordTarget, editorOpens: R.editable(raw) });
    return s;
  };

  // 1. A new doc, as "New doc" makes it: empty, in the editor's Markdown.
  const created = R.newNote("", now);
  seal(created, "");

  // 2. The same doc written in the formatted editor and saved: headings, emphasis, lists, a link, Unicode.
  const text = "# Reading notes\n\nThe state is the *actuality* of the **ethical** Idea.\n\n- first point\n- second point\n\n1. one\n2. two\n\n> A quote.\n\nSee [the SEP entry](https://plato.stanford.edu/entries/hegel/). Ünïcode ✓ <b>not html</b>\n";
  seal(R.saved(created, "Reading notes", text, now + 60_000), text);

  // 3. A phone doc edited on the website: its unknown parts and word target ride along.
  const e = phone.entries[0];
  const original = JSON.parse(new TextDecoder().decode(R.openBlob(Buffer.from(e.meta, "base64"), R.objectKeyFromRoot(root, "metadata", e.id), e.id)));
  const withTarget = { ...original, wordTarget: 5000, futurePart: { kept: true } };
  const edited = "# Seminar paper draft\n\nRewritten on the website.\n";
  seal(R.saved(withTarget, "Seminar paper draft (v2)", edited, now + 120_000), edited, 5000);

  // 4. The conflict copy the editor makes when the doc changed underneath it.
  const copy = R.newNote(R.copyTitle("Reading notes"), now + 180_000);
  seal(R.saved(copy, copy.title, "My words from the website.", now + 180_000), "My words from the website.");

  return { note: "Made by web/site/test/make-reader-vectors.mjs from the website's own code. Test key only.", rootKey: phone.rootKey, items };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  writeFileSync("../../docs/reader-web-vectors.json", JSON.stringify(makeWebVectors(), null, 2) + "\n");
  console.log("wrote docs/reader-web-vectors.json");
}

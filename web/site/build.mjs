// Bundles src/ into dist/ with hashed names and subresource integrity, copies public/.
import { build } from "esbuild";
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";

const blobUrl = (process.env.BLOB_URL ?? "https://usetotality.com/blobs/").replace(/\/*$/, "/");
if (!/^https:\/\/[a-z0-9.-]+(\/[a-z0-9/_-]*)?$/i.test(blobUrl)) throw new Error("BLOB_URL must be an https address");
const supabaseUrl = (process.env.SUPABASE_URL ?? "").replace(/\/+$/, "");
if (supabaseUrl && !/^https:\/\/[a-z0-9.-]+$/i.test(supabaseUrl)) throw new Error("SUPABASE_URL must be an https origin");

await rm("dist", { recursive: true, force: true });
await mkdir("dist", { recursive: true });
await build({
  entryPoints: { app: "src/main.ts" },
  bundle: true, minify: true, format: "esm", target: "es2022",
  outdir: "dist", entryNames: "[name]", legalComments: "none",
  // Supabase's public URL and publishable key (the same two the iPhone app is built with). Not secrets.
  define: { __SUPABASE_URL__: JSON.stringify(supabaseUrl), __SUPABASE_KEY__: JSON.stringify(process.env.SUPABASE_PUBLISHABLE_KEY ?? ""), __BLOB_URL__: JSON.stringify(blobUrl) },
});
await cp("public", "dist", { recursive: true });
// The page may talk to the account server and nowhere else.
const headersFile = (await readFile("dist/_headers", "utf8")).replace("connect-src 'self'", `connect-src 'self'${supabaseUrl ? " " + supabaseUrl : ""} ${new URL(blobUrl).origin}`);
await writeFile("dist/_headers", headersFile);

const sri = (bytes) => "sha384-" + createHash("sha384").update(bytes).digest("base64");
const hashed = {};
for (const file of await readdir("dist")) {
  if (file !== "app.js" && file !== "app.css") continue;
  const bytes = await readFile(`dist/${file}`);
  const [stem, ext] = file.split(".");
  const name = `${stem}.${createHash("sha256").update(bytes).digest("hex").slice(0, 10)}.${ext}`;
  await rename(`dist/${file}`, `dist/${name}`);
  hashed[file] = { name, integrity: sri(bytes) };
}

let html = await readFile("src/index.html", "utf8");
const css = hashed["app.css"], js = hashed["app.js"];
html = html
  .replace('<link rel="stylesheet" href="/app.css">', `<link rel="stylesheet" href="/${css.name}" integrity="${css.integrity}">`)
  .replace('<script type="module" src="/app.js"></script>', `<script type="module" src="/${js.name}" integrity="${js.integrity}"></script>`);
await writeFile("dist/index.html", html);

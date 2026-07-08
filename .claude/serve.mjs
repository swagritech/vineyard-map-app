// Dev-only static server mirroring the production _redirects rules:
//   /customers/* -> real files (no rewrite)
//   /*           -> index.html (SPA fallback)
// Used by .claude/launch.json for local preview. Not deployed.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, extname, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const port = Number(process.env.PORT || 8123);
const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".json": "application/json",
  ".geojson": "application/geo+json",
  ".webmanifest": "application/manifest+json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".ico": "image/x-icon"
};

createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://localhost");
    let p = decodeURIComponent(url.pathname);
    if (p.endsWith("/")) p += "index.html";
    const filePath = normalize(join(root, p));
    if (!filePath.startsWith(normalize(root))) { res.writeHead(403); res.end(); return; }
    try {
      const data = await readFile(filePath);
      res.writeHead(200, { "Content-Type": mime[extname(filePath)] || "application/octet-stream" });
      res.end(data);
    } catch {
      if (p.startsWith("/customers/")) { res.writeHead(404); res.end("not found"); return; }
      const data = await readFile(join(root, "index.html"));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(data);
    }
  } catch (e) {
    res.writeHead(500); res.end(String(e));
  }
}).listen(port, () => console.log(`vineyard dev server on http://localhost:${port}`));

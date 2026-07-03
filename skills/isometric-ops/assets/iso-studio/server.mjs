// Tiny zero-dependency static server for iso-studio (the isometric-ops scene composer).
// Serves its OWN directory so the app (index.html) loads same-origin. Run:
//   node server.mjs            (then open http://localhost:4323)
//   PORT=8080 node server.mjs  (PORT env overrides the port)
// No build step, no dependencies — just Node stdlib. Pattern precedent: tools/svg-brand-tuner/server.mjs.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, extname, normalize, sep } from 'node:path';

const root = dirname(fileURLToPath(import.meta.url));
const port = Number(process.env.PORT) || 4323;
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
};

createServer(async (req, res) => {
  try {
    let p = decodeURIComponent((req.url || '/').split('?')[0]);
    if (p === '/' || p === '') p = '/index.html';
    // /palettes/* is served from the sibling assets/palettes/ dir ONLY (the
    // three-tone presets live at skills/isometric-ops/assets/palettes/). The
    // prefix is stripped and requests resolve against that dir specifically, so
    // /palettes/../anything cannot reach other files in assets/.
    const isPal = p.startsWith('/palettes/');
    const base = isPal ? normalize(join(root, '..', 'palettes')) : root;
    const file = normalize(join(base, isPal ? p.slice('/palettes'.length) : p));
    // Path-traversal guard: resolved path must stay inside its base dir.
    if (file !== base && !file.startsWith(base + sep)) {
      res.writeHead(403);
      return res.end('forbidden');
    }
    const data = await readFile(file);
    res.writeHead(200, {
      'content-type': TYPES[extname(file)] || 'application/octet-stream',
      'cache-control': 'no-store',
    });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end('not found');
  }
}).listen(port, () => console.log(`iso-studio → http://localhost:${port}`));

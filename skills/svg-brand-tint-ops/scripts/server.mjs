#!/usr/bin/env node
// Zero-dependency static server for the SVG brand-tint studio (a designer tool).
//
// Usage:   node server.mjs [--root DIR] [--port N] [--open]
// Input:   flags only (no stdin). ROOT / PORT env vars are honoured as fallbacks.
// Output:  stdout stays clean (data contract) — nothing but --help text.
// Stderr:  the "serving on <url>" status line, warnings, and errors.
// Exit:    0 ok / help, 2 usage (bad flag), 5 precondition (port in use / no web root).
//
// The web root defaults to the sibling assets/ directory (where index.html lives in
// the skill layout); falls back to the script's own directory for a flat checkout.
// Drop a `diagram.svg` (or `sample.svg`) into the served root to have it auto-load.
//
// Examples:
//   node server.mjs                       # serve ../assets on http://localhost:4322
//   PORT=8080 node server.mjs             # pick a port via env
//   node server.mjs --root ./my-icons     # serve a folder of your own SVGs/PNGs
//   node server.mjs --port 0              # ephemeral port (printed to stderr) — used by tests

import { createServer } from 'node:http';
import { readFile, access } from 'node:fs/promises';
import { constants as FS } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, extname, normalize, resolve, sep } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
};

const HELP = `svg-brand-tint studio — zero-dependency static server

Usage:   node server.mjs [--root DIR] [--port N] [--open]

Options:
  --root DIR   Directory to serve (default: sibling assets/, else this script's dir)
  --port N     Port to listen on (default: $PORT or 4322; 0 = ephemeral)
  --open       Print the URL only (no server) — for scripting
  -h, --help   Show this help and exit

Examples:
  node server.mjs                     # serve the studio on http://localhost:4322
  PORT=8080 node server.mjs           # choose a port via env var
  node server.mjs --root ./my-icons   # serve your own folder of SVGs / PNGs
  node server.mjs --port 0            # ephemeral port (printed to stderr)
`;

function parseArgs(argv) {
  const out = { root: process.env.ROOT || '', port: process.env.PORT, open: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') return { help: true };
    else if (a === '--open') out.open = true;
    else if (a === '--root') out.root = argv[++i] ?? '';
    else if (a === '--port') out.port = argv[++i] ?? '';
    else if (a.startsWith('--root=')) out.root = a.slice(7);
    else if (a.startsWith('--port=')) out.port = a.slice(7);
    else return { error: `unknown argument: ${a}` };
  }
  return out;
}

async function hasIndex(dir) {
  try { await access(join(dir, 'index.html'), FS.R_OK); return true; } catch { return false; }
}

async function pickRoot(explicit) {
  if (explicit) return resolve(explicit);
  const assets = resolve(HERE, '..', 'assets');
  if (await hasIndex(assets)) return assets;
  return HERE;
}

const args = parseArgs(process.argv.slice(2));
if (args.help) { process.stdout.write(HELP); process.exit(0); }
if (args.error) { process.stderr.write(`error: ${args.error}\n\n${HELP}`); process.exit(2); }

const root = await pickRoot(args.root);
if (!(await hasIndex(root))) {
  process.stderr.write(`error: no index.html found in web root: ${root}\n` +
    `hint: run from the skill (serves ../assets) or pass --root DIR\n`);
  process.exit(5);
}

const port = Number(args.port) || (args.port === '0' ? 0 : 4322);

if (args.open) {
  process.stderr.write(`web root: ${root}\nopen:     http://localhost:${port || 4322}/\n`);
  process.exit(0);
}

const server = createServer(async (req, res) => {
  try {
    let p = decodeURIComponent((req.url || '/').split('?')[0]);
    if (p === '/' || p === '') p = '/index.html';
    const file = normalize(join(root, p));
    if (file !== root && !file.startsWith(root + sep)) {   // path-traversal guard
      res.writeHead(403); return res.end('forbidden');
    }
    const data = await readFile(file);
    res.writeHead(200, {
      'content-type': TYPES[extname(file).toLowerCase()] || 'application/octet-stream',
      'cache-control': 'no-store',
    });
    res.end(data);
  } catch {
    res.writeHead(404); res.end('not found');
  }
});

server.on('error', (err) => {
  if (err && err.code === 'EADDRINUSE') {
    process.stderr.write(`error: port ${port} is already in use — set PORT or pass --port N\n`);
    process.exit(5);
  }
  process.stderr.write(`error: ${err && err.message ? err.message : err}\n`);
  process.exit(1);
});

server.listen(port, () => {
  const actual = server.address().port;
  process.stderr.write(`svg-brand-tint studio -> http://localhost:${actual}/  (root: ${root})\n`);
});

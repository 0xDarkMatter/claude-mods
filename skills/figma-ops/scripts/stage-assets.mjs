#!/usr/bin/env node
// stage-assets.mjs — turn a folder (or shortlist) of images into planner input.
//
// Closes the gap between "images on disk" and plan-layout.mjs: copies each image to a
// staging directory under a meaningful slug (the slug becomes the Figma layer name on
// upload), reads TRUE pixel dimensions from the file header, and emits the
// { centre, images[] } JSON the planner consumes. Originals are never moved.
//
// Why the slug matters: upload_assets names the layer after the uploaded filename, so
// IMG_0997.PNG becomes a layer called IMG_0997 forever. Staging renames once, up front.
//
// Why dimensions come from the header: uploaded frames land as 400x300 FILL regardless
// of source; the planner needs the real aspect ratio or every image is cropped.
//
// Arms (N/S/E/W) are a HUMAN grouping decision. This script leaves arm: null unless a
// --arms map is supplied, and exits 10 to say "a person still has to sort these" —
// the output is complete otherwise.
//
// Contract (SKILL-RESOURCE-PROTOCOL): stdout data only; diagnostics on stderr.
//   0  staged, every image has a subject and an arm
//   2  usage error
//   3  bad input (unreadable file, unsupported type, bad map JSON)
//  10  staged, but some images need a human subject and/or arm (output still emitted)
//
// Slug grammar:  NN-<source>-<subject>.<ext>
//   NN       two-digit order (input order; keeps upload order == layer order)
//   source   shotcraft run dir domain ("conductorai.com" -> "conductorai"), else "ref"
//   subject  shotcraft: the page/section name parsed from <hash>-<site>-<device>-<page>--<kind>
//            otherwise the original basename if it looks meaningful, else "needs-name"
//   Override any subject with --names FILE ({ "<original basename>": "subject" }).

import { readFileSync, readdirSync, statSync, mkdirSync, copyFileSync, existsSync } from 'node:fs';
import { basename, dirname, extname, join, resolve } from 'node:path';

const HELP = `stage-assets.mjs — stage images for plan-layout.mjs and upload_assets

Usage:
  node stage-assets.mjs (--dir DIR | --list FILE)... --out DIR [options] [--json]

Inputs (repeatable, order preserved):
  --dir DIR           every png/jpg/jpeg/gif in DIR (sorted by name)
  --list FILE         newline-separated image paths ("-" = stdin)

Options:
  --out DIR           staging directory (created)             (required)
  --names FILE        JSON { "<original basename>": "subject" } overrides
  --arms FILE         JSON { "<slug or basename>": "N|S|E|W" }
  --centre WxH        centre element size                     (default: 1040x1040)
  --start N           first sequence number                   (default: 1)
  --json              emit planner JSON (default: table)
  -h, --help          this text

Exit codes: 0 ok · 2 usage · 3 bad input · 10 needs human subject/arm

EXAMPLES:
  node stage-assets.mjs --list shortlist.txt --dir E:/refs --out ./staged --json > board.json
  node stage-assets.mjs --dir ./staged-src --out ./staged --names names.json --arms arms.json --json
  node stage-assets.mjs --list - --out ./staged < shortlist.txt
`;

// === ARGS ===================================================================
function usage(m) { process.stderr.write(`stage-assets: ${m}\n\n${HELP}`); process.exit(2); }
function bad(m) { process.stderr.write(`stage-assets: ${m}\n`); process.exit(3); }

function parseArgs(argv) {
  const o = { inputs: [], out: null, names: null, arms: null, centre: { w: 1040, h: 1040 }, start: 1, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i], v = argv[i + 1];
    switch (a) {
      case '-h': case '--help': process.stdout.write(HELP); process.exit(0);
      case '--dir': o.inputs.push({ kind: 'dir', v }); i++; break;
      case '--list': o.inputs.push({ kind: 'list', v }); i++; break;
      case '--out': o.out = v; i++; break;
      case '--names': o.names = v; i++; break;
      case '--arms': o.arms = v; i++; break;
      case '--centre': { const m = /^(\d+)x(\d+)$/.exec(v || ''); if (!m) usage('--centre wants WxH'); o.centre = { w: +m[1], h: +m[2] }; i++; break; }
      case '--start': o.start = Number(v); if (!Number.isInteger(o.start)) usage('--start wants an integer'); i++; break;
      case '--json': o.json = true; break;
      default: usage(`unknown option ${a}`);
    }
  }
  if (!o.inputs.length) usage('at least one --dir or --list is required');
  if (!o.out) usage('--out is required');
  return o;
}

// === INPUT ==================================================================
const IMG_EXT = new Set(['.png', '.jpg', '.jpeg', '.gif']);

function collect(inputs) {
  const files = [];
  for (const { kind, v } of inputs) {
    if (kind === 'dir') {
      if (!existsSync(v) || !statSync(v).isDirectory()) bad(`--dir ${v} is not a directory`);
      for (const f of readdirSync(v).sort()) if (IMG_EXT.has(extname(f).toLowerCase())) files.push(resolve(v, f));
    } else {
      let raw;
      try { raw = v === '-' ? readFileSync(0, 'utf8') : readFileSync(v, 'utf8'); } catch (e) { bad(`cannot read list ${v}: ${e.message}`); }
      for (const line of raw.split(/\r?\n/)) {
        const p = line.trim(); if (!p || p.startsWith('#')) continue;
        if (!existsSync(p)) bad(`listed file not found: ${p}`);
        files.push(resolve(p));
      }
    }
  }
  if (!files.length) bad('no images found');
  return files;
}

function readMap(path, what) {
  if (!path) return {};
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch (e) { bad(`bad ${what} JSON ${path}: ${e.message}`); }
}

// === DIMENSIONS =============================================================
// PNG: IHDR width/height, big-endian uint32 at 16 and 20.
// JPEG: walk markers to the first SOFn (C0–CF except C4/C8/CC): height @+5, width @+7.
// GIF: logical screen width/height, little-endian uint16 at 6 and 8.
function dims(buf, ext) {
  if (ext === '.png') {
    if (buf.length < 24 || buf.readUInt32BE(0) !== 0x89504e47) return null;
    return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
  }
  if (ext === '.jpg' || ext === '.jpeg') {
    if (buf.length < 4 || buf[0] !== 0xFF || buf[1] !== 0xD8) return null;
    let o = 2;
    while (o + 9 < buf.length) {
      if (buf[o] !== 0xFF) { o++; continue; }
      const m = buf[o + 1];
      if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) return { h: buf.readUInt16BE(o + 5), w: buf.readUInt16BE(o + 7) };
      if (m === 0xD8 || m === 0x01 || (m >= 0xD0 && m <= 0xD7)) { o += 2; continue; }
      o += 2 + buf.readUInt16BE(o + 2);
    }
    return null;
  }
  if (ext === '.gif') {
    if (buf.length < 10 || buf.toString('ascii', 0, 3) !== 'GIF') return null;
    return { w: buf.readUInt16LE(6), h: buf.readUInt16LE(8) };
  }
  return null;
}

// === SLUGS ==================================================================
const slugify = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 48) || 'needs-name';

// shotcraft: <hash6>-<site>-<device>-<page>--<kind>.png inside shotcraft_<domain>/<device>/
const SHOT = /^[0-9a-f]{6}-(.+?)-(macbook|ipad|iphone|[a-z0-9]+)-(.+?)--([a-z]+)$/i;
// generic camera/UUID names carry no subject
const MEANINGLESS = /^(img[_-]?\d+|dsc[_-]?\d+|screenshot.*|image\d*|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;

function describe(file) {
  const base = basename(file, extname(file));
  const runDir = dirname(dirname(file));
  const runName = basename(runDir);
  let source = 'ref', subject, needsName = false;
  const sm = SHOT.exec(base);
  if (sm && /^shotcraft_/.test(runName)) {
    source = slugify(runName.replace(/^shotcraft_/, '').replace(/\.[a-z]+$/i, ''));
    // page name minus shotcraft's own scaffolding: "sectn-04-" ranking prefix, a
    // repeated site name, and the kind suffix unless it is an element crop.
    let page = sm[3].replace(/^sectn-\d+-/i, '');
    if (page.toLowerCase().startsWith(source + '-')) page = page.slice(source.length + 1);
    const kind = sm[4].toLowerCase();
    const isElement = !['full', 'viewport', 'section', 'scroll'].includes(kind);
    subject = slugify(`${page}${isElement ? '-' + kind : ''}`);
  } else if (MEANINGLESS.test(base)) {
    subject = 'needs-name'; needsName = true;
  } else {
    subject = slugify(base);
  }
  return { source, subject, needsName };
}

// === MAIN ===================================================================
const o = parseArgs(process.argv.slice(2));
const files = collect(o.inputs);
const names = readMap(o.names, '--names');
const arms = readMap(o.arms, '--arms');
mkdirSync(o.out, { recursive: true });

const images = [];
let needsHuman = 0;
files.forEach((file, idx) => {
  const ext = extname(file).toLowerCase();
  let buf; try { buf = readFileSync(file); } catch (e) { bad(`cannot read ${file}: ${e.message}`); }
  const d = dims(buf, ext);
  if (!d || !(d.w > 0 && d.h > 0)) bad(`cannot read dimensions of ${file} (unsupported or corrupt)`);

  const { source, subject: auto, needsName } = describe(file);
  const orig = basename(file);
  const subject = names[orig] ? slugify(names[orig]) : auto;
  const nn = String(o.start + idx).padStart(2, '0');
  const slug = `${nn}-${source}-${subject}`;
  const staged = join(o.out, slug + (ext === '.jpeg' ? '.jpg' : ext));
  copyFileSync(file, staged);

  const arm = arms[slug] || arms[orig] || null;
  const flags = [];
  if (needsName && !names[orig]) flags.push('needs-subject');
  if (!arm) flags.push('needs-arm');
  if (flags.length) needsHuman++;

  images.push({ id: null, name: slug, file: staged.replace(/\\/g, '/'), src: file.replace(/\\/g, '/'),
    w: d.w, h: d.h, ar: +(d.w / d.h).toFixed(3), arm, flags });
});

const out = { centre: o.centre, images };
if (o.json) process.stdout.write(JSON.stringify(out, null, 2) + '\n');
else {
  for (const im of images) process.stdout.write(`${im.name.padEnd(40)} ${String(im.w).padStart(5)}x${String(im.h).padEnd(5)} ar=${im.ar}  arm=${im.arm || '-'}${im.flags.length ? '  [' + im.flags.join(',') + ']' : ''}\n`);
}
if (needsHuman) { process.stderr.write(`stage-assets: ${needsHuman} image(s) need a human subject and/or arm — see flags\n`); process.exit(10); }

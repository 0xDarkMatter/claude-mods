#!/usr/bin/env node
// verify-freshness.mjs — tripwire for the external facts this skill encodes.
//
// figma-ops routes to eleven official plugin skills by name and cites a community
// index by URL. Both move: the plugin ships new skills, renames them, and the
// community list grows. When they do, the router table in SKILL.md quietly rots.
// This script makes that rot trip a test instead (SKILL-RESOURCE-PROTOCOL §7).
//
//   --offline  checks the LOCAL plugin cache: every skill the router names exists
//              there, and reports skills the cache has that the router does not
//              mention. No network. Skips cleanly (exit 0, message) if no cache.
//   --live     additionally fetches the official community index and reports
//              skills it lists that references/skill-map.md does not mention.
//
// Contract: stdout report; stderr diagnostics.
//   0 fresh · 2 usage · 10 stale (router or map out of date) · 0 with "skipped"
//   when the environment lacks the plugin cache (--offline) or network (--live).

import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HELP = `verify-freshness.mjs — is figma-ops' router still true?

Usage:
  node verify-freshness.mjs --offline [--cache DIR] [--json]
  node verify-freshness.mjs --live    [--cache DIR] [--json]

Options:
  --offline        check the router against the local Figma plugin cache
  --live           also compare references/skill-map.md against the community index
  --cache DIR      plugin skills dir (default: newest under ~/.claude/plugins/cache/claude-plugins-official/figma/*/skills)
  --json           JSON report
  -h, --help

Exit: 0 fresh (or --offline skipped: no cache) · 2 usage · 7 --live source unreachable · 10 stale/drift

EXAMPLES:
  node verify-freshness.mjs --offline
  node verify-freshness.mjs --live --json
`;

const args = process.argv.slice(2);
if (args.includes('-h') || args.includes('--help')) { process.stdout.write(HELP); process.exit(0); }
const live = args.includes('--live'), offline = args.includes('--offline') || live;
if (!offline) { process.stderr.write('verify-freshness: pass --offline or --live\n\n' + HELP); process.exit(2); }
const json = args.includes('--json');
const ci = args.indexOf('--cache'); let cache = ci >= 0 ? args[ci + 1] : null;

const skillDir = new URL('..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const skillMd = readFileSync(join(skillDir, 'SKILL.md'), 'utf8');
const mapMd = readFileSync(join(skillDir, 'references', 'skill-map.md'), 'utf8');

// Every `figma-…` skill name the router table or prose mentions.
const routed = new Set([...skillMd.matchAll(/`(figma-[a-z0-9-]+)`/g)].map(m => m[1]));
const report = { routed: [...routed].sort(), missingFromCache: [], unroutedInCache: [], unmappedCommunity: [], skipped: [] };

// --- offline: local plugin cache --------------------------------------------
if (!cache) {
  const root = join(homedir(), '.claude', 'plugins', 'cache', 'claude-plugins-official', 'figma');
  if (existsSync(root)) {
    const vers = readdirSync(root).filter(v => existsSync(join(root, v, 'skills'))).sort((a, b) => statSync(join(root, b)).mtimeMs - statSync(join(root, a)).mtimeMs);
    if (vers.length) cache = join(root, vers[0], 'skills');
  }
}
if (cache && existsSync(cache)) {
  const inCache = new Set(readdirSync(cache).filter(d => existsSync(join(cache, d, 'SKILL.md'))));
  report.cache = cache;
  report.missingFromCache = [...routed].filter(s => !inCache.has(s)).sort();
  report.unroutedInCache = [...inCache].filter(s => !routed.has(s)).sort();
} else {
  report.skipped.push('no Figma plugin cache found — offline check skipped');
}

// --- live: community index ---------------------------------------------------
if (live) {
  try {
    const res = await fetch('https://raw.githubusercontent.com/figma/community-resources/main/agent_skills/README.md', { signal: AbortSignal.timeout(15000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const md = await res.text();
    // The index lists one skill per `#### <kebab-name>` heading (verified 2026-09-05;
    // one entry is mis-levelled as ###, so accept both — category headings are
    // Title Case and never kebab, so they don't match).
    const names = new Set([...md.matchAll(/^#{3,4}\s+([a-z0-9]+(?:-[a-z0-9]+)+)\s*$/gm)].map(m => m[1]));
    if (!names.size) throw new Error('no "#### <skill>" headings found — index format changed?');
    report.communityCount = names.size;
    // skill-map.md keeps an explicit inventory list; a name absent from it is drift.
    report.unmappedCommunity = [...names].filter(n => !new RegExp(`\\b${n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`).test(mapMd)).sort();
  } catch (e) {
    // House convention (freshness.yml): 7 = live source unavailable, warn, don't fail.
    process.stderr.write(`verify-freshness: community index unreachable (${e.message})\n`);
    if (json) process.stdout.write(JSON.stringify({ ...report, unavailable: true }, null, 2) + '\n');
    process.exit(7);
  }
}

const stale = report.missingFromCache.length > 0;   // hard: router names a skill that doesn't exist
const drift = report.unroutedInCache.length > 0 || report.unmappedCommunity.length > 0;

if (json) process.stdout.write(JSON.stringify({ ...report, stale, drift }, null, 2) + '\n');
else {
  process.stdout.write(`routed skills: ${report.routed.length}${report.cache ? `  (cache: ${report.cache})` : ''}\n`);
  if (report.missingFromCache.length) process.stdout.write(`STALE  router names skills not in the cache: ${report.missingFromCache.join(', ')}\n`);
  if (report.unroutedInCache.length) process.stdout.write(`DRIFT  cache has skills the router never mentions: ${report.unroutedInCache.join(', ')}\n`);
  if (report.unmappedCommunity.length) process.stdout.write(`DRIFT  community index lists skills skill-map.md doesn't: ${report.unmappedCommunity.slice(0, 20).join(', ')}${report.unmappedCommunity.length > 20 ? ' …' : ''}\n`);
  for (const s of report.skipped) process.stdout.write(`SKIP   ${s}\n`);
  if (!stale && !drift && !report.skipped.length) process.stdout.write('fresh\n');
}
process.exit(stale || drift ? 10 : 0);

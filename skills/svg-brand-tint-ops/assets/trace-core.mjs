// SVG Studio — raster→vector trace engine (pure, dependency-free ES module).
//
// The canonical image-trace core. Runs identically in the browser (fed a
// <canvas> ImageData) and in Node (fed decoded pixels), so the tool and the
// headless accuracy harness share ONE implementation — no drift.
//
//   import { traceImage } from './trace-core.mjs';
//   const svg = traceImage({ data, width, height }, { mode:'color', colors:8 });
//
// `data` is RGBA bytes (Uint8ClampedArray|Uint8Array|number[]), length w*h*4.
// Returns an SVG string. No DOM, no canvas, no network.

export const DEFAULTS = {
  mode: 'color',      // 'color' | 'bw' | 'poster'
  colors: 6,          // color mode: palette size
  threshold: 128,     // bw mode: luminance cut
  levels: 4,          // poster mode: grey bands
  detail: 1.0,        // Douglas–Peucker epsilon (px) — pre-simplify before Bézier fitting
  smooth: 0.5,        // widens the Bézier fit tolerance (0..1)
  cornerDeg: 40,      // turns sharper than this stay sharp (corner-split)
  fair: 1,            // Laplacian fairing passes on CURVE vertices (de-wiggles thin strokes; corners pinned)
  fitErr: 1.5,        // Schneider Bézier fit error tolerance (working px) — higher = smoother, fewer curves
  mergeDist: 48,      // merge palette colours closer than this (collapses mono over-segmentation + anti-alias fringe)
  smoothPx: 1,        // mask-smoothing blur radius (px); 0 = crisp (blur rounds corners)
  despeckle: 10,      // drop features under N px²
  preblur: 0,         // box-blur radius (denoise)
  invert: false,      // bw/poster: invert luminance
  alphaCut: 128,      // pixels below this alpha are treated as transparent (excluded)
  bg: '',             // optional forced background fill for fully-opaque images
  // ── field/palette machinery (v2 repair rounds — ON by default; set false to disable) ──
  softField: true,    // CHANGE 1: fractional membership field dq/(dp+dq) instead of hard binary mask
  alphaField: true,   // CHANGE 1b: multiply membership by alpha/255 (soft outer boundary on transparent-bg art)
  fringeCull: true,   // CHANGE 2: cull AA-fringe palette entries (on the a—b line, tiny area)
  fringeDist: 45,     // CHANGE 2: max RGB distance from the a—b segment to count as fringe
  fringeAreaRatio: 0.25, // CHANGE 2: fringe area must be < this fraction of min(area(a),area(b))
  matteAnchor: true,  // CHANGE 2b: also cull fringes toward the estimated background matte (transparent-bg halos)
  matteDilate: 3,     // CHANGE 2b: transparency-dilate passes for the halo border band (callers scale with supersample)
  straightRun: false, // CHANGE 3 (legacy v2 geometry): greedy straight-run collapse after DP simplify.
                      // Superseded by `potrace`; only consulted when potrace is disabled.
  runTol: 0.75,       // CHANGE 3: max deviation (working px) of intermediates from the run segment
  demat: true,        // CHANGE 0: un-blend the background matte from semi-transparent AA pixels (root-cause halo fix)
  // ── v3: Potrace-style global geometry stage (Selinger 2003, implemented from the paper) ──
  potrace: true,      // v3 path: optimal polygon + vertex adjust + corner analysis (replaces DP+straightRun+Schneider)
  tubeTol: 1.0,       // P2 straightness tube radius (working px; ≈ Potrace's 0.5 native px at 2x supersample)
  chamferMax: 4.5,    // collapse runs of polygon edges shorter than this across AA-rounded corners (working px)
  alphaMax: 1.0,      // P6 corner threshold (alpha > alphaMax => corner)
  cornerBox: 1.0,     // P6 tolerance-square side around a_i (working px)
  adjustR: 0.75,      // P5 max displacement of adjusted vertex from its ring vertex (working px)
  axisSnap: true,     // P8 snap near-axis edges to exact 0/90 (and 45) degrees
  snapDeg: 0.75,      // P8 tolerance for horizontal/vertical snap (degrees)
  snap45Deg: 0.4,     // P8 tolerance for 45-degree snap (degrees)
  minSeg: 0.2,        // P1 pre-merge: drop ring vertices closer than this to their predecessor (working px)
  optiCurve: true,    // P7 curve optimization: join same-convexity Bézier runs (paper §2.4)
  optTol: 0.2,        // P7 tangency acceptance tolerance (working px)
  // ── v4 field/palette fidelity fixes (ON by default; set false/0 to disable) ──
  matteField: true,   // FIX 1: estimated background matte joins the field competition (dq), so the
                      // outer boundary lands on the 50% ink↔matte blend instead of the AA envelope
  polarize: true,     // FIX 2a: snap each palette colour to the mean of its FLAT-INTERIOR pixels
                      // (kmeans means are dragged toward AA blends; interiors are the true inks)
  interiorGuard: true, // FIX 2b: flat-interior-aware merge + fringe cull — an entry with a real flat
                      // interior is never culled/merged away; an entry with none, sitting on a blend
                      // segment (incl. toward the matte), is always culled
  minFlat: 16,        // FIX 2: minimum flat-interior pixels (working px²; at the 2x-supersample
                      // reference scale — callers scale by (superF/2)²)
  fieldSharp: 1.0,    // FIX 3: unsharp gain λ on each layer field (recovers sub-50%-coverage hairlines;
                      // preserves straight-edge 0.5 crossings exactly). 0 = off
  sharpR: 2,          // FIX 3: unsharp radius (working px)
  minLoop: 0,         // per-contour despeckle (working px²); 0 = legacy 0.5
  blendVeto: true,    // FIX 4: zero membership on pixels explained by another ink-pair blend
  isoArea: true,      // FIX 5: per-layer area-conserving iso — pick the contour level whose region
                      // area equals the field integral (∑f). Symmetric ramps ⇒ exactly 0.5 (no-op);
                      // sub-50%-coverage hairline fields (fine barcodes, serif hairlines) ⇒ the iso
                      // drops just enough to preserve the stroke's optical weight. Clamped [0.32,0.6]
  sliverVeto: true,   // FIX 6: phantom-sliver veto — drop/reassign small emitted contours whose
                      // SOURCE pixels are explained by a blend of the two colours they border
                      // (AA debris: fringe caps, edge ticks, third-colour slivers) rather than by
                      // their own fill. Needs two distinct bordering colours, so isolated legit
                      // marks (dots, ®, faint hairlines on plain background) are never touched.
  sliverMax: 500,     // FIX 6: max contour area (working px²) eligible for the veto
};

/* ── main ────────────────────────────────────────────────────────────── */
export function traceImage(image, opts = {}) {
  const o = { ...DEFAULTS, ...opts };
  // coerce numeric knobs to finite defaults so a bad value degrades gracefully
  // (NaN threshold/levels/detail/colors would otherwise silently blank the SVG)
  { const num = (v, d) => Number.isFinite(+v) ? +v : d;
    for (const k of ['colors','threshold','levels','detail','smooth','cornerDeg','fair','fitErr','mergeDist','smoothPx','despeckle','preblur','alphaCut','fringeDist','fringeAreaRatio','runTol']) o[k] = num(o[k], DEFAULTS[k]); }
  const w = image.width, h = image.height;
  let px = image.data;
  if (o.preblur > 0) px = boxBlur(px, w, h, Math.round(o.preblur));
  const matte = o.matteField ? estimateMatte(px, w * h) : null;  // FIX 1 (from ORIGINAL px, pre-demat)
  if (o.demat) px = dematte(px, w * h);                 // CHANGE 0: strip matte contamination from AA pixels

  const N = w * h;
  const lum = new Float32Array(N);
  const opaque = new Uint8Array(N);
  for (let i = 0, j = 0; i < N; i++, j += 4) {
    lum[i] = 0.299 * px[j] + 0.587 * px[j + 1] + 0.114 * px[j + 2];
    opaque[i] = px[j + 3] >= o.alphaCut ? 1 : 0;
  }

  const layers = buildLayers(px, lum, opaque, w, h, o, matte);

  // contour + fit each layer → paths
  const eps = o.detail, minA = o.despeckle;
  const minLoop = o.minLoop > 0 ? o.minLoop : 0.5;

  // pass 1: per-layer iso level, despeckle survivors
  const preps = [];
  const consLevel = (field) => {                         // FIX 5: area-conserving contour level
    const HB = 512, hist = new Int32Array(HB + 1);
    let S = 0;
    for (let i = 0; i < field.length; i++) {
      const f = field[i];
      if (f <= 0) continue;
      S += f;
      hist[Math.min(HB, Math.floor(f * HB))]++;
    }
    let acc = 0, t = 0.5;
    for (let b = HB; b >= 0; b--) {                      // area(≥ b/HB) grows as b falls; stop at ∑f
      acc += hist[b];
      if (acc >= S) { t = b / HB; break; }
    }
    return t;
  };
  for (const L of layers) {
    let iso = 0.5, tRaw = 0.5;
    if (o.isoArea) {
      if (L.fieldUn) {
        // FIX 7: two regimes in one layer. The gated field is coverage-true
        // (iso 0.5 is exact); the ungated field wants its own conserving level
        // t*. Rescale the ungated field so t* maps to 0.5 and take the max —
        // equivalent to a per-region iso, in a single marching-squares cut.
        const t = Math.max(0.32, Math.min(0.6, consLevel(L.fieldUn)));
        const sc = 0.5 / t;
        const F = L.field, U = L.fieldUn;
        for (let i = 0; i < F.length; i++) {
          const v = U[i] * sc;
          const u = v > 1 ? 1 : v;
          if (u > F[i]) F[i] = u;
        }
        iso = 0.5; tRaw = t;                            // 0.5 minus a hair: blur+unsharp+fit shave ~0.02 of ramp
      } else {
        const t = consLevel(L.field);
        iso = Math.max(0.32, Math.min(0.6, t));
        tRaw = t;
      }
    }
    let pxArea = 0;
    for (let i = 0; i < L.field.length; i++) if (L.field[i] >= iso) pxArea++;
    if (o._isoHook) o._isoHook({ fill: L.fill, tRaw: +tRaw.toFixed(3), iso, pxArea });
    if (pxArea < minA) continue;                         // one cull, on true px²
    preps.push({ L, iso });
  }

  // FIX 6 prep: region masks + composite index + flattened source (colour mode only)
  const vetoOn = o.sliverVeto && preps.length > 0 && preps.every(pr => pr.L.rgb);
  let compTop = null, srcFlat = null, bgRGB = null;
  if (vetoOn) {
    bgRGB = matte ? [Math.round(matte[0]), Math.round(matte[1]), Math.round(matte[2])] : [255, 255, 255];
    compTop = new Int16Array(N).fill(-1);
    for (let k = 0; k < preps.length; k++) {
      const { L, iso } = preps[k], m = new Uint8Array(N);
      for (let i = 0; i < N; i++) if (L.field[i] >= iso) { m[i] = 1; compTop[i] = k; }
      preps[k].mask = m;
    }
    srcFlat = new Uint8ClampedArray(N * 3);
    for (let i = 0, j = 0; i < N; i++, j += 4) {
      const a = px[j + 3] / 255;
      srcFlat[i * 3]     = px[j]     * a + bgRGB[0] * (1 - a);
      srcFlat[i * 3 + 1] = px[j + 1] * a + bgRGB[1] * (1 - a);
      srcFlat[i * 3 + 2] = px[j + 2] * a + bgRGB[2] * (1 - a);
    }
  }

  // pass 2: contour, veto, fit, emit
  // FIX 10 (pixel-centre alignment): field[y*w+x] is the coverage of the pixel
  // CENTRED at (x+0.5, y+0.5), but marching squares emits vertices on the
  // (x, y) lattice — every contour lands half a working pixel up-left of the
  // true edge (measured: a uniform (-0.5,-0.5) 2x-px shift of every render vs
  // its source). Translate rings to pixel-centre space before fitting. Veto /
  // mask bookkeeping stays in lattice space, consistent with the field.
  const fitOne = poly => {
    poly = poly.map(p => [p[0] + 0.5, p[1] + 0.5]);
    if (o.potrace) {                                     // v3: Potrace global stage on the RAW ring (no DP)
      if (o._ringHook) o._ringHook(poly);
      return potracePath(poly, o, o.debugGeo);
    }
    let pts = simplify(poly, eps);
    if (o.straightRun && pts.length >= 4) pts = straightRunCollapse(pts, o.runTol);  // CHANGE 3
    if (pts.length < 3) return '';
    return fitPath(pts, o.smooth, o.cornerDeg, o.fair, o.fitErr);
  };
  let body = '';
  const polyPerim = poly => {
    let s = 0;
    for (let i = 0, n = poly.length; i < n; i++) {
      const a = poly[i], b = poly[(i + 1) % n];
      s += Math.hypot(b[0] - a[0], b[1] - a[1]);
    }
    return s;
  };
  const polySigned = poly => {
    let a = 0;
    for (let i = 0, n = poly.length; i < n; i++) {
      const [x1, y1] = poly[i], [x2, y2] = poly[(i + 1) % n];
      a += x1 * y2 - x2 * y1;
    }
    return a / 2;
  };
  for (let k = 0; k < preps.length; k++) {
    const { L, iso } = preps[k];
    const contours = isoContours(L.field, w, h, iso);
    const keep = [], smalls = [], extras = [];
    // FIX 11 (sub-px fringe band drop): an OUTER contour whose mean optical
    // width 2A/P is under a working pixel, with tiny area, is a resampling /
    // chroma-fringe band hugging another ink's edge (1px accent slivers along
    // text stems) — not art. Holes (counters, opposite winding) are exempt so
    // hairline cutouts survive. Reference winding = the layer's largest loop.
    let refSign = 0, refA = 0;
    for (const poly of contours) {
      const sa = polySigned(poly);
      if (Math.abs(sa) > refA) { refA = Math.abs(sa); refSign = Math.sign(sa); }
    }
    for (const poly of contours) {
      const A = polyArea(poly);
      if (A < minLoop) continue;                         // discard sliver contours
      if (A < 300 && Math.sign(polySigned(poly)) === refSign &&
          2 * A / polyPerim(poly) < 1.1) continue;       // FIX 11
      if (vetoOn) smalls.push(poly);
      else keep.push(poly);
    }
    if (smalls.length) sliverVetoPass(smalls, keep, extras, k, preps, compTop, srcFlat, bgRGB, w, h, o);
    let d = '';
    for (const poly of keep) { const pd = fitOne(poly); if (pd) d += pd + ' '; }
    if (d) body += `<path d="${d.trim()}" fill="${L.fill}" fill-rule="evenodd"/>`;
    for (const ex of extras) {
      let dd = '';
      for (const poly of ex.polys) { const pd = fitOne(poly); if (pd) dd += pd + ' '; }
      if (dd) body += `<path d="${dd.trim()}" fill="${ex.fill}" fill-rule="evenodd"/>`;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}">${body}</svg>`;
}

/* ── layering per mode ───────────────────────────────────────────────── */
// Each layer is a hard binary membership, then BLURRED into a smooth 0..1
// coverage field. isoContours cuts the blurred field at 0.5 → sub-pixel-smooth
// boundaries (the blur dissolves the pixel staircase) while staying robust for
// monochrome art (a hard assignment never collapses like a distance ratio does).
function buildLayers(px, lum, opaque, w, h, o, matte) {
  const N = w * h, layers = [];
  const r = Math.max(0, Math.round(o.smoothPx));
  const smooth = raw => {
    let f = r > 0 ? blurField(raw, w, h, r) : raw;
    if (o.fieldSharp > 0) f = unsharpField(f, w, h, Math.max(1, Math.round(o.sharpR)), o.fieldSharp); // FIX 3
    return f;
  };
  if (o.mode === 'bw') {
    const th = o.threshold, raw = new Float32Array(N);
    for (let i = 0; i < N; i++) if (opaque[i]) raw[i] = (o.invert ? lum[i] > th : lum[i] < th) ? 1 : 0;
    layers.push({ field: smooth(raw), fill: o.invert ? '#ffffff' : '#111111' });
  } else if (o.mode === 'poster') {
    const L = Math.max(2, Math.round(o.levels) || DEFAULTS.levels);   // ≥2, never NaN (avoids empty output / L-1 div-by-0)
    for (let k = 1; k < L; k++) {
      const th = 255 * k / L, raw = new Float32Array(N);
      for (let i = 0; i < N; i++) { if (!opaque[i]) continue; let v = lum[i]; if (o.invert) v = 255 - v; raw[i] = v < th ? 1 : 0; }
      const g = Math.round(255 * (k - 1) / (L - 1));
      layers.push({ field: smooth(raw), fill: rgb2hex(g, g, g) });
    }
    layers.reverse();
  } else { // color — nearest-palette assignment, then blur each membership mask
    let pal = medianCut(px, opaque, w, h, o.colors);
    pal = kmeansRefine(px, opaque, w, h, pal, 5);   // snap seeds onto the true flat colours
    if (o._palHook) o._palHook('kmeans', pal.map(c => c.slice()));
    if (o.interiorGuard) {                          // FIX 2: interior-aware merge
      const st = flatStats(px, opaque, w, h, pal);
      pal = mergePaletteSmart(pal, o.mergeDist, st, o.minFlat);
    } else {
      const preArea = new Array(pal.length).fill(0);  // so merge keeps the DOMINANT member of each cluster
      for (let i = 0, j = 0; i < N; i++, j += 4) { if (!opaque[i]) continue; let b = 0, bd = 1e12;
        for (let p = 0; p < pal.length; p++) { const dr = px[j]-pal[p][0], dg = px[j+1]-pal[p][1], dl = px[j+2]-pal[p][2]; const dd = dr*dr+dg*dg+dl*dl; if (dd < bd) { bd = dd; b = p; } } preArea[b]++; }
      pal = mergePalette(pal, o.mergeDist, preArea);    // collapse near-duplicate colours (mono logos)
    }
    if (o._palHook) o._palHook('merge', pal.map(c => c.slice()));
    if (o.polarize) {                               // FIX 2a: pre-cull polarize (cull geometry on true inks)
      const st = flatStats(px, opaque, w, h, pal);
      pal = pal.map((c, p) => st.flatCnt[p] >= o.minFlat ? st.flatMean[p].map(Math.round) : c);
    }
    if (o.fringeCull) pal = cullFringe(px, opaque, w, h, pal, o, matte);  // CHANGE 2 (+2b) + FIX 2b
    if (o.polarize) {                               // FIX 2a: post-cull polarize (reassigned AA px absorbed)
      const st = flatStats(px, opaque, w, h, pal);
      pal = pal.map((c, p) => st.flatCnt[p] >= o.minFlat ? st.flatMean[p].map(Math.round) : c);
    }
    if (o._palHook) o._palHook('cull', pal.map(c => c.slice()));
    const assign = new Int16Array(N), area = new Array(pal.length).fill(0);
    for (let i = 0, j = 0; i < N; i++, j += 4) {
      if (!opaque[i]) { assign[i] = -1; continue; }
      let best = 0, bd = 1e12;
      for (let p = 0; p < pal.length; p++) {
        const dr = px[j] - pal[p][0], dg = px[j + 1] - pal[p][1], dl = px[j + 2] - pal[p][2];
        const dd = dr * dr + dg * dg + dl * dl;
        if (dd < bd) { bd = dd; best = p; }
      }
      assign[i] = best; area[best]++;
    }
    // FIX 7 (collinear-competitor gating): on greyscale-ramp art the real
    // intermediate inks (barcode greys) are collinear with dark↔matte, so they
    // "explain" every AA pixel of the dark wordmark and erode its boundary far
    // inside the true 50%-coverage line. An intermediate ink may only compete
    // for pixels NEAR ITS OWN flat cores; elsewhere the ramp belongs to the
    // ink↔matte pair. Pure-hue palettes have no collinear intermediates, so
    // this is a no-op outside greyscale/monochrome art.
    let collinAny = false, collinNear = null;
    if (o.softField && matte && pal.length >= 3) {
      const dM = c => Math.hypot(c[0] - matte[0], c[1] - matte[1], c[2] - matte[2]);
      const isCollin = pal.map(() => false);
      for (let q = 0; q < pal.length; q++) {
        for (let pp = 0; pp < pal.length; pp++) {
          if (pp === q) continue;
          const dQP = Math.hypot(pal[q][0] - pal[pp][0], pal[q][1] - pal[pp][1], pal[q][2] - pal[pp][2]);
          const dQM = dM(pal[q]);
          if (dQP > 60 && dQM > 60 && dM(pal[pp]) > dQM + 60 &&
              ptSegDist3(pal[q], pal[pp], matte) <= 40) { isCollin[q] = true; collinAny = true; break; }
        }
      }
      if (collinAny) {
        const stC = flatStats(px, opaque, w, h, pal);
        const R = Math.max(4, Math.round(o.matteDilate * 2));
        collinNear = pal.map((c, q) => {
          let cur = new Uint8Array(N);
          let any = false;
          for (let i = 0; i < N; i++) if (stC.flatMask[i] && stC.assign[i] === q) { cur[i] = 1; any = true; }
          if (!any) return cur;
          for (let pass = 0; pass < R; pass++) {           // chebyshev dilation
            const nx = new Uint8Array(cur);
            for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
              const i = y * w + x;
              if (cur[i]) continue;
              let hit = 0;
              for (let dy = -1; dy <= 1 && !hit; dy++) for (let dx = -1; dx <= 1; dx++) {
                const xx = x + dx, yy = y + dy;
                if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
                if (cur[yy * w + xx]) { hit = 1; break; }
              }
              if (hit) nx[i] = 1;
            }
            cur = nx;
          }
          return cur;
        });
        collinNear.isCollin = isCollin;
      }
    }
    const order = pal.map((_, i) => i).sort((a, b) => area[b] - area[a]);
    for (const p of order) {
      if (area[p] === 0) continue;                              // truly empty (all-transparent entry)
      if (p !== order[0] && area[p] < o.despeckle) continue;    // never drop the dominant colour → never a blank SVG
      let raw;
      if (o.softField && (pal.length >= 2 || o.alphaField || matte)) {
        raw = softMembership(px, opaque, N, pal, p, o.alphaField, matte, o.blendVeto, collinNear);  // CHANGE 1 (+1b) + FIX 1/4/7
      } else {
        raw = new Float32Array(N);
        for (let i = 0; i < N; i++) if (assign[i] === p) raw[i] = 1;
      }
      const L = { field: smooth(raw), fill: rgb2hex(...pal[p]), rgb: pal[p].slice() };
      if (raw.rawUn) L.fieldUn = smooth(raw.rawUn);
      if (collinNear && collinNear.isCollin[p]) L.selfNear = collinNear[p];
      layers.push(L);
    }
  }
  return layers;
}

/* ── FIX 6: phantom-sliver veto ───────────────────────────────────────────
   The per-pixel membership machinery occasionally emits small contours whose
   fill is NOT what the source shows there: fringe caps at stroke tips (an
   invented overshoot colour), third-colour ticks on wordmark AA, edge slivers
   of a real ink misplaced onto the blend zone of two OTHER colours. All share
   one signature: the SOURCE pixels under the contour sit on the RGB blend
   segment between the two colours the contour borders, and far from the
   contour's own fill. Test exactly that, per pixel, and on a supermajority
   drop the contour — or, when one bordering ink explains the source better
   than the background does, reassign the contour to that ink so strokes keep
   their full length (a dropped cap must not shorten its stem).
   Global and principled: no per-image tuning; needs two distinct bordering
   colours, so isolated legit marks (dots, ®, hairlines on plain background)
   never qualify. */
function polyBounds(poly) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const p of poly) {
    if (p[0] < x0) x0 = p[0]; if (p[0] > x1) x1 = p[0];
    if (p[1] < y0) y0 = p[1]; if (p[1] > y1) y1 = p[1];
  }
  return [x0, y0, x1, y1];
}
function pointInPoly(x, y, poly) {
  let inside = false;
  for (let i = 0, n = poly.length; i < n; i++) {
    const a = poly[i], b = poly[(i + 1) % n];
    if ((a[1] <= y && b[1] > y) || (b[1] <= y && a[1] > y)) {
      const xc = a[0] + (y - a[1]) / (b[1] - a[1]) * (b[0] - a[0]);
      if (xc > x) inside = !inside;
    }
  }
  return inside;
}
function interiorPixels(poly, w, h) {
  const [x0, y0, x1, y1] = polyBounds(poly);
  const out = [];
  const yA = Math.max(0, Math.ceil(y0)), yB = Math.min(h - 1, Math.floor(y1));
  for (let y = yA; y <= yB; y++) {
    const xs = [];
    for (let i = 0, n = poly.length; i < n; i++) {
      const a = poly[i], b = poly[(i + 1) % n];
      if ((a[1] <= y && b[1] > y) || (b[1] <= y && a[1] > y))
        xs.push(a[0] + (y - a[1]) / (b[1] - a[1]) * (b[0] - a[0]));
    }
    xs.sort((p, q) => p - q);
    for (let m = 0; m + 1 < xs.length; m += 2) {
      const xa = Math.max(0, Math.ceil(xs[m])), xb = Math.min(w - 1, Math.floor(xs[m + 1]));
      for (let x = xa; x <= xb; x++) out.push(y * w + x);
    }
  }
  return out;
}
function sliverVetoPass(smalls, keep, extras, k, preps, compTop, srcFlat, bg, w, h, o) {
  const ownRGB = preps[k].L.rgb, mask = preps[k].mask;
  const d3 = (r, g, b, c) => Math.sqrt((r - c[0]) ** 2 + (g - c[1]) ** 2 + (b - c[2]) ** 2);
  // context colours along the boundary: adjacent regions (topmost composite
  // layer, or background) + what lies beneath the contour's own pixels
  const ctxOf = (poly) => {
    const cnt = new Map();  // layer index (or -1 = bg) → sample count
    let total = 0;
    const step = Math.max(1, Math.floor(poly.length / 96));
    for (let vi = 0; vi < poly.length; vi += step) {
      const vx = Math.round(poly[vi][0]), vy = Math.round(poly[vi][1]);
      for (const [dx, dy] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const x = vx + dx, y = vy + dy;
        if (x < 0 || y < 0 || x >= w || y >= h) continue;
        const i = y * w + x;
        let key;
        if (mask[i]) {                       // own region: the colour beneath
          key = -1;
          for (let j = 0; j < k; j++) if (preps[j].mask[i]) key = j;
        } else key = compTop[i];             // adjacent region (any layer, or bg)
        if (key === k) continue;
        cnt.set(key, (cnt.get(key) || 0) + 1); total++;
      }
    }
    const out = [];
    for (const [key, c] of cnt) {
      if (c < Math.max(2, 0.15 * total)) continue;
      out.push({ rgb: key < 0 ? bg : preps[key].L.rgb, isBg: key < 0 });
    }
    return out;
  };
  const dropped = [], holes = [];
  for (const poly of smalls) {
    let P = interiorPixels(poly, w, h);
    const A = polyArea(poly);
    if (A > o.sliverMax) {
      // Large ring. polyArea counts the enclosed DISK, so a thin debris band
      // ringing another layer's region (AA rim around a bar/stem) escapes the
      // area cap — and its mostly-not-own interior reads as a "hole". Judge it
      // by its OWN pixel count: small own-band + mostly-foreign interior =
      // band-debris candidate, voted on the band pixels only. Genuinely big
      // own regions stay kept; big foreign-interior rings with no band are
      // true holes (counters) and follow their host.
      let inCnt = 0;
      for (const i of P) if (mask[i]) inCnt++;
      if (P.length >= 2 && inCnt * 2 < P.length && inCnt > 0 && inCnt <= o.sliverMax) {
        P = P.filter(i => mask[i]);          // vote on the band's own pixels
      } else if (P.length >= 2 && inCnt * 2 < P.length) {
        holes.push(poly); continue;          // true hole ring (counter)
      } else { keep.push(poly); continue; }  // big legit region
    } else {
      // hole rings (counters) are never veto candidates — leave them in place
      if (P.length >= 2) {
        let inCnt = 0;
        for (const i of P) if (mask[i]) inCnt++;
        if (inCnt * 2 < P.length) { holes.push(poly); continue; }
      }
    }
    if (!P.length) {                         // sub-pixel sliver: sample the ring itself
      const seen = new Set();
      for (const v of poly) {
        const x = Math.min(w - 1, Math.max(0, Math.round(v[0])));
        const y = Math.min(h - 1, Math.max(0, Math.round(v[1])));
        seen.add(y * w + x);
      }
      P = [...seen];
    }
    const ctx = ctxOf(poly);
    const pairs = [];
    for (let a = 0; a < ctx.length; a++) for (let b = a + 1; b < ctx.length; b++) {
      const A = ctx[a].rgb, B = ctx[b].rgb;
      if ((A[0] - B[0]) ** 2 + (A[1] - B[1]) ** 2 + (A[2] - B[2]) ** 2 >= 50 * 50) pairs.push([A, B]);
    }
    if (!pairs.length) { keep.push(poly); continue; }    // no two distinct borders → not a blend zone
    let votes = 0;
    const selfNear = preps[k].L.selfNear;
    const sums = ctx.map(() => 0);
    for (const i of P) {
      const r = srcFlat[i * 3], g = srcFlat[i * 3 + 1], b = srcFlat[i * 3 + 2];
      const dOwn = d3(r, g, b, ownRGB);
      let dCtx = Infinity, qCtx = null;
      for (const [A, B] of pairs) {
        const pr = projSeg3([r, g, b], A, B);
        if (pr.d < dCtx) { dCtx = pr.d; qCtx = pr.q; }
      }
      // Collinear-palette escape: a thin fragment of a real intermediate ink
      // "is a blend of its borders" by construction (greys are collinear), so
      // near its own flat cores a blend point that coincides with the own fill
      // does not count as debris evidence. Away from the cores it does.
      const protectedPx = selfNear && selfNear[i] && d3(qCtx[0], qCtx[1], qCtx[2], ownRGB) <= 32;
      if (dCtx + 12 < dOwn && !protectedPx) votes++;
      for (let ci = 0; ci < ctx.length; ci++) sums[ci] += d3(r, g, b, ctx[ci].rgb);
    }
    if (votes < 0.7 * P.length) { keep.push(poly); continue; }
    // debris — reassign to the context colour that best explains the source
    let bi = 0;
    for (let ci = 1; ci < ctx.length; ci++) if (sums[ci] < sums[bi]) bi = ci;
    const rec = { poly, reFill: null };
    if (!ctx[bi].isBg) {
      const fill = rgb2hex(...ctx[bi].rgb);
      let ex = extras.find(e => e.fill === fill);
      if (!ex) { ex = { fill, polys: [] }; extras.push(ex); }
      ex.polys.push(poly);
      rec.reFill = ex;
    }
    dropped.push(rec);
  }
  // hole rings inside a vetoed contour follow their host (or vanish with it)
  for (const hp of holes) {
    const host = dropped.find(dr => pointInPoly(hp[0][0], hp[0][1], dr.poly));
    if (!host) keep.push(hp);
    else if (host.reFill) host.reFill.polys.push(hp);
  }
}

/* ── FIX 1: matte estimate (pre-demat pixels) ─────────────────────────────
   Mean colour of low-alpha pixels (the matte the AA was blended toward);
   white fallback for binary-alpha cutouts. null when the image is opaque. */
function estimateMatte(src, N) {
  let mr = 0, mg = 0, mb = 0, mn = 0, hasTrans = false;
  for (let i = 0, j = 0; i < N; i++, j += 4) {
    const a = src[j + 3];
    if (a < 255) hasTrans = true;
    if (a > 0 && a <= 96) { mr += src[j]; mg += src[j + 1]; mb += src[j + 2]; mn++; }
  }
  if (!hasTrans) return null;
  return mn ? [mr / mn, mg / mn, mb / mn] : [255, 255, 255];
}

/* ── FIX 3: unsharp on a layer field ──────────────────────────────────────
   f' = clamp(f + λ(f − blur(f))). Antisymmetric residue at a straight step
   edge → the 0.5 crossing is preserved; positive at a ridge (hairline whose
   AA'd peak fell below 0.5) → the ridge crosses 0.5 again; negative in a thin
   gap → counters/slots stay open. Counteracts exactly the AA low-pass. */
function unsharpField(src, w, h, r, lam) {
  const b = blurField(src, w, h, r), out = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) {
    const v = src[i] + lam * (src[i] - b[i]);
    out[i] = v < 0 ? 0 : v > 1 ? 1 : v;
  }
  return out;
}

/* ── FIX 2: flat-interior statistics per palette entry ────────────────────
   A pixel is FLAT when its 4-neighbours are opaque, share its nearest palette
   entry, and sit within 15 RGB-sum units — i.e. it belongs to a solid interior,
   not an AA ramp. Real inks have flat interiors; AA fringe clusters have none.
   A flat pixel only counts toward entry p when its colour is NEAR pal[p]
   (≤45): a flat mixture region far from every palette colour (dense-hatch
   optical blends, barcode gap greys) is not evidence of a real ink. */
export function flatStats(px, opaque, w, h, pal) {
  const N = w * h, K = pal.length;
  const assign = new Int16Array(N).fill(-1);
  const area = new Array(K).fill(0);
  for (let i = 0, j = 0; i < N; i++, j += 4) {
    if (!opaque[i]) continue;
    let best = 0, bd = 1e12;
    for (let p = 0; p < K; p++) {
      const dr = px[j] - pal[p][0], dg = px[j + 1] - pal[p][1], db = px[j + 2] - pal[p][2];
      const dd = dr * dr + dg * dg + db * db;
      if (dd < bd) { bd = dd; best = p; }
    }
    assign[i] = best; area[best]++;
  }
  const flatCnt = new Array(K).fill(0);
  const flatMask = new Uint8Array(N);
  const fs = Array.from({ length: K }, () => [0, 0, 0]);
  const NEAR2 = 60 * 60;   // wide enough that a kmeans entry dragged by AA still credits its true cores
  for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
    const i = y * w + x, a = assign[i];
    if (a < 0) continue;
    const j = i * 4;
    { const dr = px[j] - pal[a][0], dg = px[j + 1] - pal[a][1], db = px[j + 2] - pal[a][2];
      if (dr * dr + dg * dg + db * db > NEAR2) continue; }
    let ok = true;
    for (const d of [-1, 1, -w, w]) {
      const k = i + d;
      if (assign[k] !== a) { ok = false; break; }
      const kj = k * 4;
      if (Math.abs(px[kj] - px[j]) + Math.abs(px[kj + 1] - px[j + 1]) + Math.abs(px[kj + 2] - px[j + 2]) > 15) { ok = false; break; }
    }
    if (ok) { flatCnt[a]++; flatMask[i] = 1; fs[a][0] += px[j]; fs[a][1] += px[j + 1]; fs[a][2] += px[j + 2]; }
  }
  const flatMean = fs.map((s, p) => flatCnt[p] ? [s[0] / flatCnt[p], s[1] / flatCnt[p], s[2] / flatCnt[p]] : pal[p].slice());
  return { assign, area, flatCnt, flatMean, flatMask };
}

/* ── FIX 2: interior-aware palette merge ──────────────────────────────────
   Entries closer than TIGHT always merge; entries within `thr` merge only when
   at least one of the pair lacks a flat interior (an AA cluster). Two REAL inks
   48 units apart (apc's overlap blues, tear's charcoal/grey) both survive.
   The representative is the flat-richer (then larger-area) member. */
function mergePaletteSmart(pal, thr, st, minFlat) {
  if (!thr || thr <= 0) return pal;
  const TIGHT = Math.min(20, thr);
  const keep = pal.map(() => true), out = [];
  for (let i = 0; i < pal.length; i++) {
    if (!keep[i]) continue;
    let rep = i;
    for (let j = i + 1; j < pal.length; j++) {
      if (!keep[j]) continue;
      const dr = pal[i][0] - pal[j][0], dg = pal[i][1] - pal[j][1], db = pal[i][2] - pal[j][2];
      const d2 = dr * dr + dg * dg + db * db;
      const mergeable = d2 < TIGHT * TIGHT ||
        (d2 < thr * thr && (st.flatCnt[i] < minFlat || st.flatCnt[j] < minFlat));
      if (mergeable) {
        keep[j] = false;
        const better = (st.flatCnt[j] >= minFlat) !== (st.flatCnt[rep] >= minFlat)
          ? (st.flatCnt[j] >= minFlat) : st.area[j] > st.area[rep];
        if (better) rep = j;
      }
    }
    out.push(pal[rep]);
  }
  return out;
}

// separable box blur on a single-channel float field (clamped edges)
function blurField(src, w, h, r) {
  const tmp = new Float32Array(w * h), out = new Float32Array(w * h), inv = 1 / (2 * r + 1);
  const cx = x => x < 0 ? 0 : x >= w ? w - 1 : x, cy = y => y < 0 ? 0 : y >= h ? h - 1 : y;
  for (let y = 0; y < h; y++) {
    const row = y * w; let acc = 0;
    for (let x = -r; x <= r; x++) acc += src[row + cx(x)];
    for (let x = 0; x < w; x++) { tmp[row + x] = acc * inv; acc += src[row + cx(x + r + 1)] - src[row + cx(x - r)]; }
  }
  for (let x = 0; x < w; x++) {
    let acc = 0;
    for (let y = -r; y <= r; y++) acc += tmp[cy(y) * w + x];
    for (let y = 0; y < h; y++) { out[y * w + x] = acc * inv; acc += tmp[cy(y + r + 1) * w + x] - tmp[cy(y - r) * w + x]; }
  }
  return out;
}

/* ── colour helpers ──────────────────────────────────────────────────── */
export const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
export const rgb2hex = (r, g, b) =>
  '#' + [r, g, b].map(v => clamp(Math.round(v), 0, 255).toString(16).padStart(2, '0')).join('');

// median-cut quantization over OPAQUE pixels
function medianCut(px, opaque, w, h, K) {
  const N = w * h, step = Math.max(1, Math.floor(N / 20000)), pts = [];
  for (let i = 0; i < N; i += step) {
    if (!opaque[i]) continue;
    const j = i * 4; pts.push([px[j], px[j + 1], px[j + 2]]);
  }
  if (!pts.length) return [[0, 0, 0]];
  let boxes = [pts];
  while (boxes.length < K) {
    let bi = -1, br = -1;
    boxes.forEach((b, i) => { if (b.length < 2) return; const r = chanRange(b); if (r.range > br) { br = r.range; bi = i; } });
    if (bi < 0) break;
    const b = boxes[bi], r = chanRange(b);
    b.sort((a, c) => a[r.ch] - c[r.ch]);
    const m = b.length >> 1;
    boxes.splice(bi, 1, b.slice(0, m), b.slice(m));
  }
  return boxes.map(b => {
    const s = [0, 0, 0];
    b.forEach(c => { s[0] += c[0]; s[1] += c[1]; s[2] += c[2]; });
    const n = b.length || 1;
    return [Math.round(s[0] / n), Math.round(s[1] / n), Math.round(s[2] / n)];
  });
}
// k-means (Lloyd) refinement — pulls median-cut seeds onto the dense colour
// clusters (a flat logo's true colours), dissolving muddy anti-alias intermediates.
function kmeansRefine(px, opaque, w, h, pal, iters) {
  const N = w * h, step = Math.max(1, Math.floor(N / 30000));
  const K = pal.length, cur = pal.map(c => c.slice());
  for (let it = 0; it < iters; it++) {
    const sum = Array.from({ length: K }, () => [0, 0, 0, 0]);
    for (let i = 0; i < N; i += step) {
      if (!opaque[i]) continue;
      const j = i * 4, r = px[j], g = px[j + 1], b = px[j + 2];
      let best = 0, bd = 1e12;
      for (let p = 0; p < K; p++) {
        const dr = r - cur[p][0], dg = g - cur[p][1], db = b - cur[p][2];
        const dd = dr * dr + dg * dg + db * db;
        if (dd < bd) { bd = dd; best = p; }
      }
      const s = sum[best]; s[0] += r; s[1] += g; s[2] += b; s[3]++;
    }
    let moved = 0;
    for (let p = 0; p < K; p++) {
      if (sum[p][3] === 0) continue;                 // keep an emptied seed as-is
      const nr = sum[p][0] / sum[p][3], ng = sum[p][1] / sum[p][3], nb = sum[p][2] / sum[p][3];
      moved += Math.abs(nr - cur[p][0]) + Math.abs(ng - cur[p][1]) + Math.abs(nb - cur[p][2]);
      cur[p] = [nr, ng, nb];
    }
    if (moved < 1) break;
  }
  return cur.map(c => [Math.round(c[0]), Math.round(c[1]), Math.round(c[2])]);
}
// merge palette entries closer than `thr` (Euclidean RGB) — keeps the first of
// each cluster, so a near-monochrome logo collapses to its few true colours.
function mergePalette(pal, thr, areas) {
  if (!thr || thr <= 0) return pal;
  const keep = pal.map(() => true), out = [];
  for (let i = 0; i < pal.length; i++) {
    if (!keep[i]) continue;
    let rep = i, repA = areas ? areas[i] : 0;                 // keep the DOMINANT member of the cluster
    for (let j = i + 1; j < pal.length; j++) {
      if (!keep[j]) continue;
      const dr = pal[i][0] - pal[j][0], dg = pal[i][1] - pal[j][1], db = pal[i][2] - pal[j][2];
      if (dr * dr + dg * dg + db * db < thr * thr) { keep[j] = false; if (areas && areas[j] > repA) { repA = areas[j]; rep = j; } }
    }
    out.push(pal[rep]);
  }
  return out;
}
/* ── v2 CHANGE 1: soft membership field ──────────────────────────────────
   For layer colour P and each opaque pixel c: dp=||c-P||, dq=min over OTHER
   palette colours of ||c-q||; field = dq/(dp+dq). Pure P → 1, decision
   boundary → 0.5, other → <0.5. AA ramp pixels take intermediate values so
   interpolated marching squares gets genuine sub-pixel crossings at iso 0.5. */
function softMembership(px, opaque, N, pal, p, useAlpha, matte, blendVeto, collinNear) {
  const raw = new Float32Array(N);
  const P = pal[p], K = pal.length;
  // FIX 1: the matte competes for every layer whose own ink is far from it, so the
  // ink↔background boundary lands on the 50% blend instead of the AA envelope.
  let mC = null;
  if (matte) {
    const dr = P[0] - matte[0], dg = P[1] - matte[1], db = P[2] - matte[2];
    if (dr * dr + dg * dg + db * db > 40 * 40) mC = matte;
  }
  // FIX 4 (blend veto): a pixel lying ON the blend segment of two OTHER inks
  // (or ink↔matte) is their AA, not P-ink — even when P happens to be the
  // nearest palette point (kills third-colour corner ticks on wordmark edges).
  // Guarded by e_own: pixels on P's own ink↔matte ramp are never vetoed.
  let pairs = null;
  if (blendVeto && (K + (mC ? 1 : 0)) >= 3) {
    const pts = pal.map((c, q) => ({ c, own: q === p }));
    if (mC) pts.push({ c: mC, own: false });
    pairs = [];
    for (let a = 0; a < pts.length; a++) for (let b = a + 1; b < pts.length; b++) {
      if (pts[a].own || pts[b].own) continue;
      const dr = pts[a].c[0] - pts[b].c[0], dg = pts[a].c[1] - pts[b].c[1], db = pts[a].c[2] - pts[b].c[2];
      if (dr * dr + dg * dg + db * db < 60 * 60) continue;      // degenerate pair
      pairs.push([pts[a].c, pts[b].c]);
    }
    if (!pairs.length) pairs = null;
  }
  // FIX 7: gate[q] — q is a collinear intermediate on P's own ink↔matte ramp
  // (strictly between, with margin); it may only compete near its own flat cores.
  let gate = null, matteTwin = false;
  if (collinNear && mC) {
    const dPM = Math.hypot(P[0] - mC[0], P[1] - mC[1], P[2] - mC[2]);
    for (let q = 0; q < K; q++) {
      if (q === p || !collinNear.isCollin[q]) continue;
      const dQP = Math.hypot(pal[q][0] - P[0], pal[q][1] - P[1], pal[q][2] - P[2]);
      const dQM = Math.hypot(pal[q][0] - mC[0], pal[q][1] - mC[1], pal[q][2] - mC[2]);
      if (dQP > 60 && dQM > 60 && dPM > dQM + 60 && ptSegDist3(pal[q], P, mC) <= 40) {
        if (!gate) gate = new Array(K).fill(false);
        gate[q] = true;
      }
    }
    // matte pollution guard: transparent-bg exports whose skirt px still carry
    // ink give a too-dark matte estimate, eroding the gated coverage boundary.
    // When an ungated palette entry is a near-twin of the matte (a genuine
    // background-coloured ink layer), let IT carry the background competition.
    if (gate) {
      for (let q = 0; q < K; q++) {
        if (q === p || gate[q]) continue;
        const dQM = Math.hypot(pal[q][0] - mC[0], pal[q][1] - mC[1], pal[q][2] - mC[2]);
        if (dQM < 60) { matteTwin = true; break; }
      }
    }
  }
  const rawUn = gate ? new Float32Array(N) : null;   // FIX 7: parallel ungated field
  if (gate) raw.rawUn = rawUn;
  for (let i = 0, j = 0; i < N; i++, j += 4) {
    const a8 = px[j + 3];
    if (useAlpha ? a8 === 0 : !opaque[i]) continue;
    let m, mUn;
    if (K < 2 && !mC) m = mUn = 1;
    else {
      const r = px[j], g = px[j + 1], b = px[j + 2];
      const dr = r - P[0], dg = g - P[1], db = b - P[2];
      const dp = Math.sqrt(dr * dr + dg * dg + db * db);
      let dq2 = Infinity, dq2Un = Infinity;
      for (let q = 0; q < K; q++) {
        if (q === p) continue;
        const qr = r - pal[q][0], qg = g - pal[q][1], qb = b - pal[q][2];
        const dd = qr * qr + qg * qg + qb * qb;
        if (dd < dq2Un) dq2Un = dd;
        if (gate && gate[q] && !collinNear[q][i]) continue;  // FIX 7
        if (dd < dq2) dq2 = dd;
      }
      if (mC) {
        const mr = r - mC[0], mg = g - mC[1], mb = b - mC[2];
        const dd = mr * mr + mg * mg + mb * mb;
        if (dd < dq2 && !matteTwin) dq2 = dd;
        if (dd < dq2Un) dq2Un = dd;
      }
      const dq = Math.sqrt(dq2);
      m = (dp + dq) > 0 ? dq / (dp + dq) : 0.5;
      const dqUn = Math.sqrt(dq2Un);
      mUn = (dp + dqUn) > 0 ? dqUn / (dp + dqUn) : 0.5;
      if (pairs && dp > 30 && (m >= 0.4 || mUn >= 0.4)) {
        const pix = [r, g, b];
        const eOwn = mC ? ptSegDist3(pix, P, mC) : Infinity;
        const lim = Math.min(0.5 * eOwn, 0.5 * dp, 20);
        for (const [A, B] of pairs) {
          if (ptSegDist3(pix, A, B) < lim) { if (m >= 0.4) m = 0; if (mUn >= 0.4) mUn = 0; break; }
        }
      }
    }
    raw[i] = useAlpha ? m * (a8 / 255) : m;   // CHANGE 1b: coverage-weighted membership
    if (rawUn) rawUn[i] = useAlpha ? mUn * (a8 / 255) : mUn;
  }
  return raw;
}

/* ── v2 CHANGE 0: de-matte ───────────────────────────────────────────────
   Transparent-background exports matte AA pixel RGB toward the page colour
   (usually white): rgb_file = mix(rgb_true, matte, 1-alpha). Un-blend it:
   rgb_true = matte + (rgb_file - matte) * 255/alpha. Kills fringe colours at
   the SOURCE — the palette never sees the pale halo blends. Matte estimated
   from low-alpha pixels; no-op for fully opaque images. */
function dematte(src, N) {
  let mr = 0, mg = 0, mb = 0, mn = 0, hasTrans = false;
  for (let i = 0, j = 0; i < N; i++, j += 4) {
    const a = src[j + 3];
    if (a < 255) hasTrans = true;
    if (a > 0 && a <= 96) { mr += src[j]; mg += src[j + 1]; mb += src[j + 2]; mn++; }
  }
  if (!hasTrans) return src;
  const M = mn ? [mr / mn, mg / mn, mb / mn] : [255, 255, 255];
  const out = new Uint8ClampedArray(src.length);
  out.set(src);
  for (let i = 0, j = 0; i < N; i++, j += 4) {
    const a = src[j + 3];
    if (a === 0 || a === 255) continue;
    const k = 255 / a;
    out[j]     = M[0] + (src[j]     - M[0]) * k;
    out[j + 1] = M[1] + (src[j + 1] - M[1]) * k;
    out[j + 2] = M[2] + (src[j + 2] - M[2]) * k;
  }
  return out;
}

/* ── v2 CHANGE 2: AA-fringe palette cull ─────────────────────────────────
   Iteratively remove any palette entry f that (a) lies within `maxDist` RGB
   units of the segment between two other surviving entries a,b (i.e. it is a
   blend of them — an anti-alias fringe colour), AND (b) claims < areaRatio of
   min(area(a),area(b)) pixels. Pixels reassign to the nearest survivor on the
   next assignment pass. Iterate until stable. */
function projSeg3(p, a, b) {
  const abx = b[0] - a[0], aby = b[1] - a[1], abz = b[2] - a[2];
  const apx = p[0] - a[0], apy = p[1] - a[1], apz = p[2] - a[2];
  const ab2 = abx * abx + aby * aby + abz * abz;
  let t = ab2 > 0 ? (apx * abx + apy * aby + apz * abz) / ab2 : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  const q = [a[0] + t * abx, a[1] + t * aby, a[2] + t * abz];
  const dx = p[0] - q[0], dy = p[1] - q[1], dz = p[2] - q[2];
  return { d: Math.sqrt(dx * dx + dy * dy + dz * dz), q };
}
function ptSegDist3(p, a, b) {
  const abx = b[0] - a[0], aby = b[1] - a[1], abz = b[2] - a[2];
  const apx = p[0] - a[0], apy = p[1] - a[1], apz = p[2] - a[2];
  const ab2 = abx * abx + aby * aby + abz * abz;
  let t = ab2 > 0 ? (apx * abx + apy * aby + apz * abz) / ab2 : 0;
  t = t < 0 ? 0 : t > 1 ? 1 : t;
  const dx = apx - t * abx, dy = apy - t * aby, dz = apz - t * abz;
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}
function cullFringe(px, opaque, w, h, pal, o, matteEst) {
  const N = w * h, maxDist = o.fringeDist, areaRatio = o.fringeAreaRatio;
  pal = pal.map(c => c.slice());
  // CHANGE 2b prep: estimated matte colour + "near transparency" mask (Chebyshev r=3)
  let matte = null, nearTrans = null;
  if (o.matteAnchor) {
    let mr = 0, mg = 0, mb = 0, mn = 0, anyTrans = false;
    for (let i = 0, j = 0; i < N; i++, j += 4) {
      const a = px[j + 3];
      if (a < 255) anyTrans = true;
      if (a > 0 && a <= 96) { mr += px[j]; mg += px[j + 1]; mb += px[j + 2]; mn++; }
    }
    if (anyTrans) {
      matte = mn ? [mr / mn, mg / mn, mb / mn] : [255, 255, 255];
      let cur = new Uint8Array(N);
      for (let i = 0; i < N; i++) cur[i] = opaque[i] ? 0 : 1;
      const dilate = Math.max(3, Math.round(o.matteDilate || 3));   // scale with supersample (v3: px-space correctness)
      for (let pass = 0; pass < dilate; pass++) {      // dilate transparency (8-neighbour)
        const nx = new Uint8Array(cur);
        for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
          if (cur[y * w + x]) continue;
          let hit = 0;
          for (let dy = -1; dy <= 1 && !hit; dy++) for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx, yy = y + dy;
            if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
            if (cur[yy * w + xx]) { hit = 1; break; }
          }
          if (hit) nx[y * w + x] = 1;
        }
        cur = nx;
      }
      nearTrans = cur;
    }
  }
  const matteRef = matte || matteEst;                 // FIX 2b can use the FIX 1 matte even w/o dilate mask
  while (pal.length >= 3 || (matteRef && pal.length >= 2)) {
    const K = pal.length, area = new Array(K).fill(0), border = new Array(K).fill(0);
    let st = null;
    if (o.interiorGuard) st = flatStats(px, opaque, w, h, pal);   // FIX 2b: flat interiors per entry
    const assign = st ? st.assign : null;
    for (let i = 0, j = 0; i < N; i++, j += 4) {
      if (!opaque[i]) continue;
      let best;
      if (assign) best = assign[i];
      else {
        best = 0; let bd = 1e12;
        for (let p = 0; p < K; p++) {
          const dr = px[j] - pal[p][0], dg = px[j + 1] - pal[p][1], db = px[j + 2] - pal[p][2];
          const dd = dr * dr + dg * dg + db * db;
          if (dd < bd) { bd = dd; best = p; }
        }
      }
      area[best] = (area[best] || 0) + 1;
      if (nearTrans && nearTrans[i]) border[best]++;
    }
    if (st) area.forEach((_, i) => { area[i] = st.area[i]; });
    // interstitial probe: fraction of f's FLAT pixels with an INKIER entry's pixel
    // within Chebyshev radius 2 — separates barcode-gap mixtures (sandwiched
    // between darker ink, high adjacency) from real light inks, whose flat cores
    // only ever touch their own LIGHTER AA ramp (which must not count).
    const dM = c => { if (!matteRef) return 0; const dr = c[0] - matteRef[0], dg = c[1] - matteRef[1], db = c[2] - matteRef[2]; return Math.sqrt(dr * dr + dg * dg + db * db); };
    const flatAdjFrac = (f) => {
      if (!st || !st.flatCnt[f]) return 0;
      // a true a↔matte mixture sits near the midpoint (dM(a) ≈ 2·dM(f)); 1.6 keeps
      // real neighbouring inks (tear charcoal/grey = 1.36) out of the test while
      // catching genuine interstitials (maddocks black/gap-grey = 1.65), and is
      // immune to lanczos-overshoot rims (slightly darker than f, ratio ≈ 1)
      const inkier = pal.map((c, q) => q !== f && dM(c) > 1.6 * dM(pal[f]));
      if (!inkier.some(Boolean)) return 0;
      let adj = 0;
      for (let y = 2; y < h - 2; y++) for (let x = 2; x < w - 2; x++) {
        const i = y * w + x;
        if (!st.flatMask[i] || assign[i] !== f) continue;
        let hit = false;
        for (let dy = -2; dy <= 2 && !hit; dy++) for (let dx = -2; dx <= 2; dx++) {
          const k = i + dy * w + dx;
          if (assign[k] >= 0 && inkier[assign[k]]) { hit = true; break; }
        }
        if (hit) adj++;
      }
      return adj / st.flatCnt[f];
    };
    let victim = -1, victimArea = Infinity;
    for (let f = 0; f < K; f++) {
      let isFringe = false;
      if (st) {
        const fa = st.flatCnt[f], frac = area[f] ? fa / area[f] : 0;
        if (fa >= o.minFlat && frac >= 0.25) continue;      // real ink: solid flat interior
        // is f on ANY blend segment (two surviving inks, or ink↔matte)?
        let onSeg = false;
        for (let a = 0; a < K && !onSeg; a++) {
          if (a === f) continue;
          for (let b = a + 1; b < K; b++) {
            if (b === f) continue;
            if (ptSegDist3(pal[f], pal[a], pal[b]) <= maxDist) { onSeg = true; break; }
          }
          if (!onSeg && matteRef && ptSegDist3(pal[f], pal[a], matteRef) <= maxDist) onSeg = true;
        }
        if (onSeg) {
          if (fa < o.minFlat) isFringe = true;              // pure AA cloud — always cull
          else isFringe = flatAdjFrac(f) >= 0.3;            // ambiguous — cull only if interstitial
        } else if (matteRef) {
          // FIX 8: lanczos-undershoot rim ("invented darker underlayer"). A weak
          // entry whose colour extrapolates a real ink BEYOND its endpoint on the
          // matte→ink axis (per-channel clamped — supersampling undershoot rings
          // darker-saturated rims around every ink edge) is a resampling artifact,
          // not an ink. Confirm spatially: its pixels must hug the parent ink.
          for (let a = 0; a < K && !isFringe; a++) {
            if (a === f || st.flatCnt[a] < o.minFlat) continue;
            const dFA = Math.hypot(pal[f][0] - pal[a][0], pal[f][1] - pal[a][1], pal[f][2] - pal[a][2]);
            if (dFA > 120) continue;
            let best = Infinity;
            for (let t = 1.05; t <= 1.6; t += 0.05) {
              const er = clamp(matteRef[0] + t * (pal[a][0] - matteRef[0]), 0, 255);
              const eg = clamp(matteRef[1] + t * (pal[a][1] - matteRef[1]), 0, 255);
              const eb = clamp(matteRef[2] + t * (pal[a][2] - matteRef[2]), 0, 255);
              const d = Math.hypot(pal[f][0] - er, pal[f][1] - eg, pal[f][2] - eb);
              if (d < best) best = d;
            }
            if (best > 40) continue;
            let adj = 0, tot = 0;                           // rim px hug the parent
            for (let y = 2; y < h - 2; y++) for (let x = 2; x < w - 2; x++) {
              const i = y * w + x;
              if (assign[i] !== f) continue;
              tot++;
              let hit = false;
              for (let dy = -2; dy <= 2 && !hit; dy++) for (let dx = -2; dx <= 2; dx++) {
                if (assign[i + dy * w + dx] === a) { hit = true; break; }
              }
              if (hit) adj++;
            }
            if (tot > 0 && adj / tot >= 0.6) isFringe = true;
          }
        }
        if (o._cullHook) o._cullHook({ f, pal: pal.map(c => c.slice()), fa, frac: +frac.toFixed(3), onSeg, isFringe, area: area[f] });
      } else {
        // legacy (v2 A/B) rules — unchanged
        for (let a = 0; a < K && !isFringe; a++) {
          if (a === f) continue;
          for (let b = a + 1; b < K; b++) {
            if (b === f) continue;
            if (ptSegDist3(pal[f], pal[a], pal[b]) <= maxDist &&
                area[f] < areaRatio * Math.min(area[a], area[b])) { isFringe = true; break; }
          }
        }
        if (!isFringe && matte) {
          const bf = area[f] ? border[f] / area[f] : 0;
          if (bf >= 0.6) {
            for (let a = 0; a < K; a++) {
              if (a === f) continue;
              if (ptSegDist3(pal[f], pal[a], matte) <= maxDist && area[f] < area[a]) { isFringe = true; break; }
            }
          }
        }
      }
      if (isFringe && area[f] < victimArea) { victim = f; victimArea = area[f]; }
    }
    if (victim < 0) break;
    pal.splice(victim, 1);
  }
  return pal;
}

/* ── v2 CHANGE 3: greedy maximal-straight-run collapse ───────────────────
   After DP simplify, replace the ring with a maximal-straight-run polygon:
   from anchor i find the furthest j (cyclic) such that EVERY intermediate
   vertex lies within `tol` working px of segment(P[i],P[j]); emit j; repeat.
   Greedy version of Potrace's optimal polygon. Walk starts at the sharpest
   turn so a true corner anchors the first run. */
export function straightRunCollapse(ring, tol) {
  const n = ring.length;
  if (n < 4) return ring;
  let start = 0, worst = 2;
  for (let i = 0; i < n; i++) {
    const p0 = ring[(i - 1 + n) % n], p1 = ring[i], p2 = ring[(i + 1) % n];
    const ax = p1[0] - p0[0], ay = p1[1] - p0[1], bx = p2[0] - p1[0], by = p2[1] - p1[1];
    const la = Math.hypot(ax, ay) || 1, lb = Math.hypot(bx, by) || 1;
    const cos = (ax * bx + ay * by) / (la * lb);
    if (cos < worst) { worst = cos; start = i; }
  }
  const at = k => ring[(start + k) % n];
  const tol2 = tol * tol;
  const dseg2 = (p, a, b) => {
    const abx = b[0] - a[0], aby = b[1] - a[1];
    const ab2 = abx * abx + aby * aby;
    let t = ab2 > 0 ? ((p[0] - a[0]) * abx + (p[1] - a[1]) * aby) / ab2 : 0;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    const dx = p[0] - a[0] - t * abx, dy = p[1] - a[1] - t * aby;
    return dx * dx + dy * dy;
  };
  const out = [];
  let i = 0;
  while (i < n) {
    out.push(at(i));
    let adv = 1;
    for (let a = 2; i + a <= n; a++) {          // candidate end at(i+a); i+a===n closes the ring
      let ok = true;
      const A = at(i), B = at(i + a);
      for (let k = 1; k < a; k++) if (dseg2(at(i + k), A, B) > tol2) { ok = false; break; }
      if (!ok) break;
      adv = a;
    }
    i += adv;
  }
  return out;
}

function chanRange(b) {
  const mn = [255, 255, 255], mx = [0, 0, 0];
  b.forEach(c => { for (let k = 0; k < 3; k++) { if (c[k] < mn[k]) mn[k] = c[k]; if (c[k] > mx[k]) mx[k] = c[k]; } });
  const r = [mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]];
  const ch = r.indexOf(Math.max(...r));
  return { ch, range: r[ch] };
}

/* ── denoise ─────────────────────────────────────────────────────────── */
function boxBlur(src, w, h, r) {
  if (r < 1) return src;
  const out = new Uint8ClampedArray(src.length), tmp = new Uint8ClampedArray(src.length);
  const pass = (inp, outp, horiz) => {
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      let R = 0, G = 0, B = 0, A = 0, n = 0;
      for (let k = -r; k <= r; k++) {
        const xx = horiz ? x + k : x, yy = horiz ? y : y + k;
        if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
        const idx = (yy * w + xx) * 4; R += inp[idx]; G += inp[idx + 1]; B += inp[idx + 2]; A += inp[idx + 3]; n++;
      }
      const oo = (y * w + x) * 4; outp[oo] = R / n; outp[oo + 1] = G / n; outp[oo + 2] = B / n; outp[oo + 3] = A / n;
    }
  };
  pass(src, tmp, true); pass(tmp, out, false);
  return out;
}

/* ── interpolated iso-contours (marching squares with sub-pixel crossings) ─
   Extracts the iso=level contour of a scalar FIELD, placing each edge crossing
   by linear interpolation between corner values → smooth, anti-alias-accurate
   boundaries. Filled-on-right winding so end→start linking traces closed loops. */
export function isoContours(field, w, h, iso) {
  const val = (x, y) => (x < 0 || y < 0 || x >= w || y >= h) ? -1e6 : field[y * w + x];
  const lerp = (p, q, a, b) => { let t = (iso - a) / ((b - a) || 1e-9); if (t < 0) t = 0; else if (t > 1) t = 1; return [p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t]; };
  const segs = [];
  for (let y = -1; y < h; y++) for (let x = -1; x < w; x++) {
    const a = val(x, y), b = val(x + 1, y), c = val(x + 1, y + 1), d = val(x, y + 1); // tl tr br bl
    const ci = (a > iso ? 8 : 0) | (b > iso ? 4 : 0) | (c > iso ? 2 : 0) | (d > iso ? 1 : 0);
    if (ci === 0 || ci === 15) continue;
    const TL = [x, y], TR = [x + 1, y], BR = [x + 1, y + 1], BL = [x, y + 1];
    const T = () => lerp(TL, TR, a, b), R = () => lerp(TR, BR, b, c), B = () => lerp(BL, BR, d, c), L = () => lerp(TL, BL, a, d);
    const add = (p, q) => { if (Math.abs(p[0] - q[0]) > 1e-9 || Math.abs(p[1] - q[1]) > 1e-9) segs.push([p[0], p[1], q[0], q[1]]); };  // skip degenerate corner segs
    switch (ci) {
      case 1: add(B(), L()); break; case 2: add(R(), B()); break; case 3: add(R(), L()); break;
      case 4: add(T(), R()); break; case 5: add(T(), R()); add(B(), L()); break; case 6: add(T(), B()); break;
      case 7: add(T(), L()); break; case 8: add(L(), T()); break; case 9: add(B(), T()); break;
      case 10: add(L(), T()); add(R(), B()); break; case 11: add(R(), T()); break;
      case 12: add(L(), R()); break; case 13: add(B(), R()); break; case 14: add(L(), B()); break;
    }
  }
  const key = (x, y) => Math.round(x * 64) + ',' + Math.round(y * 64), map = new Map();
  segs.forEach((s, i) => { const k = key(s[0], s[1]); if (!map.has(k)) map.set(k, []); map.get(k).push(i); });
  const used = new Uint8Array(segs.length), contours = [];
  for (let seed = 0; seed < segs.length; seed++) {
    if (used[seed]) continue;
    const poly = []; let cur = seed, guard = 0;
    while (cur !== -1 && !used[cur] && guard++ < segs.length + 5) {
      used[cur] = 1; const s = segs[cur]; poly.push([s[0], s[1]]);
      const cand = map.get(key(s[2], s[3])); let nxt = -1;
      if (cand) {
        if (poly.length >= 2 && cand.includes(seed)) { poly.push(poly[0].slice()); break; }   // close on segment IDENTITY, not fuzzy key
        for (const ci of cand) { if (!used[ci]) { nxt = ci; break; } }
      }
      if (nxt === -1) { poly.push([s[2], s[3]]); break; }
      cur = nxt;
    }
    if (poly.length >= 3) contours.push(poly);
  }
  return contours;
}
export function polyArea(p) {
  let a = 0;
  for (let i = 0, n = p.length; i < n; i++) { const [x1, y1] = p[i], [x2, y2] = p[(i + 1) % n]; a += x1 * y2 - x2 * y1; }
  return Math.abs(a / 2);
}

/* ── simplify (closed-ring Douglas–Peucker) ──────────────────────────── */
export function simplify(pts, eps) {
  if (eps <= 0) return pts;
  let ring = pts;
  if (ring.length > 1 && Math.abs(ring[0][0] - ring[ring.length - 1][0]) < 1e-6 && Math.abs(ring[0][1] - ring[ring.length - 1][1]) < 1e-6)
    ring = ring.slice(0, -1);
  const n = ring.length;
  if (n < 4) return ring;
  const at = i => ring[i % n];
  let far = 0, dm = -1;
  for (let i = 1; i < n; i++) { const dx = ring[i][0] - ring[0][0], dy = ring[i][1] - ring[0][1]; const d = dx * dx + dy * dy; if (d > dm) { dm = d; far = i; } }
  const keep = new Uint8Array(n); keep[0] = 1; keep[far] = 1;
  const dp = (a, b) => {
    const stack = [[a, b]];
    while (stack.length) {
      const [s, e] = stack.pop(); if (e <= s + 1) continue;
      const A = at(s), B = at(e); const dx = B[0] - A[0], dy = B[1] - A[1]; const len = Math.hypot(dx, dy) || 1;
      let dmax = 0, idx = -1;
      for (let i = s + 1; i < e; i++) { const P = at(i); const dd = Math.abs((P[0] - A[0]) * dy - (P[1] - A[1]) * dx) / len; if (dd > dmax) { dmax = dd; idx = i; } }
      if (dmax > eps && idx > -1) { keep[idx % n] = 1; stack.push([s, idx], [idx, e]); }
    }
  };
  dp(0, far); dp(far, n);
  const res = [];
  for (let i = 0; i < n; i++) if (keep[i]) res.push(ring[i]);
  return res;
}

/* ── path emit ───────────────────────────────────────────────────────── */
export function polyPath(pts) {
  let d = 'M' + f(pts[0][0]) + ' ' + f(pts[0][1]);
  for (let i = 1; i < pts.length; i++) d += 'L' + f(pts[i][0]) + ' ' + f(pts[i][1]);
  return d + 'Z';
}
export function smoothPath(pts, tension) {
  const n = pts.length; if (n < 3) return polyPath(pts);
  const t = clamp(tension, 0, 1) * 0.5;
  let d = 'M' + f(pts[0][0]) + ' ' + f(pts[0][1]);
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n];
    const c1x = p1[0] + (p2[0] - p0[0]) * t, c1y = p1[1] + (p2[1] - p0[1]) * t;
    const c2x = p2[0] - (p3[0] - p1[0]) * t, c2y = p2[1] - (p3[1] - p1[1]) * t;
    d += `C${f(c1x)} ${f(c1y)} ${f(c2x)} ${f(c2y)} ${f(p2[0])} ${f(p2[1])}`;
  }
  return d + 'Z';
}
const f = v => (Math.round(v * 10) / 10);

/* Corner-split + least-squares Bézier fit (Schneider, Graphics Gems).
   Classify vertices corner-vs-curve, (optionally) Laplacian-fair the curve
   vertices, split the ring at corners, and fit each smooth span with the FEWEST
   cubic Béziers that stay within `fitErr` px — averaging staircase noise into
   clean curves. Straight runs & letter corners stay razor-sharp; scripts and
   circles become genuinely smooth. `smooth` (0..1) widens the error tolerance. */
export function fitPath(pts, smooth = 0.5, cornerDeg = 42, fair = 0, fitErr = 1.6) {
  let n = pts.length;
  if (n < 3) return polyPath(pts);
  const cornerCos = Math.cos(cornerDeg * Math.PI / 180);
  const corner = new Array(n);
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n];
    const ax = p1[0] - p0[0], ay = p1[1] - p0[1], bx = p2[0] - p1[0], by = p2[1] - p1[1];
    const la = Math.hypot(ax, ay) || 1, lb = Math.hypot(bx, by) || 1;
    corner[i] = (ax * bx + ay * by) / (la * lb) < cornerCos;
  }
  if (fair > 0) {
    let cur = pts.map(p => p.slice());
    for (let it = 0; it < fair; it++) {
      const nx = cur.map(p => p.slice());
      for (let i = 0; i < n; i++) {
        if (corner[i]) continue;
        const a = cur[(i - 1 + n) % n], b = cur[(i + 1) % n];
        nx[i][0] = cur[i][0] + 0.5 * ((a[0] + b[0]) / 2 - cur[i][0]);
        nx[i][1] = cur[i][1] + 0.5 * ((a[1] + b[1]) / 2 - cur[i][1]);
      }
      cur = nx;
    }
    pts = cur;
  }
  // break points: every corner. Ensure ≥2 so a corner-free loop still splits.
  let breaks = [];
  for (let i = 0; i < n; i++) if (corner[i]) breaks.push(i);
  if (breaks.length === 0) {
    let far = 0, dm = -1;
    for (let i = 1; i < n; i++) { const dx = pts[i][0] - pts[0][0], dy = pts[i][1] - pts[0][1]; const d = dx * dx + dy * dy; if (d > dm) { dm = d; far = i; } }
    breaks = [0, far].sort((a, b) => a - b);
  } else if (breaks.length === 1) {
    const c0 = breaks[0]; let far = c0, dm = -1;
    for (let k = 1; k < n; k++) { const i = (c0 + k) % n; const dx = pts[i][0] - pts[c0][0], dy = pts[i][1] - pts[c0][1]; const d = dx * dx + dy * dy; if (d > dm) { dm = d; far = i; } }
    breaks = [c0, far].sort((a, b) => a - b);
  }
  const errSq = Math.pow(fitErr * (0.6 + smooth), 2);
  let d = 'M' + f(pts[breaks[0]][0]) + ' ' + f(pts[breaks[0]][1]);
  for (let b = 0; b < breaks.length; b++) {
    const a = breaks[b], e = breaks[(b + 1) % breaks.length];
    const span = []; let i = a; while (true) { span.push(pts[i]); if (i === e) break; i = (i + 1) % n; }
    if (span.length === 2) { d += 'L' + f(span[1][0]) + ' ' + f(span[1][1]); continue; }
    for (const bez of fitCurve(span, errSq)) d += `C${f(bez[1][0])} ${f(bez[1][1])} ${f(bez[2][0])} ${f(bez[2][1])} ${f(bez[3][0])} ${f(bez[3][1])}`;
  }
  return d + 'Z';
}

/* ── Schneider least-squares cubic fitting ───────────────────────────── */
const vsub = (a, b) => [a[0] - b[0], a[1] - b[1]], vadd = (a, b) => [a[0] + b[0], a[1] + b[1]];
const vscale = (a, s) => [a[0] * s, a[1] * s], vdot = (a, b) => a[0] * b[0] + a[1] * b[1];
const vlen = a => Math.hypot(a[0], a[1]), vnorm = a => { const l = vlen(a) || 1; return [a[0] / l, a[1] / l]; };
const bez = (c, t) => { let p = c.map(v => v.slice()); for (let r = 1; r < p.length; r++) for (let i = 0; i < p.length - r; i++) p[i] = [p[i][0] + (p[i + 1][0] - p[i][0]) * t, p[i][1] + (p[i + 1][1] - p[i][1]) * t]; return p[0]; };
function fitCurve(points, errSq) {
  const n = points.length;
  const tHat1 = vnorm(vsub(points[1], points[0])), tHat2 = vnorm(vsub(points[n - 2], points[n - 1]));
  return fitCubic(points, 0, n - 1, tHat1, tHat2, errSq, 0);
}
function fitCubic(points, first, last, tHat1, tHat2, errSq, depth) {
  const nPts = last - first + 1;
  if (nPts === 2) {
    const dist = vlen(vsub(points[last], points[first])) / 3;
    return [[points[first], vadd(points[first], vscale(tHat1, dist)), vadd(points[last], vscale(tHat2, dist)), points[last]]];
  }
  let u = chordParam(points, first, last);
  let curve = genBezier(points, first, last, u, tHat1, tHat2);
  let { err, split } = maxError(points, first, last, curve, u);
  if (err < errSq) return [curve];
  if (err < errSq * 16 && depth < 20) {
    for (let i = 0; i < 4; i++) {
      const up = u.map((ui, k) => newton(curve, points[first + k], ui));
      curve = genBezier(points, first, last, up, tHat1, tHat2);
      ({ err, split } = maxError(points, first, last, curve, up));
      if (err < errSq) return [curve];
      u = up;
    }
  }
  if (split <= first || split >= last || depth > 22) return [curve];   // give up gracefully
  const tHatC = vnorm(vsub(points[split - 1], points[split + 1]));
  return fitCubic(points, first, split, tHat1, tHatC, errSq, depth + 1)
    .concat(fitCubic(points, split, last, [-tHatC[0], -tHatC[1]], tHat2, errSq, depth + 1));
}
function chordParam(points, first, last) {
  const u = [0];
  for (let i = first + 1; i <= last; i++) u.push(u[u.length - 1] + vlen(vsub(points[i], points[i - 1])));
  const tot = u[u.length - 1] || 1;
  return u.map(x => x / tot);
}
function genBezier(points, first, last, uP, tHat1, tHat2) {
  const nPts = last - first + 1, A = [];
  for (let i = 0; i < nPts; i++) { const u = uP[i]; A.push([vscale(tHat1, 3 * u * (1 - u) * (1 - u)), vscale(tHat2, 3 * u * u * (1 - u))]); }
  let C00 = 0, C01 = 0, C11 = 0, X0 = 0, X1 = 0;
  const p0 = points[first], p3 = points[last];
  for (let i = 0; i < nPts; i++) {
    const u = uP[i], b0 = (1 - u) ** 3, b1 = 3 * u * (1 - u) ** 2, b2 = 3 * u * u * (1 - u), b3 = u ** 3;
    C00 += vdot(A[i][0], A[i][0]); C01 += vdot(A[i][0], A[i][1]); C11 += vdot(A[i][1], A[i][1]);
    const tmp = vsub(points[first + i], [p0[0] * (b0 + b1) + p3[0] * (b2 + b3), p0[1] * (b0 + b1) + p3[1] * (b2 + b3)]);
    X0 += vdot(A[i][0], tmp); X1 += vdot(A[i][1], tmp);
  }
  const detCC = C00 * C11 - C01 * C01, detCX = C00 * X1 - C01 * X0, detXC = X0 * C11 - X1 * C01;
  let aL = detCC === 0 ? 0 : detXC / detCC, aR = detCC === 0 ? 0 : detCX / detCC;
  const segLen = vlen(vsub(p3, p0)), eps = 1e-6 * segLen;
  if (aL < eps || aR < eps) { const dist = segLen / 3; aL = dist; aR = dist; }
  return [p0, vadd(p0, vscale(tHat1, aL)), vadd(p3, vscale(tHat2, aR)), p3];
}
function maxError(points, first, last, curve, u) {
  let err = 0, split = Math.floor((first + last) / 2);
  for (let i = first + 1; i < last; i++) {
    const P = bez(curve, u[i - first]);
    const dx = P[0] - points[i][0], dy = P[1] - points[i][1], d = dx * dx + dy * dy;
    if (d >= err) { err = d; split = i; }
  }
  return { err, split };
}
function newton(Q, P, u) {
  const Q1 = [vscale(vsub(Q[1], Q[0]), 3), vscale(vsub(Q[2], Q[1]), 3), vscale(vsub(Q[3], Q[2]), 3)];
  const Q2 = [vscale(vsub(Q1[1], Q1[0]), 2), vscale(vsub(Q1[2], Q1[1]), 2)];
  const Qu = bez(Q, u), Q1u = bez(Q1, u), Q2u = bez(Q2, u);
  const num = vdot(vsub(Qu, P), Q1u), den = vdot(Q1u, Q1u) + vdot(vsub(Qu, P), Q2u);
  if (!den) return u;
  const nu = u - num / den;
  return (nu < 0 || nu > 1 || Number.isNaN(nu)) ? u : nu;
}

/* ═════════════════════ v3: Potrace-style global geometry stage ═════════════════════
   Implemented from the PAPER: Selinger, "Potrace: a polygon-based tracing algorithm"
   (2003), https://potrace.sourceforge.net/potrace.pdf — no GPL code consulted.
   Adapted to dense sub-pixel rings from soft-field marching squares (~1 vertex/px,
   NOT an integer lattice path):
     P2  straightness = Euclidean tube around the chord (the paper's max-distance +
         "not all four directions" clause are lattice-specific and dropped);
         possible segment i->j iff the subpath clipped-extended by one vertex at
         both ends, v(i-1)..v(j+1), is straight (paper §2.2.2 — the clipping is
         what prevents strange behaviour at corners). Computed per-anchor with an
         incremental constraint-cone: each tested vertex restricts the admissible
         chord direction to an angular interval; O(1) update + check per advance.
     P3  penalty P(i,j) = |vj-vi| * RMS distance of subpath points from the chord
         line, closed form from prefix sums of x, y, x², y², xy (paper §2.2.3).
     P4  optimal polygon: lexicographic (segment count, total penalty) DP over the
         chain obtained by cutting the ring at the sharpest windowed turn (§2.2.4).
     P5  vertex adjustment: least-squares line fit (centroid + dominant covariance
         eigenvector) per polygon edge; each vertex re-placed at the intersection
         of its two adjacent lines, clamped into a disc of radius adjustR around
         the original ring vertex (§2.3.1, unit square -> disc).
     P6  corner analysis: alpha = 4*gamma/3 from the tolerance-square construction
         (§2.3.3); alpha > alphaMax => hard corner (two straight lines through a_i),
         else cubic Bézier b(i-1)->b(i) with control points at fraction
         clamp(alpha, 0.55, 1) from the midpoints toward a_i.
     P8  (ours, logo polish): snap edge lines within snapDeg of exact 0/90° (and
         snap45Deg of 45°) to the exact angle BEFORE vertex intersection, then
         merge collinear neighbours. Logos are full of axis-aligned strokes. */

function prepRing(poly, minSeg) {
  let ring = poly;
  if (ring.length > 1 &&
      Math.abs(ring[0][0] - ring[ring.length - 1][0]) < 1e-9 &&
      Math.abs(ring[0][1] - ring[ring.length - 1][1]) < 1e-9)
    ring = ring.slice(0, -1);
  if (minSeg > 0 && ring.length > 4) {
    const out = [ring[0]];
    for (let i = 1; i < ring.length; i++) {
      const p = out[out.length - 1], q = ring[i];
      if (Math.hypot(q[0] - p[0], q[1] - p[1]) >= minSeg) out.push(q);
    }
    while (out.length > 3 &&
           Math.hypot(out[0][0] - out[out.length - 1][0], out[0][1] - out[out.length - 1][1]) < minSeg)
      out.pop();
    if (out.length >= 4) ring = out;
  }
  return ring;
}

// P2: maximal pivot advance per anchor. len[i] = largest a such that i -> i+a is a
// possible segment (early-exit at first failure, per the paper's interval property).
export function pivotLens(R, tol) {
  const n = R.length, len = new Int32Array(n);
  const maxAdv = Math.max(1, n - 3);
  for (let i = 0; i < n; i++) {
    const anchor = R[(i - 1 + n) % n];
    let lo = 0, hi = 0, hasRef = false, empty = false, adv = 1;
    const addC = (k) => {
      const p = R[k % n];
      const dx = p[0] - anchor[0], dy = p[1] - anchor[1];
      const d = Math.hypot(dx, dy);
      if (d <= tol) return;                       // inside every line's tube — no constraint
      let base = Math.atan2(dy, dx);
      const half = Math.asin(Math.min(1, tol / d));
      if (!hasRef) { hasRef = true; lo = base - half; hi = base + half; return; }
      const mid = (lo + hi) / 2;
      while (base - mid > Math.PI) base -= 2 * Math.PI;
      while (base - mid < -Math.PI) base += 2 * Math.PI;
      if (base - half > lo) lo = base - half;
      if (base + half < hi) hi = base + half;
      if (lo > hi) empty = true;
    };
    const dirOK = (k) => {
      if (!hasRef) return true;
      const p = R[k % n];
      const dx = p[0] - anchor[0], dy = p[1] - anchor[1];
      if (dx * dx + dy * dy < 1e-18) return false;
      let a = Math.atan2(dy, dx);
      const mid = (lo + hi) / 2;
      while (a - mid > Math.PI) a -= 2 * Math.PI;
      while (a - mid < -Math.PI) a += 2 * Math.PI;
      return a >= lo - 1e-9 && a <= hi + 1e-9;
    };
    addC(i);
    for (let a = 1; a <= maxAdv; a++) {
      addC(i + a);                                 // test set is now i..i+a
      if (empty) break;
      if (!dirOK(i + a + 1)) break;                // chord anchor v(i-1) -> v(j+1)
      adv = a;
    }
    len[i] = adv;
  }
  return len;
}

export function potracePath(poly, o, dbg) {
  const ring0 = prepRing(poly, o.minSeg);
  const n = ring0.length;
  if (n < 8) return n >= 3 ? polyPath(ring0) : '';

  // ── cut the ring at the sharpest windowed turn (near-certain polygon vertex) ──
  const win = Math.max(2, Math.min(8, n >> 3));
  let rot = 0, worst = 2;
  for (let i = 0; i < n; i++) {
    const p0 = ring0[(i - win + n) % n], p1 = ring0[i], p2 = ring0[(i + win) % n];
    const ax = p1[0] - p0[0], ay = p1[1] - p0[1], bx = p2[0] - p1[0], by = p2[1] - p1[1];
    const la = Math.hypot(ax, ay) || 1, lb = Math.hypot(bx, by) || 1;
    const cos = (ax * bx + ay * by) / (la * lb);
    if (cos < worst) { worst = cos; rot = i; }
  }
  const R = ring0.slice(rot).concat(ring0.slice(0, rot));

  // ── P2: pivots ──
  const len = pivotLens(R, o.tubeTol);

  // ── P3: prefix sums (chain indices 0..n; vertex n ≡ vertex 0) ──
  const Sx = new Float64Array(n + 2), Sy = new Float64Array(n + 2),
        Sxx = new Float64Array(n + 2), Syy = new Float64Array(n + 2), Sxy = new Float64Array(n + 2);
  for (let k = 1; k <= n + 1; k++) {
    const p = R[(k - 1) % n];
    Sx[k] = Sx[k - 1] + p[0]; Sy[k] = Sy[k - 1] + p[1];
    Sxx[k] = Sxx[k - 1] + p[0] * p[0]; Syy[k] = Syy[k - 1] + p[1] * p[1]; Sxy[k] = Sxy[k - 1] + p[0] * p[1];
  }
  const pen = (i, j) => {
    const a = R[i % n], b = R[j % n];
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const cnt = j - i + 1;
    const Ex = (Sx[j + 1] - Sx[i]) / cnt, Ey = (Sy[j + 1] - Sy[i]) / cnt;
    const mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2;
    const A = (Sxx[j + 1] - Sxx[i]) / cnt - 2 * mx * Ex + mx * mx;
    const B = (Sxy[j + 1] - Sxy[i]) / cnt - mx * Ey - my * Ex + mx * my;
    const C = (Syy[j + 1] - Syy[i]) / cnt - 2 * my * Ey + my * my;
    return Math.sqrt(Math.max(0, A * dy * dy - 2 * B * dx * dy + C * dx * dx));
  };

  // ── P4: lexicographic (count, penalty) DP over the cut chain ──
  const segs = new Int32Array(n + 1).fill(-1);
  const penA = new Float64Array(n + 1).fill(Infinity);
  const prev = new Int32Array(n + 1).fill(-1);
  segs[0] = 0; penA[0] = 0;
  for (let i = 0; i < n; i++) {
    if (segs[i] < 0) continue;
    const jmax = Math.min(i + len[i], n);
    for (let j = i + 1; j <= jmax; j++) {
      const s = segs[i] + 1, p = penA[i] + pen(i, j);
      if (segs[j] < 0 || s < segs[j] || (s === segs[j] && p < penA[j])) {
        segs[j] = s; penA[j] = p; prev[j] = i;
      }
    }
  }
  if (segs[n] < 0) return polyPath(ring0);           // unreachable (degenerate) — fallback
  const chain = [n];
  for (let c = n; c > 0;) { c = prev[c]; chain.push(c); }
  chain.reverse();                                    // [0, c1, ..., n]
  let K = chain.length - 1;                           // polygon vertex/edge count
  if (K < 3) return polyPath(ring0);

  // ── P5: least-squares line per edge ──
  const normUnit = (x, y) => { const l = Math.hypot(x, y); return l > 1e-12 ? [x / l, y / l] : [1, 0]; };
  const fitEdge = (e0, e1) => {
    const cnt = e1 - e0 + 1;
    const Ex = (Sx[e1 + 1] - Sx[e0]) / cnt, Ey = (Sy[e1 + 1] - Sy[e0]) / cnt;
    const a = R[e0 % n], b = R[e1 % n];
    let dir;
    if (cnt === 2) dir = normUnit(b[0] - a[0], b[1] - a[1]);
    else {
      const A = (Sxx[e1 + 1] - Sxx[e0]) / cnt - Ex * Ex;
      const B = (Sxy[e1 + 1] - Sxy[e0]) / cnt - Ex * Ey;
      const C = (Syy[e1 + 1] - Syy[e0]) / cnt - Ey * Ey;
      const lam = (A + C) / 2 + Math.sqrt(((A - C) / 2) ** 2 + B * B);
      let vx = B, vy = lam - A;
      if (Math.abs(vx) < 1e-12 && Math.abs(vy) < 1e-12) { vx = A >= C ? 1 : 0; vy = A >= C ? 0 : 1; }
      dir = normUnit(vx, vy);
      if (dir[0] * (b[0] - a[0]) + dir[1] * (b[1] - a[1]) < 0) dir = [-dir[0], -dir[1]];
    }
    return { cx: Ex, cy: Ey, dir, e0, e1 };
  };
  const lineIntersect = (L1, L2) => {
    const n1 = [-L1.dir[1], L1.dir[0]], n2 = [-L2.dir[1], L2.dir[0]];
    const c1 = n1[0] * L1.cx + n1[1] * L1.cy, c2 = n2[0] * L2.cx + n2[1] * L2.cy;
    const det = n1[0] * n2[1] - n1[1] * n2[0];
    if (Math.abs(det) < 1e-6) return null;
    return [(c1 * n2[1] - c2 * n1[1]) / det, (n1[0] * c2 - n2[0] * c1) / det];
  };

  // vertex/edge lists (edge t runs from vertex t to vertex t+1; support = chain range)
  let V = [], ES = [];
  for (let t = 0; t < K; t++) { V.push({ idx: chain[t], clampR: o.adjustR }); ES.push({ e0: chain[t], e1: chain[t + 1] }); }

  // ── chamfer collapse (our adaptation) ─────────────────────────────────────
  // On an AA-rounded corner the clipped possible-segment relation cannot reach the
  // apex, so the DP leaves 1-2 tiny "chamfer" edges across each corner arc. Collapse
  // every run of tiny edges bounded by two long edges into ONE vertex; P5 then puts
  // it at the intersection of the long edges' fitted lines — the true corner.
  // Guards keep genuine micro-features alive: real corner turn angle, intersection
  // close to the arc, bounded run chord.
  {
    const CH_MAX = o.chamferMax, RUN_MAX = 1.6 * o.chamferMax;
    const chordOf = E => { const a = R[E.e0 % n], b = R[E.e1 % n]; return Math.hypot(b[0] - a[0], b[1] - a[1]); };
    let base = -1;
    for (let t = 0; t < ES.length; t++) if (chordOf(ES[t]) > CH_MAX) { base = t; break; }
    if (base >= 0) {
      if (base > 0) { V = V.slice(base).concat(V.slice(0, base)); ES = ES.slice(base).concat(ES.slice(0, base)); }
      const NV = [], NE = [];
      const Kc = ES.length;
      let skipVert = false, t = 0;
      while (t < Kc) {
        if (chordOf(ES[t]) > CH_MAX) {
          if (!skipVert) NV.push(V[t]); else skipVert = false;
          NE.push(ES[t]); t++; continue;
        }
        let t1 = t;
        while (t1 + 1 < Kc && chordOf(ES[t1 + 1]) <= CH_MAX) t1++;
        let collapsed = false;
        if (t1 + 1 < Kc && NE.length) {                       // run not touching the seam
          const a0 = R[ES[t].e0 % n], a1 = R[ES[t1].e1 % n];
          const runChord = Math.hypot(a1[0] - a0[0], a1[1] - a0[1]);
          const prevE = NE[NE.length - 1], nextE = ES[t1 + 1];
          if (runChord <= RUN_MAX &&
              chordOf(prevE) >= Math.max(10, 2.5 * runChord) &&
              chordOf(nextE) >= Math.max(10, 2.5 * runChord)) {
            const L1 = fitEdge(prevE.e0, prevE.e1), L2 = fitEdge(nextE.e0, nextE.e1);
            const crossD = L1.dir[0] * L2.dir[1] - L1.dir[1] * L2.dir[0];
            const dotD = L1.dir[0] * L2.dir[0] + L1.dir[1] * L2.dir[1];
            const turn = Math.abs(Math.atan2(crossD, dotD)) * 180 / Math.PI;
            if (turn > 18 && turn < 160) {
              const X = lineIntersect(L1, L2);
              if (X) {
                const midIdx = Math.round((ES[t].e0 + ES[t1].e1) / 2);
                const M = R[midIdx % n];
                const dm = Math.hypot(X[0] - M[0], X[1] - M[1]);
                const d0 = Math.hypot(X[0] - a0[0], X[1] - a0[1]);
                const d1 = Math.hypot(X[0] - a1[0], X[1] - a1[1]);
                if (dm <= 0.85 * runChord + 1.0 && d0 <= runChord + 1.2 && d1 <= runChord + 1.2) {
                  NV.push({ idx: midIdx, clampR: Math.max(o.adjustR, dm + 0.5) });
                  skipVert = true;                             // consumed vertex t1+1 too
                  collapsed = true;
                }
              }
            }
          }
        }
        if (!collapsed) {
          for (let k = t; k <= t1; k++) {
            if (k === t) { if (!skipVert) NV.push(V[k]); else skipVert = false; }
            else NV.push(V[k]);
            NE.push(ES[k]);
          }
        }
        t = t1 + 1;
      }
      if (NV.length === NE.length && NV.length >= 3) { V = NV; ES = NE; }
    }
  }
  K = V.length;
  if (K < 3) return polyPath(ring0);

  let edges = ES.map(E => fitEdge(E.e0, E.e1));

  // ── P8: axis snap (rotate the fitted line about its centroid) ──
  if (o.axisSnap) {
    for (const E of edges) {
      const th = Math.atan2(E.dir[1], E.dir[0]) * 180 / Math.PI;
      const mod90 = ((th % 90) + 90) % 90;
      const d0 = Math.min(mod90, 90 - mod90);
      const d45 = Math.abs(mod90 - 45);
      let delta = 0;
      if (d0 <= o.snapDeg) delta = mod90 < 45 ? -mod90 : (90 - mod90);
      else if (d45 <= o.snap45Deg) delta = 45 - mod90;
      if (delta !== 0) {
        const r = (th + delta) * Math.PI / 180;
        E.dir = [Math.cos(r), Math.sin(r)];
      }
      // FIX 10b: a LONG snapped exact-vertical/horizontal line whose offset is
      // fractional renders as a sustained half-covered column/row — a blend
      // colour a crisp steppy source never contains. Land long snapped lines
      // on the working-px boundary grid (integers in pixel-centre coords);
      // rounding error <= 0.5 working px, unbiased. Short edges (glyph stems)
      // keep their sub-px placement — their mass is too small for the blend
      // mismatch to register, but their position error would compound.
      {
        const a = R[E.e0 % n], b = R[E.e1 % n];
        if (Math.hypot(b[0] - a[0], b[1] - a[1]) >= 10) {
          if (Math.abs(E.dir[0]) < 1e-9) E.cx = Math.round(E.cx);
          else if (Math.abs(E.dir[1]) < 1e-9) E.cy = Math.round(E.cy);
        }
      }
    }
  }

  // ── P5 (cont.): vertex = intersection of adjacent lines, clamped into disc ──
  const placeVertex = (E1, E2, v0, r) => {
    const X = lineIntersect(E1, E2);
    let x, y;
    if (!X) {                                          // near-parallel: average projections of v0
      const n1 = [-E1.dir[1], E1.dir[0]], n2 = [-E2.dir[1], E2.dir[0]];
      const d1 = n1[0] * (v0[0] - E1.cx) + n1[1] * (v0[1] - E1.cy);
      const d2 = n2[0] * (v0[0] - E2.cx) + n2[1] * (v0[1] - E2.cy);
      x = v0[0] - (d1 * n1[0] + d2 * n2[0]) / 2;
      y = v0[1] - (d1 * n1[1] + d2 * n2[1]) / 2;
    } else { x = X[0]; y = X[1]; }
    const dx = x - v0[0], dy = y - v0[1], d = Math.hypot(dx, dy);
    if (d > r) { const s = r / d; x = v0[0] + dx * s; y = v0[1] + dy * s; }
    return [x, y];
  };
  let A = [], polyIdx = [];
  for (let t = 0; t < K; t++) {
    A.push(placeVertex(edges[(t - 1 + K) % K], edges[t], R[V[t].idx % n], V[t].clampR));
    polyIdx.push(V[t].idx);
  }

  // merge collinear neighbours created by snapping (vertex within 0.15px of its neighbours' segment)
  for (let t = 0; t < A.length && A.length > 3;) {
    const Kc = A.length;
    const p0 = A[(t - 1 + Kc) % Kc], p1 = A[t], p2 = A[(t + 1) % Kc];
    const ux = p2[0] - p0[0], uy = p2[1] - p0[1], L = Math.hypot(ux, uy) || 1;
    const dev = Math.abs((p1[0] - p0[0]) * uy - (p1[1] - p0[1]) * ux) / L;
    if (dev < 0.15) {
      A.splice(t, 1); polyIdx.splice(t, 1);
      const Ke = ES.length, tp = (t - 1 + Ke) % Ke;
      ES[tp] = { e0: ES[tp].e0, e1: ES[t % Ke].e1 };   // merge supports (debug only)
      ES.splice(t % Ke, 1);
    }
    else t++;
  }
  K = A.length;
  if (K < 3) return polyPath(ring0);

  // debug: per-edge max residual of supporting ring points vs final polygon segment
  if (dbg) {
    const eds = [];
    for (let t = 0; t < K; t++) {
      const e0 = ES[t].e0, e1 = ES[t].e1;
      const a = A[t], b = A[(t + 1) % K];
      const ux = b[0] - a[0], uy = b[1] - a[1], L = Math.hypot(ux, uy) || 1;
      let mx = 0;
      for (let k = e0; k <= e1; k++) {
        const p = R[k % n];
        const d = Math.abs((p[0] - a[0]) * uy - (p[1] - a[1]) * ux) / L;
        if (d > mx) mx = d;
      }
      eds.push({ support: e1 - e0 + 1, len: L, angle: Math.atan2(uy, ux) * 180 / Math.PI, maxResid: mx });
    }
    dbg.push({ n, K, edges: eds, A: A.map(p => p.slice()) });
  }

  // ── P6: corner analysis → pieces (each piece runs b(i-1) -> b(i) via vertex a_i) ──
  const mids = A.map((p, t) => { const q = A[(t + 1) % K]; return [(p[0] + q[0]) / 2, (p[1] + q[1]) / 2]; });
  let pieces = [];
  for (let s = 1; s <= K; s++) {
    const t = s % K;
    const aP = A[t], bPrev = mids[s - 1], bCur = mids[t];
    const ex = bCur[0] - bPrev[0], ey = bCur[1] - bPrev[1];
    const eL = Math.hypot(ex, ey);
    let alpha;
    if (eL < 1e-9) alpha = 2;                          // degenerate: corner
    else {
      const nx = -ey / eL, ny = ex / eL;
      const d = Math.abs((aP[0] - bPrev[0]) * nx + (aP[1] - bPrev[1]) * ny);
      const delta = o.cornerBox * (Math.abs(nx) + Math.abs(ny)) / 2;
      const gamma = d > 1e-12 ? (d - delta) / d : 0;
      alpha = 4 * gamma / 3;
    }
    if (alpha > o.alphaMax) pieces.push({ corner: true, a: aP, from: bPrev, to: bCur });
    else {
      const al = Math.max(0.55, Math.min(1, alpha));
      pieces.push({
        corner: false, a: aP, from: bPrev, to: bCur,
        c1: [bPrev[0] + al * (aP[0] - bPrev[0]), bPrev[1] + al * (aP[1] - bPrev[1])],
        c2: [bCur[0] + al * (aP[0] - bCur[0]), bCur[1] + al * (aP[1] - bCur[1])],
      });
    }
  }

  // ── P7: opticurve (paper §2.4) ──
  if (o.optiCurve && pieces.length > 2) pieces = optiCurve(pieces, o.optTol);

  // ── emit ──
  const f2 = v => Math.round(v * 100) / 100;
  const cmds = [];
  for (const p of pieces) {
    if (p.corner) { cmds.push(['L', p.a[0], p.a[1]]); cmds.push(['L', p.to[0], p.to[1]]); }
    else cmds.push(['C', p.c1[0], p.c1[1], p.c2[0], p.c2[1], p.to[0], p.to[1]]);
  }
  // cleanup: drop L endpoints collinear with their neighbours (corner-corner midpoints)
  const start = pieces[0].from;
  for (let pass = 0; pass < 4; pass++) {
    let changed = false;
    for (let i = 0; i + 1 < cmds.length; i++) {
      if (cmds[i][0] !== 'L' || cmds[i + 1][0] !== 'L') continue;
      const p0 = i === 0 ? start : cmds[i - 1].slice(-2);
      const p1 = [cmds[i][1], cmds[i][2]], p2 = [cmds[i + 1][1], cmds[i + 1][2]];
      const ux = p2[0] - p0[0], uy = p2[1] - p0[1], L = Math.hypot(ux, uy) || 1;
      const dev = Math.abs((p1[0] - p0[0]) * uy - (p1[1] - p0[1]) * ux) / L;
      if (dev < 0.05) { cmds.splice(i, 1); changed = true; i--; }
    }
    if (!changed) break;
  }
  let d = `M${f2(start[0])} ${f2(start[1])}`;
  for (const c of cmds) {
    if (c[0] === 'L') d += `L${f2(c[1])} ${f2(c[2])}`;
    else d += `C${f2(c[1])} ${f2(c[2])} ${f2(c[3])} ${f2(c[4])} ${f2(c[5])} ${f2(c[6])}`;
  }
  return d + 'Z';
}

/* ── P7: curve optimization (paper §2.4) ──────────────────────────────────
   Join runs of consecutive smooth Bézier pieces that agree in convexity and
   turn < 179° total into single Béziers: endpoints keep their tangents (so the
   join is tangent to b(j)a(j+1) and a(k)b(k)); the free parameter alpha is set
   by matching the enclosed area; the candidate is accepted iff for every
   interior polygon edge a(i)a(i+1) the point on the candidate with parallel
   tangent lies within `tol` of that segment. DP minimizes (count, sum d²). */
const bezPt = (Z, t) => {
  const u = 1 - t;
  return [
    u * u * u * Z[0][0] + 3 * u * u * t * Z[1][0] + 3 * u * t * t * Z[2][0] + t * t * t * Z[3][0],
    u * u * u * Z[0][1] + 3 * u * u * t * Z[1][1] + 3 * u * t * t * Z[2][1] + t * t * t * Z[3][1],
  ];
};
// signed ∮(x dy − y dx)/2 contribution of a cubic segment (4-pt Gauss–Legendre, exact)
const GL_T = [0.069431844202973, 0.330009478207572, 0.669990521792428, 0.930568155797027];
const GL_W = [0.173927422568727, 0.326072577431273, 0.326072577431273, 0.173927422568727];
function bezAreaTerm(Z) {
  let s = 0;
  for (let g = 0; g < 4; g++) {
    const t = GL_T[g], u = 1 - t;
    const x = u * u * u * Z[0][0] + 3 * u * u * t * Z[1][0] + 3 * u * t * t * Z[2][0] + t * t * t * Z[3][0];
    const y = u * u * u * Z[0][1] + 3 * u * u * t * Z[1][1] + 3 * u * t * t * Z[2][1] + t * t * t * Z[3][1];
    const dx = 3 * ((Z[1][0] - Z[0][0]) * u * u + 2 * (Z[2][0] - Z[1][0]) * u * t + (Z[3][0] - Z[2][0]) * t * t);
    const dy = 3 * ((Z[1][1] - Z[0][1]) * u * u + 2 * (Z[2][1] - Z[1][1]) * u * t + (Z[3][1] - Z[2][1]) * t * t);
    s += GL_W[g] * (x * dy - y * dx);
  }
  return s / 2;
}
function optiCurve(pieces, tol) {
  const m0 = pieces.length;
  // rotate so a corner (if any) sits at index 0 — runs then never wrap
  let rot = -1;
  for (let i = 0; i < m0; i++) if (pieces[i].corner) { rot = i; break; }
  const P = rot > 0 ? pieces.slice(rot).concat(pieces.slice(0, rot)) : pieces.slice();
  const out = [];
  let i = 0;
  while (i < m0) {
    if (P[i].corner) { out.push(P[i]); i++; continue; }
    let j = i;
    while (j + 1 < m0 && !P[j + 1].corner) j++;
    const run = P.slice(i, j + 1);
    for (const p of optiRun(run, tol)) out.push(p);
    i = j + 1;
  }
  return out;
}
function optiRun(run, tol) {
  const m = run.length;
  if (m < 2) return run;
  // exterior turn per piece (signed, at its vertex) + prefix sums
  const ext = run.map(p => {
    const u1 = [p.a[0] - p.from[0], p.a[1] - p.from[1]];
    const u2 = [p.to[0] - p.a[0], p.to[1] - p.a[1]];
    return Math.atan2(u1[0] * u2[1] - u1[1] * u2[0], u1[0] * u2[0] + u1[1] * u2[1]);
  });
  const MAX_TURN = 179 * Math.PI / 180;
  // per-piece area terms (piece cubic + nothing else; chords handled per candidate)
  const pieceArea = run.map(p => bezAreaTerm([p.from, p.c1, p.c2, p.to]));
  const preA = [0], preT = [0], preSgn = [0];
  for (let k = 0; k < m; k++) {
    preA.push(preA[k] + pieceArea[k]);
    preT.push(preT[k] + Math.abs(ext[k]));
    preSgn.push(preSgn[k] + Math.sign(ext[k]));
  }
  const tryJoin = (u, v) => {              // join pieces u..v-1 into one cubic; null if not acceptable
    const cnt = v - u;
    if (cnt < 2) return null;
    if (preT[v] - preT[u] >= MAX_TURN) return null;
    if (Math.abs(preSgn[v] - preSgn[u]) !== cnt) return null;      // convexity agreement
    const z0 = run[u].from, z3 = run[v - 1].to;
    const d1 = [run[u].a[0] - z0[0], run[u].a[1] - z0[1]];
    const d2 = [z3[0] - run[v - 1].a[0], z3[1] - run[v - 1].a[1]];
    const det = d1[0] * (-d2[1]) - d1[1] * (-d2[0]);
    if (Math.abs(det) < 1e-9) return null;
    // z0 + s·d1 = z3 − r·d2
    const rx = z3[0] - z0[0], ry = z3[1] - z0[1];
    const s = (rx * (-d2[1]) - ry * (-d2[0])) / det;
    const r = (d1[0] * ry - d1[1] * rx) / det;
    if (s <= 1e-9 || r >= -1e-9) return null;                       // O ahead of z0 (s>0), behind z3 (r<0: O = z3 + r·d2)
    const O = [z0[0] + s * d1[0], z0[1] + s * d1[1]];
    // enclosed area: composite curve pieces + closing chord z3->z0 (closed loop, origin-independent)
    const Achord = (preA[v] - preA[u]) + (z3[0] * z0[1] - z3[1] * z0[0]) / 2;
    // triangle z0, O, z3 (same loop orientation)
    const AtriLoop = ((z0[0] * O[1] - z0[1] * O[0]) + (O[0] * z3[1] - O[1] * z3[0]) + (z3[0] * z0[1] - z3[1] * z0[0])) / 2;
    if (Math.abs(AtriLoop) < 1e-9) return null;
    const rho = Achord / AtriLoop;
    if (!(rho > 0.02)) return null;
    const disc = 4 - 10 * rho / 3;
    if (disc < 0) return null;
    const alpha = 2 - Math.sqrt(disc);
    if (!(alpha > 0.05 && alpha <= 1.0)) return null;
    const Z = [z0, [z0[0] + alpha * (O[0] - z0[0]), z0[1] + alpha * (O[1] - z0[1])],
                   [z3[0] + alpha * (O[0] - z3[0]), z3[1] + alpha * (O[1] - z3[1])], z3];
    // tangency acceptance on interior polygon edges a(k) -> a(k+1)
    let pen = 0;
    for (let k = u; k < v - 1; k++) {
      const a1 = run[k].a, a2 = run[k + 1].a;
      const dx = a2[0] - a1[0], dy = a2[1] - a1[1];
      const L = Math.hypot(dx, dy);
      if (L < 1e-9) return null;
      // B'(t) ∥ (dx,dy): cross(B'(t), dir) = 0 → quadratic in t
      const p1 = [Z[1][0] - Z[0][0], Z[1][1] - Z[0][1]];
      const p2 = [Z[2][0] - Z[1][0], Z[2][1] - Z[1][1]];
      const p3 = [Z[3][0] - Z[2][0], Z[3][1] - Z[2][1]];
      const c0 = p1[0] * dy - p1[1] * dx;
      const c1q = p2[0] * dy - p2[1] * dx;
      const c2q = p3[0] * dy - p3[1] * dx;
      const qa = c0 - 2 * c1q + c2q, qb = 2 * (c1q - c0), qc = c0;
      const roots = [];
      if (Math.abs(qa) < 1e-12) { if (Math.abs(qb) > 1e-12) roots.push(-qc / qb); }
      else {
        const D = qb * qb - 4 * qa * qc;
        if (D >= 0) { const sq = Math.sqrt(D); roots.push((-qb + sq) / (2 * qa), (-qb - sq) / (2 * qa)); }
      }
      let best = null;
      for (const t of roots) {
        if (!(t >= -1e-9 && t <= 1 + 1e-9)) continue;
        const z = bezPt(Z, Math.min(1, Math.max(0, t)));
        const proj = ((z[0] - a1[0]) * dx + (z[1] - a1[1]) * dy) / (L * L);
        if (proj < -0.15 || proj > 1.15) continue;
        const d = Math.abs((z[0] - a1[0]) * dy - (z[1] - a1[1]) * dx) / L;
        if (best === null || d < best) best = d;
      }
      if (best === null || best > tol) return null;
      pen += best * best;
    }
    return { pen, Z };
  };
  // DP over boundaries 0..m minimizing (count, penalty)
  const cnt = new Int32Array(m + 1).fill(1 << 29);
  const pen = new Float64Array(m + 1).fill(Infinity);
  const prv = new Int32Array(m + 1).fill(-1);
  const arc = new Array(m + 1).fill(null);
  cnt[0] = 0; pen[0] = 0;
  for (let u = 0; u < m; u++) {
    if (cnt[u] >= (1 << 29)) continue;
    // single piece
    if (cnt[u] + 1 < cnt[u + 1] || (cnt[u] + 1 === cnt[u + 1] && pen[u] < pen[u + 1])) {
      cnt[u + 1] = cnt[u] + 1; pen[u + 1] = pen[u]; prv[u + 1] = u; arc[u + 1] = null;
    }
    for (let v = u + 2; v <= m; v++) {
      if (preT[v] - preT[u] >= MAX_TURN) break;
      const J = tryJoin(u, v);
      if (!J) continue;
      const c = cnt[u] + 1, p = pen[u] + J.pen;
      if (c < cnt[v] || (c === cnt[v] && p < pen[v])) { cnt[v] = c; pen[v] = p; prv[v] = u; arc[v] = J.Z; }
    }
  }
  // reconstruct
  const outR = [];
  let v = m;
  const segsR = [];
  while (v > 0) { segsR.push(v); v = prv[v]; }
  segsR.reverse();
  let u = 0;
  for (const vv of segsR) {
    if (arc[vv] && prv[vv] === u && vv - u >= 2) {
      const Z = arc[vv];
      outR.push({ corner: false, a: null, from: Z[0], to: Z[3], c1: Z[1], c2: Z[2] });
    } else if (vv - u === 1) outR.push(run[u]);
    else { for (let k = u; k < vv; k++) outR.push(run[k]); } // shouldn't happen
    u = vv;
  }
  return outR;
}

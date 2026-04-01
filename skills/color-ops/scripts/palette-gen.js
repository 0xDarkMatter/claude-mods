#!/usr/bin/env node
// Palette generator - produce a 10-step OKLCH scale as CSS custom properties
// Usage: node palette-gen.js <hue> [name] [--neutral] [--json]
//
// Examples:
//   node palette-gen.js 250              # Blue scale (default name: "brand")
//   node palette-gen.js 250 blue         # Named "blue"
//   node palette-gen.js 250 blue --neutral  # Also generate a neutral scale
//   node palette-gen.js 30 orange --json    # JSON output

const args = process.argv.slice(2);
if (args.length < 1 || args.includes('--help') || args.includes('-h')) {
  console.log(`Usage: node palette-gen.js <hue> [name] [--neutral] [--json]

Arguments:
  hue        OKLCH hue angle (0-360)
  name       Token prefix (default: "brand")

Flags:
  --neutral  Also generate a matching neutral scale (same hue, low chroma)
  --json     Output as JSON instead of CSS

Hue reference:
  0-30   Pink/Red       110-160  Green
  30-70  Orange/Amber   160-200  Teal/Cyan
  70-110 Yellow/Lime    200-260  Blue
                        260-310  Violet
                        310-360  Magenta`);
  process.exit(0);
}

const hue = parseFloat(args[0]);
if (isNaN(hue) || hue < 0 || hue > 360) {
  console.error('Error: Hue must be a number between 0 and 360.');
  process.exit(1);
}

const flags = args.filter(a => a.startsWith('--'));
const positional = args.filter(a => !a.startsWith('--'));
const name = positional[1] || 'brand';
const includeNeutral = flags.includes('--neutral');
const jsonOutput = flags.includes('--json');

function generateScale(hue, chromaMultiplier = 1) {
  const steps = 10;
  return Array.from({ length: steps }, (_, i) => {
    const t = i / (steps - 1);
    const step = (i + 1) * 100; // 100..1000
    const l = +(0.97 - t * 0.82).toFixed(3);
    // Chroma peaks at midtones (sine curve), clamped for neutrals
    const c = +(Math.sin(t * Math.PI) * 0.18 * chromaMultiplier).toFixed(4);
    return { step, l, c, h: hue };
  });
}

function formatOklch(l, c, h) {
  return `oklch(${l} ${c} ${h})`;
}

// --- sRGB conversion for preview swatches ---

function oklchToOklab(L, C, H) {
  const hRad = H * Math.PI / 180;
  return [L, C * Math.cos(hRad), C * Math.sin(hRad)];
}

function oklabToLinearRgb(L, a, b) {
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.2914855480 * b;
  const l = l_ * l_ * l_;
  const m = m_ * m_ * m_;
  const s = s_ * s_ * s_;
  return [
    +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
  ];
}

function linearToSrgb(c) {
  return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

function toHex(l, c, h) {
  const [labL, labA, labB] = oklchToOklab(l, c, h);
  const [lr, lg, lb] = oklabToLinearRgb(labL, labA, labB);
  const clamp = v => Math.round(Math.min(255, Math.max(0, linearToSrgb(v) * 255)));
  return '#' + [clamp(lr), clamp(lg), clamp(lb)].map(v => v.toString(16).padStart(2, '0')).join('');
}

function isInGamut(l, c, h) {
  const [labL, labA, labB] = oklchToOklab(l, c, h);
  const [lr, lg, lb] = oklabToLinearRgb(labL, labA, labB);
  return [lr, lg, lb].every(v => v >= -0.001 && v <= 1.001);
}

// --- Output ---

const brandScale = generateScale(hue);
const neutralScale = includeNeutral ? generateScale(hue, 0.12) : [];

if (jsonOutput) {
  const output = {
    [name]: brandScale.map(s => ({
      step: s.step,
      oklch: formatOklch(s.l, s.c, s.h),
      hex: toHex(s.l, s.c, s.h),
      inGamut: isInGamut(s.l, s.c, s.h),
    })),
  };
  if (includeNeutral) {
    output[`${name}-neutral`] = neutralScale.map(s => ({
      step: s.step,
      oklch: formatOklch(s.l, s.c, s.h),
      hex: toHex(s.l, s.c, s.h),
      inGamut: isInGamut(s.l, s.c, s.h),
    }));
  }
  console.log(JSON.stringify(output, null, 2));
  process.exit(0);
}

// CSS output
function printScale(scaleName, scale) {
  console.log(`  /* ${scaleName} - hue ${hue} */`);
  for (const s of scale) {
    const hex = toHex(s.l, s.c, s.h);
    const gamut = isInGamut(s.l, s.c, s.h) ? '' : ' /* out of sRGB gamut */';
    console.log(`  --${scaleName}-${s.step}: ${formatOklch(s.l, s.c, s.h)};  /* ${hex} */${gamut}`);
  }
}

console.log(`:root {`);
printScale(name, brandScale);
if (includeNeutral) {
  console.log('');
  printScale(`${name}-neutral`, neutralScale);
}
console.log(`}`);

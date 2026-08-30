# Favicons and App Icons

The other end of icon work: the marks that represent the *site*, not the UI
inside it. Different constraints, different failure modes, and a legacy tail
that generates a lot of cargo-culted markup.

Verified 2026-08-30.

---

## The modern minimal set

Four files cover every current browser and platform. Generators that emit
twenty-plus files are producing a 2015 answer.

| File | Size | Why it exists |
|---|---|---|
| `favicon.ico` | 32×32 (multi-res ok) | Legacy fallback; browsers request `/favicon.ico` **even with no link tag** |
| `icon.svg` | any (vector) | The real one — scales to every density, and can adapt to dark mode |
| `apple-touch-icon.png` | 180×180 | iOS home screen; iOS ignores the SVG and the manifest for this |
| `icon-512-maskable.png` | 512×512 | Android adaptive icons, via the web manifest |

```html
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="manifest" href="/manifest.webmanifest">
```

That is the whole head block. Notes on it:

- **Order matters less than `type`.** A browser supporting SVG picks `icon.svg`
  because of the `type` hint; others fall back to the `.ico`.
- **`rel="shortcut icon"` is meaningless.** "shortcut" was never a valid link
  relation; `rel="icon"` alone is correct and has been for many years.
- **Keep `/favicon.ico` at the origin root** regardless of the link tag, because
  browsers, feed readers and link-preview crawlers request that exact path.
- **`apple-touch-icon` must be PNG and must not be transparent** — iOS composites
  it onto a white-to-black gradient and transparency renders as black.

## The SVG favicon can follow the browser theme

The one genuine advantage of the SVG favicon, and it is easy to miss: a media
query *inside* the file works, because the browser evaluates it in the browser's
own context, not the page's.

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <style>
    path { fill: #0f172a; }
    @media (prefers-color-scheme: dark) { path { fill: #f8fafc; } }
  </style>
  <path d="…"/>
</svg>
```

A near-black favicon vanishes into a dark browser chrome; this is the fix, and
it costs one embedded style block. Note this is the opposite of the situation in
page content, where [an internal media query is unreliable](brand-variants.md#lightdark-pairs)
once the SVG is loaded through `<img>`.

## Maskable icons — the safe zone is the whole trick

Android crops your icon to whatever shape the launcher uses: circle, squircle,
rounded square, teardrop. A normal icon gets its corners — often its whole edge —
sliced off.

**The safe zone is a centred circle with a diameter of 80% of the icon.**
Everything outside it may be cropped on some device. So for a 512×512 maskable
icon, all meaningful content sits inside a 409px-diameter centre circle, and the
remaining ~51px band on each side is bleed that must be *filled background*, not
transparency.

```json
{
  "icons": [
    { "src": "/icon-192.png",          "sizes": "192x192", "type": "image/png" },
    { "src": "/icon-512.png",          "sizes": "512x512", "type": "image/png" },
    { "src": "/icon-512-maskable.png", "sizes": "512x512", "type": "image/png",
      "purpose": "maskable" }
  ]
}
```

Ship the maskable variant **as a separate file**. Declaring one icon with
`"purpose": "any maskable"` forces a single artwork to serve both, so it is
either over-padded when used un-cropped or clipped when used masked. Two files,
two purposes.

## Designing the mark down

A favicon is 16 CSS px in a tab. That is not a small logo — it is a different
mark, and the most common mistake is shipping the full wordmark scaled down to
an illegible smudge.

- **Use the symbol, not the wordmark.** If the brand has no symbol, use a single
  letterform.
- **Reduce detail deliberately.** Strokes that read at 200px disappear at 16px;
  thicken them in the favicon artwork rather than trusting the scale.
- **Test at true size against real chrome**, light and dark, with several tabs
  open. A mark that is distinctive alone can be indistinguishable from its
  neighbours in a crowded tab strip.
- **Contrast against browser chrome**, not against your site. The tab background
  is the browser's colour, and it changes with the user's theme.

## Producing them

Favicon generation is a raster pipeline, not an SVG-normalisation job, so it
sits outside `normalize-icon.py`. Do the source cleanup here, the rasterising
elsewhere:

```bash
# 1. Normalize the source mark (keep its colours — this is the brand asset)
normalize-icon.py --keep-colour brand-symbol.svg -o public/icon.svg

# 2. Rasterise. Any of ImageMagick / sharp / rsvg-convert; sizes above.
#    Bake the background INTO the maskable PNG - transparency is not bleed.
```

Two constraints worth carrying into whichever tool does the rasterising:

- **`icon.svg` keeps its `viewBox` and stays square.** A non-square favicon is
  letterboxed unpredictably.
- **Strip the `aria-hidden`/`focusable` attributes** that `normalize-icon.py`
  adds for inline use — harmless in a favicon, but meaningless, and their
  presence suggests the file was copied from the UI icon set rather than
  authored for this.

## Cross-reference

- Normalising and namespacing SVGs → `scripts/normalize-icon.py`
- Mono / knockout / greyscale variants of a mark → [brand-variants.md](brand-variants.md)
- Where brand marks come from → [icon-sources.md](icon-sources.md)

# Images: formats, responsive sizes, priority, lazy loading

Images are usually the LCP element and usually the heaviest bytes on the page. The
four levers, in order of impact: **right size** (srcset/sizes), **right format**
(AVIF/WebP), **right priority** (eager + `fetchpriority` for the LCP, lazy for the rest),
**reserved space** (width/height, for CLS). Compat data: MDN BCD, checked 2026-10-05.

## Contents

- [The canonical markup](#the-canonical-markup)
- [Formats](#formats)
- [srcset and sizes](#srcset-and-sizes)
- [Priority and lazy loading](#priority-and-lazy-loading)
- [Background images, video, icons](#background-images-video-icons)
- [Where transforms happen](#where-transforms-happen)
- [Gotchas](#gotchas)

## The canonical markup

```html
<!-- LCP / hero image: eager, high priority, sized, modern formats -->
<picture>
  <source type="image/avif"
          srcset="/img/hero-640.avif 640w, /img/hero-960.avif 960w, /img/hero-1440.avif 1440w, /img/hero-1920.avif 1920w"
          sizes="100vw">
  <source type="image/webp"
          srcset="/img/hero-640.webp 640w, /img/hero-960.webp 960w, /img/hero-1440.webp 1440w, /img/hero-1920.webp 1920w"
          sizes="100vw">
  <img src="/img/hero-1440.jpg"
       srcset="/img/hero-640.jpg 640w, /img/hero-960.jpg 960w, /img/hero-1440.jpg 1440w, /img/hero-1920.jpg 1920w"
       sizes="100vw" width="1920" height="1080" alt="..."
       fetchpriority="high">
</picture>

<!-- Everything below the fold: lazy, sized -->
<img src="/img/card-480.webp"
     srcset="/img/card-320.webp 320w, /img/card-480.webp 480w, /img/card-720.webp 720w"
     sizes="auto, (min-width: 64rem) 33vw, 100vw"
     width="720" height="480" loading="lazy" decoding="async" alt="...">
```

## Formats

| Format | Support | Use |
|---|---|---|
| **AVIF** | Baseline widely available (Chrome 85, Firefox 113, Safari 16.4, Edge 121) | Best compression for photos; ~50% smaller than JPEG at similar quality. Slow to **encode**, which matters for on-the-fly transforms |
| **WebP** | Universal | Default fallback; fast to encode; ~25-35% smaller than JPEG |
| JPEG / PNG | Universal | Last-resort `<img src>` fallback; PNG only for images that need lossless alpha and do not compress well as WebP |
| JPEG XL | Safari 17+ only; Chrome has it behind a flag, not on by default (2026-10) | Do not ship as the only format |
| SVG | Universal | Logos, icons, illustrations. Run through SVGO; inline the critical ones |
| GIF | - | Never for animation: convert to `<video>` (MP4/WebM), often 5-10x smaller |

Choosing between `<picture>` and content negotiation:

- `<picture>` with typed `<source>`s works with any static host and any cache.
- **Content negotiation** (one URL; the CDN picks AVIF/WebP from the `Accept` header)
  gives shorter markup, but the response must carry `Vary: Accept` or a shared cache will
  serve AVIF to a browser that cannot decode it. Image CDNs (Cloudflare, Imgix,
  Cloudinary, Bunny) handle this for you.

Quality starting points: AVIF q50-60, WebP q75-80, JPEG q75-82. Check by eye on the
template's real images. Skin tones and gradients band first.

## srcset and sizes

| Rule | Why |
|---|---|
| Use `w` descriptors + `sizes` for anything whose rendered width varies with the viewport | The browser picks by layout width x DPR |
| `sizes` must describe the **rendered** width at each breakpoint, not the viewport | `sizes="100vw"` on a 3-column card makes phones download a 3x-too-large file |
| Width steps of ~20-30% (e.g. 320, 480, 720, 960, 1440, 1920) | Fewer steps waste bytes; more steps waste cache and transform time |
| Cap at ~2x the largest rendered width | 3x DPR images cost a lot of bytes for little visible gain |
| `x` descriptors (`1x, 2x`) only for fixed-size images (avatars, logos) | Simpler, and correct when width never changes |
| `sizes="auto"` for **lazy** images | The browser uses the real layout width. Chrome 126, Firefox 150, Safari 27; list a real fallback after `auto` for older browsers |

Debug: DevTools -> Network, check the chosen file's intrinsic width against the
element's rendered width x DPR. Lighthouse 13's `image-delivery-insight` flags
oversized and poorly compressed images with byte savings.

## Priority and lazy loading

| Image | `loading` | `fetchpriority` | Notes |
|---|---|---|---|
| LCP / hero | omit (eager) | `high` | `fetchpriority` is Baseline since Oct 2024 (Firefox 132, Safari 17.2) |
| Other above-the-fold images | omit | omit | Don't mark everything high: priority is relative |
| Hidden carousel slides | `lazy` | `low` | Slides 2+ should not compete with slide 1 |
| Below the fold | `lazy` | omit | Native lazy loading: Chrome 77, Firefox 75, Safari 15.4; iframes too (Firefox 121, Safari 16.4) |
| Iframes (maps, video embeds) | `lazy` | - | Better still: a click-to-load facade |

- **Native `loading="lazy"` beats JavaScript libraries.** `lazysizes` (common on older
  Craft builds via `data-src`) has had no release since 2021-03 and hides images from
  the preload scanner. Migrate to native lazy loading. Keep a JS placeholder effect only
  if the design truly needs it.
- Preload the LCP image only when it is **not** discoverable in the HTML (CSS
  background, JS-rendered). For responsive images, the preload must mirror the `<img>`:
  `<link rel="preload" as="image" imagesrcset="..." imagesizes="..." fetchpriority="high">`
  (`imagesrcset` support: Chrome 73, Firefox 78, Safari 17.2).
- `decoding="async"` lets decoding happen off the critical path. It is a small win, and harmless.

## Background images, video, icons

| Case | Do |
|---|---|
| CSS `background-image` hero | Prefer an `<img>` with `object-fit: cover`. If it stays CSS, use `image-set()` for formats (Chrome 113, Firefox 89, Safari 17) and preload it |
| Autoplaying hero video | `muted playsinline` + a `poster` (the poster is the LCP candidate: optimise it like a hero image); `preload="none"` for below-the-fold video |
| Icon sets | One SVG sprite or inline SVG; never an icon font for a handful of icons |
| User-uploaded originals (8 MB phone photos) | Never serve the original: always through a transform with a max width |

## Where transforms happen

| Approach | Strength | Watch for |
|---|---|---|
| Build-time (sharp, Vite plugins) | Zero runtime cost | Only for images in the repo, not CMS uploads |
| CMS transforms (Craft native, ImageOptimize, Imager X) | Editors upload once, every size is generated | First-request generation latency and server CPU; AVIF encode cost; storage growth - see [craft.md](craft.md) |
| Image CDN (Cloudflare Images, Imgix, Cloudinary, Bunny) | Format negotiation, global cache, no server CPU | Cost per transform/request; `Vary: Accept`; origin must stay cacheable |

## Gotchas

| Gotcha | Why | Fix |
|---|---|---|
| Hero lazy-loaded by a global image macro | The macro defaults `loading="lazy"` for every image | Make eager + `fetchpriority` a macro parameter; pass it for the first image |
| `sizes` missing with `w` descriptors | The default is `100vw` | Always write `sizes` |
| Width/height omitted "because it's responsive" | CLS on every image load | Emit intrinsic `width`/`height`; CSS `height: auto` keeps it fluid |
| Generated AVIF looks worse than WebP at "the same quality" | Quality scales differ per encoder | Tune quality per format, not one number for all |
| Transforms generated on first view, at peak traffic | First visitor per size waits; CPU spikes after a content import | Pre-generate on upload/save, or put an image CDN in front |
| Thumbnails served from the 4000px original via CSS scaling | Bytes don't shrink when CSS shrinks the box | Transform server-side to the rendered size |

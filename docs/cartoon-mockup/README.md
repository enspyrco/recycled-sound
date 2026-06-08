# Cartoon-style capture-illustration probe

**Status:** style review. One orientation only. Not yet wired into
`capture-protocols.html`.

## What's here

- [`bte-left.svg`](./bte-left.svg) — BTE (Behind-The-Ear) hearing aid,
  left side, dome pointing right, receiver wire coiled below.

Open `bte-left.svg` in a browser to view at full size.

## Style choices (Simpsons-style cartoon)

- **Flat fills** — single solid color per shape, no gradients, no
  shading, no rendered highlights. The beige BTE body uses one tone
  (`#F5C99B`), the battery door a second slightly-darker tone
  (`#E8A86F`), the dome a third soft tone (`#F0E6D2`).
- **Thick consistent black outlines** — 6px on major outer shapes,
  4px on secondary shapes (battery door, mic port), 3px on inner
  detail lines. The hierarchy reads at thumbnail size.
- **Simple shapes** — six recognizable parts, no more. Body, battery
  door, mic port, earhook, receiver wire, dome.
- **Comic-book label** — Impact font, all-caps, centered below the
  illustration. Names the device + orientation explicitly so the
  intake operator doesn't have to infer.

## Explicit non-styles (what this is NOT)

- Not a pencil sketch.
- Not a filtered photo (no kuwahara, no posterize).
- Not a technical line drawing.
- Not a vector-realism illustration with gradients and shadows.

## What to look at

1. **Does this read as "Simpsons-style" to you?** Bold flat color,
   thick outline, simple silhouette.
2. **Is the orientation legible?** Can you tell at a glance this is
   the LEFT side with the dome pointing RIGHT?
3. **Is the labeling load-bearing or noisy?** Happy to drop the text
   if the orientation reads from the silhouette alone.
4. **Do you want six of these** (one per orientation) before this
   gets wired into `capture-protocols.html`, or do you want a
   different style direction?

If the style lands, the plan is:
- Author the remaining five orientations as sibling SVGs in this
  directory.
- Open a follow-up PR that swaps them into `capture-protocols.html`
  next to (or replacing) the current photo references.

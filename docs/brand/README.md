# Ravnix Brand

The mark, the wordmark and the images that carry them. The rules behind the
colors and shapes are in the *Identity* section of [the style guide](../style.md).

## 🐦‍⬛ The story

In Norse myth, the god Odin keeps two ravens, Huginn and Muninn, thought and
memory. Every morning they fly out over the world, and every evening they come
back and tell him what they saw. Ravnix has two hosts named after them: the
laptop, `huginn`, where you think and look, and the server, `muninn`, which
remembers your sessions while the laptop sleeps. The tools ravnix writes for
itself are written in Odin, the programming language.

## 🪶 The mark

Two raven heads with long beaks, passing each other: Mauve for `huginn`, Blue
for `muninn`. The second head is the first turned by 180 degrees, because the
two hosts are one system seen from two sides. Straight edges, flat fills, round
eyes, nothing else, so it still reads at 16 pixels.

The name is drawn in the same facets: the r has the cut shoulder of the n, the
a's counter is a hole, and the dot on the i is a diamond. "rav" is Text and
"nix" is Mauve.

## 🗂️ Files

| File | Use |
| --- | --- |
| `logo.svg` | The mark in its two colors, for paper: the docs and the diagrams |
| `logo-mono.svg` | The mark in Text with the eyes cut out, for Base and Crust |
| `logo-16.png`, `logo-32.png` | The mark at icon sizes |
| `wordmark.svg` | The name on its own, for dark backgrounds |
| `lockup.svg` | Mark and name side by side, transparent, for dark backgrounds only |
| `header.svg` | The lockup on its own Base background, for the README and any light page |
| `social-preview.svg`, `.png` | The lockup and one line about ravnix, 1280 by 640, for links to the repository |
| `progress.svg` | The progress bar in the README |
| `screenshot-placeholder.svg` | Stands in for the screenshot until the first boot |

On a light background, use `header.svg`: "rav" is Text and disappears on
white, and Mauve on white is too faint to carry the name.

Keep a clear space of a quarter of the mark's width around it. Recolor it only
through the one-color version, and never redraw it by hand.

## 🔁 Rendering

The SVGs are the sources and are kept by hand. The PNGs are rendered with
ImageMagick through librsvg, with `-strip`, so the same input gives the same
bytes:

```sh
magick -background none RSVG:docs/brand/logo.svg -resize 16x16 -strip docs/brand/logo-16.png
magick -background none RSVG:docs/brand/logo.svg -resize 32x32 -strip docs/brand/logo-32.png
magick RSVG:docs/brand/social-preview.svg -strip docs/brand/social-preview.png
```

The social preview has live text in JetBrains Mono; render it where that font
is installed, or the line falls back to another monospace font. GitHub takes
the PNG only as an upload in the repository settings.

The progress bar shows the figure of the authors' own plan. It changes by hand
when that plan is recounted.

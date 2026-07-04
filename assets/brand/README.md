# Pixir Brand Assets

Pixir's mark is a rounded `P` shaped like a small BEAM supervision graph:
one spine, one supervisor node, and two child process nodes. The full lockup uses
the `P` as the first letter of `Pixir` and draws `ixir` as geometric vector
letterforms.

## Source Assets

- `pixir-icon.svg` - primary icon on light backgrounds.
- `pixir-logo.svg` - primary full lockup on light backgrounds.
- `pixir-logo-card.svg` - light-background README/Hex/GitHub card for unknown
  page themes.
- `pixir-icon-dark.svg` - icon for dark backgrounds.
- `pixir-logo-dark.svg` - full lockup for dark backgrounds.
- `pixir-icon-mono.svg` - monochrome icon using `currentColor`.
- `pixir-logo-mono.svg` - monochrome full lockup using `currentColor`.

Treat the SVGs as the source of truth. PNGs in `previews/` are generated previews
for quick inspection, not the editable source.

## Colors

| Token | Hex | Use |
| --- | --- | --- |
| Graphite | `#111827` | Primary structure on light backgrounds |
| Light | `#f8fafc` | Primary structure on dark backgrounds |
| Beam Cyan | `#14b8ff` | First child-process accent |
| Beam Emerald | `#10b981` | Second child-process accent |

## Usage

Use `pixir-icon.svg` for app icons, provider chips, favicons, and tiny UI
contexts. Use `pixir-logo.svg` for controlled light-background landing pages and
large documentation surfaces. Use `pixir-logo-card.svg` for README, Hex, GitHub,
and other surfaces where the page theme is outside Pixir's control.

Prefer the full-color assets when the background is controlled. Use monochrome
assets when the surrounding UI controls color through CSS.

## Notes

The letterforms are vector shapes rather than live text, so the logo does not
depend on installed fonts. If the geometry changes, regenerate previews and check
the mark at 32 px, 64 px, 256 px, and README scale.

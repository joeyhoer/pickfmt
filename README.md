# pickfmt

`pickfmt` recommends whether an image is better stored as PNG or JPEG, and can
optionally convert the image to the recommended format.

The script is designed for quick image optimization decisions:

- Images with actual transparency are kept as PNG.
- Images with low color counts, such as UI, icons, screenshots, and flat-color
  graphics, are kept as PNG.
- Other images are encoded both ways in a temporary workspace, then JPEG is
  chosen only when it is meaningfully smaller.

## Requirements

- ImageMagick, available as `magick`
- Optional: `jq` for `--json` output
- Optional: `cjpeg` for better JPEG output
- Optional: `pngquant` for better PNG output

## Usage

```sh
./pickfmt.sh [OPTIONS] IMAGE
```

## Options

| Option | Description |
| --- | --- |
| `-c`, `--convert` | Convert the image to the recommended format. |
| `-o`, `--output STEM` | Write converted output to `STEM` plus the chosen extension. Do not include an extension. |
| `-i`, `--in-place [SUFFIX]` | Replace the input image. With `SUFFIX` before `IMAGE`, keep the original as `NAME+SUFFIX+EXT`. |
| `-r`, `--reason` | Print recommendation reasoning to stderr. |
| `--json` | Print a structured JSON report to stdout. Requires `jq`. |
| `-q`, `--quality N` | JPEG quality from `1` to `100`. Default: `82`. |
| `--max-analysis-px N` | Resize the longest edge to at most `N` pixels before analysis. |
| `--png-colors N` | Prefer PNG at or below this unique color count. Default: `256`. |
| `--png-leniency N` | Prefer JPEG only if it is smaller than `PNG_SIZE * N`. Default: `0.90`. |
| `-v`, `--version` | Print the script version. |
| `-h`, `--help` | Show help. |

## Examples

Recommend a format:

```sh
./pickfmt.sh image.png
```

Show the reason for the recommendation:

```sh
./pickfmt.sh --reason image.png
```

Print a structured report:

```sh
./pickfmt.sh --json image.png
```

Convert next to the original:

```sh
./pickfmt.sh --convert image.png
```

Convert to a chosen output stem:

```sh
./pickfmt.sh --convert --output optimized/photo image.png
```

Replace the source image:

```sh
./pickfmt.sh --in-place image.png
```

Replace the source image and keep a backup:

```sh
./pickfmt.sh --in-place .bak image.png
```

## Output

Default recommendation mode prints only `png` or `jpg` to stdout. Conversion
mode prints only the output path to stdout.

`--reason` writes a short English explanation to stderr. Use `--json` when you
need parseable fields such as the decision code, dimensions, and test sizes.

When `--max-analysis-px` actually resizes the analysis image, `--reason` reports
that the recommendation came from a resized copy. `--json` includes the same
information under `analysis.scope`.

## Environment Defaults

These environment variables can be used instead of passing options every time:

| Variable | Default | Equivalent option |
| --- | --- | --- |
| `JPG_QUALITY` | `82` | `--quality` |
| `MAX_ANALYSIS_PX` | unset | `--max-analysis-px` |
| `PNG_COLOR_THRESHOLD` | `256` | `--png-colors` |
| `PNG_LENIENCY` | `0.90` | `--png-leniency` |

## Notes

`pickfmt` is most useful when starting from a lossless source image, such as
PNG, TIFF, or another high-quality original.

Converting from JPEG back to PNG is usually not an optimization. PNG may
preserve the already-lossy pixels, but it often creates a larger file without
improving quality.

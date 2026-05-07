#!/usr/bin/env bash
set -euo pipefail

prog="${0##*/}"
version="0.1.0"

# Analysis / encoding defaults.
max_analysis_px="${MAX_ANALYSIS_PX:-}"
jpg_quality="${JPG_QUALITY:-82}"
png_color_threshold="${PNG_COLOR_THRESHOLD:-256}"
png_leniency="${PNG_LENIENCY:-0.90}"

convert=0
reason=0
json_output=0
in_place=0
backup_suffix=""
output=""
file=""

recommendation=""
decision=""
analysis_scope="full"
analysis_source_width=""
analysis_source_height=""
analysis_width=""
analysis_height=""
analysis_colors=""
analysis_jpg_size=""
analysis_png_size=""

usage() {
  cat <<EOF
Usage:
  $prog [OPTIONS] IMAGE

Recommend or convert an image to the better of PNG or JPEG.

By default, prints only the recommended format:

  $prog image.png
  jpg

Options:
  -c, --convert          Convert IMAGE to the recommended format
  -o, --output STEM      Output path without extension; extension is chosen
                         automatically, e.g. -o out/photo -> out/photo.jpg
  -i, --in-place [SUFFIX]
                         Replace IMAGE in place. If SUFFIX is provided, keep
                         the original as NAME+SUFFIX+EXT, e.g. image.bak.png.
                         If the recommended format changes, output is renamed
                         with the new extension.
  -r, --reason           Print recommendation reasoning to stderr
  --json                 Print a structured JSON report to stdout; requires jq
  -q, --quality N        JPEG quality, default: $jpg_quality
  --max-analysis-px N    Resize the longest edge to at most N pixels before
                         analysis. By default, analyze the full image.
  --png-colors N         Prefer PNG at or below this color count, default: $png_color_threshold
  --png-leniency N       Prefer JPG only if smaller than PNG * N, default: $png_leniency
  -v, --version          Show version
  -h, --help             Show this help message

Examples:
  $prog image.png
  $prog --reason image.png
  $prog --json image.png
  $prog --convert image.png
  $prog --convert -o optimized image.png
  $prog --in-place image.png
  $prog --in-place .bak image.png

Notes:
  $prog is most useful when starting from a lossless source image, such as
  PNG, TIFF, or another high-quality original.

  Converting from a lossless format to JPEG can be a good optimization when
  the image is photographic and does not require transparency.

  Converting from JPEG back to PNG is usually not an optimization. JPEG is
  lossy: compression artifacts and discarded detail cannot be recovered by
  saving as PNG. PNG may preserve the already-lossy pixels, but often creates
  a larger file without improving quality.

  Images with actual transparency are recommended as PNG because JPEG does
  not support transparency without flattening.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

print_version() {
  printf '%s %s\n' "$prog" "$version"
}

log_reason() {
  if (( reason == 1 )); then
    echo "reason: $*" >&2
  fi
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

size_of() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

human_size() {
  local bytes="$1"

  awk -v bytes="$bytes" 'BEGIN {
    split("B KiB MiB GiB", units, " ")
    value = bytes + 0
    unit = 1

    while (value >= 1024 && unit < 4) {
      value /= 1024
      unit++
    }

    if (unit == 1) {
      printf "%d %s", value, units[unit]
    } else {
      printf "%.1f %s", value, units[unit]
    }
  }'
}

image_dimensions() {
  local input="$1"

  magick "$input" -auto-orient -format "%w %h" info:
}

make_temp_file() {
  local ext="$1"
  local tmp_base="${TMPDIR:-/tmp}"

  mktemp "${tmp_base%/}/pickfmt.$ext.XXXXXX"
}

make_temp_dir() {
  local tmp_base="${TMPDIR:-/tmp}"

  mktemp -d "${tmp_base%/}/pickfmt.XXXXXX"
}

path_in_dir() {
  local dir="$1"
  local name="$2"

  if [[ "$dir" == "." ]]; then
    printf '%s\n' "$name"
  elif [[ "$dir" == "/" ]]; then
    printf '/%s\n' "$name"
  else
    printf '%s/%s\n' "$dir" "$name"
  fi
}

require_uint() {
  local option="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "$option requires a number"
}

require_positive_uint() {
  local option="$1"
  local value="$2"

  require_uint "$option" "$value"
  (( 10#$value > 0 )) || die "$option must be greater than 0"
}

require_jpeg_quality() {
  local option="$1"
  local value="$2"
  local number

  require_uint "$option" "$value"
  number=$((10#$value))
  (( number >= 1 && number <= 100 )) || die "$option must be between 1 and 100"
}

require_positive_decimal() {
  local option="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$option requires a number"
  awk "BEGIN { exit !($value > 0) }" || die "$option must be greater than 0"
}

has_extension() {
  local path="$1"
  local base

  base="$(basename "$path")"
  [[ "$base" == *.* ]]
}

append_ext() {
  local path="$1"
  local ext="$2"

  printf '%s.%s\n' "$path" "$ext"
}

replace_ext() {
  local path="$1"
  local ext="$2"
  local dir base stem

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  stem="${base%.*}"

  if [[ "$base" == "$stem" ]]; then
    path_in_dir "$dir" "$base.$ext"
  else
    path_in_dir "$dir" "$stem.$ext"
  fi
}

with_suffix_before_ext() {
  local path="$1"
  local suffix="$2"
  local dir base stem ext

  dir="$(dirname "$path")"
  base="$(basename "$path")"

  if [[ "$base" == *.* ]]; then
    stem="${base%.*}"
    ext="${base##*.}"
    path_in_dir "$dir" "$stem$suffix.$ext"
  else
    path_in_dir "$dir" "$base$suffix"
  fi
}

# Create a normalized analysis image.
# By default this preserves full size; --max-analysis-px enables faster resized analysis.
make_analysis_image() {
  local input="$1"
  local output="$2"

  if [[ -n "$max_analysis_px" ]]; then
    magick "$input" \
      -auto-orient \
      -resize "${max_analysis_px}x${max_analysis_px}>" \
      PNG32:"$output"
  else
    magick "$input" \
      -auto-orient \
      PNG32:"$output"
  fi
}

record_analysis_scope() {
  local input="$1"
  local analysis_image="$2"
  local source_dimensions analysis_dimensions

  source_dimensions="$(image_dimensions "$input")"
  analysis_dimensions="$(image_dimensions "$analysis_image")"

  analysis_source_width="${source_dimensions%% *}"
  analysis_source_height="${source_dimensions##* }"
  analysis_width="${analysis_dimensions%% *}"
  analysis_height="${analysis_dimensions##* }"

  if [[ -n "$max_analysis_px" ]] &&
    [[ "$analysis_width" != "$analysis_source_width" ||
      "$analysis_height" != "$analysis_source_height" ]]; then
    analysis_scope="resized"
  else
    analysis_scope="full"
  fi

  if [[ "$analysis_scope" == "resized" ]]; then
    log_reason "analyzed a resized copy (${max_analysis_px} px max), so the recommendation may differ from full-size analysis"
  fi
}

set_recommendation() {
  recommendation="$1"
  decision="$2"
}

print_json_report() {
  local converted="$1"
  local output_path="$2"

  jq -n \
    --arg version "$version" \
    --arg input "$file" \
    --arg recommendation "$recommendation" \
    --arg decision "$decision" \
    --arg converted "$converted" \
    --arg output_path "$output_path" \
    --arg analysis_scope "$analysis_scope" \
    --arg max_analysis_px "$max_analysis_px" \
    --arg source_width "$analysis_source_width" \
    --arg source_height "$analysis_source_height" \
    --arg width "$analysis_width" \
    --arg height "$analysis_height" \
    --arg unique_colors "$analysis_colors" \
    --arg png_color_threshold "$png_color_threshold" \
    --arg jpg_size "$analysis_jpg_size" \
    --arg png_size "$analysis_png_size" \
    --arg png_leniency "$png_leniency" \
    '
    def number_or_null($value):
      if $value == "" then null else ($value | tonumber) end;

    {
      version: $version,
      input: $input,
      recommendation: $recommendation,
      decision: $decision,
      converted: ($converted == "true"),
      output: (if $output_path == "" then null else $output_path end),
      analysis: {
        scope: $analysis_scope,
        max_analysis_px: number_or_null($max_analysis_px),
        source_width: number_or_null($source_width),
        source_height: number_or_null($source_height),
        width: number_or_null($width),
        height: number_or_null($height),
        unique_colors: number_or_null($unique_colors),
        png_color_threshold: number_or_null($png_color_threshold),
        jpg_size: number_or_null($jpg_size),
        png_size: number_or_null($png_size),
        png_leniency: number_or_null($png_leniency)
      }
    }
    '
}

# Detect actual transparency, not merely the presence of an alpha channel.
has_actual_transparency() {
  local input="$1"
  local alpha_min

  alpha_min="$(magick "$input" -alpha extract -format "%[fx:minima]" info: 2>/dev/null || echo 1)"

  awk "BEGIN { exit !($alpha_min < 1) }"
}

# Lower color counts often indicate graphics, UI, icons, or screenshots.
unique_color_count() {
  local input="$1"
  magick "$input" -format "%k" info:
}

# Encode an optimized JPEG.
# Prefer mozjpeg/cjpeg when available.
jpeg_optimize() {
  local input="$1"
  local output="$2"

  if command -v cjpeg >/dev/null 2>&1; then
    magick "$input" \
      -auto-orient \
      -background white -alpha remove -alpha off \
      ppm:- |
      cjpeg \
        -quality "$jpg_quality" -optimize -progressive \
        > "$output"
  else
    magick "$input" \
      -auto-orient \
      -background white -alpha remove -alpha off \
      -quality "$jpg_quality" -interlace Plane \
      JPEG:"$output"
  fi
}

# Encode an optimized PNG.
# Prefer pngquant when available.
png_optimize() {
  local input="$1"
  local output="$2"

  if command -v pngquant >/dev/null 2>&1; then
    local tmp_png
    tmp_png="$(make_temp_file png)"

    magick "$input" \
      -auto-orient \
      PNG32:"$tmp_png"

    if ! pngquant \
      --speed 3 --quality 65-95 \
      --output "$output" --force \
      "$tmp_png" 2>/dev/null; then
      magick "$tmp_png" \
        PNG32:"$output"
    fi

    rm -f "$tmp_png"
  else
    magick "$input" \
      -auto-orient \
      PNG32:"$output"
  fi
}

# Recommend either PNG or JPEG:
# 1. Transparency -> PNG
# 2. Low color count -> PNG
# 3. Otherwise compare optimized JPEG vs PNG size
recommend_format() {
  local file="$1"
  local tmpdir analysis_image
  local jpg_test png_test color_phrase

  tmpdir="$(make_temp_dir)"

  analysis_image="$tmpdir/analysis.png"
  make_analysis_image "$file" "$analysis_image"
  record_analysis_scope "$file" "$analysis_image"

  if has_actual_transparency "$analysis_image"; then
    set_recommendation "png" "transparency"
    log_reason "PNG is recommended because the image has transparency, which JPEG cannot preserve"
    rm -rf "$tmpdir"
    return
  fi

  analysis_colors="$(unique_color_count "$analysis_image")"

  if (( analysis_colors <= png_color_threshold )); then
    set_recommendation "png" "low_color_count"
    if (( analysis_colors == 1 )); then
      color_phrase="1 unique color"
    else
      color_phrase="$analysis_colors unique colors"
    fi
    log_reason "PNG is recommended because the image has only $color_phrase, which usually favors lossless compression"
    rm -rf "$tmpdir"
    return
  fi

  jpg_test="$tmpdir/test.jpg"
  png_test="$tmpdir/test.png"

  jpeg_optimize "$analysis_image" "$jpg_test"
  png_optimize "$analysis_image" "$png_test"

  analysis_jpg_size="$(size_of "$jpg_test")"
  analysis_png_size="$(size_of "$png_test")"

  # Prefer JPEG only when meaningfully smaller.
  # Otherwise prefer PNG to preserve lossless quality.
  if awk "BEGIN { exit !($analysis_jpg_size < $analysis_png_size * $png_leniency) }"; then
    set_recommendation "jpg" "jpg_clearly_smaller"
    log_reason "JPEG is recommended because it is clearly smaller than PNG ($(human_size "$analysis_jpg_size") vs $(human_size "$analysis_png_size"))"
  elif (( analysis_png_size < analysis_jpg_size )); then
    set_recommendation "png" "png_clearly_smaller"
    log_reason "PNG is recommended because it is smaller than JPEG ($(human_size "$analysis_png_size") vs $(human_size "$analysis_jpg_size"))"
  else
    set_recommendation "png" "png_close_enough"
    log_reason "PNG is recommended because JPEG is not enough smaller to justify lossy conversion ($(human_size "$analysis_jpg_size") vs $(human_size "$analysis_png_size"))"
  fi

  rm -rf "$tmpdir"
}

destination_for() {
  local file="$1"
  local fmt="$2"

  if [[ -n "$output" ]]; then
    append_ext "$output" "$fmt"
  else
    replace_ext "$file" "$fmt"
  fi
}

convert_image() {
  local file="$1"
  local fmt="$2"
  local dest final tmp backup

  if (( in_place == 1 )) && [[ -n "$output" ]]; then
    die "--output cannot be used with --in-place"
  fi

  if (( in_place == 1 )); then
    final="$(replace_ext "$file" "$fmt")"

    if [[ "$final" != "$file" && -e "$final" ]]; then
      die "output already exists: $final"
    fi

    if [[ -n "$backup_suffix" ]]; then
      backup="$(with_suffix_before_ext "$file" "$backup_suffix")"
      [[ "$backup" != "$file" ]] || die "backup path would overwrite input"
      [[ "$backup" != "$final" ]] || die "backup path would overwrite output"
      [[ ! -e "$backup" ]] || die "backup already exists: $backup"
    fi

    tmp="$(make_temp_file "$fmt")"

    case "$fmt" in
      jpg) jpeg_optimize "$file" "$tmp" ;;
      png) png_optimize "$file" "$tmp" ;;
      *) die "unknown format: $fmt" ;;
    esac

    if [[ "$final" == "$file" ]]; then
      if [[ -n "$backup_suffix" ]]; then
        mv "$file" "$backup"
      fi
      mv -f "$tmp" "$final"
    else
      mv "$tmp" "$final"
      if [[ -n "$backup_suffix" ]]; then
        mv "$file" "$backup"
      else
        rm -f "$file"
      fi
    fi

    echo "$final"
    return
  fi

  dest="$(destination_for "$file" "$fmt")"

  if [[ "$dest" == "$file" ]]; then
    die "output would overwrite input; use --in-place or --output STEM"
  fi

  [[ ! -e "$dest" ]] || die "output already exists: $dest"

  case "$fmt" in
    jpg) jpeg_optimize "$file" "$dest" ;;
    png) png_optimize "$file" "$dest" ;;
    *) die "unknown format: $fmt" ;;
  esac

  echo "$dest"
}

parse_args() {
  while (($#)); do
    case "$1" in
      -c|--convert)
        convert=1
        shift
        ;;
      -o|--output)
        output="${2:-}"
        [[ -n "$output" ]] || die "--output requires a path stem"
        has_extension "$output" && die "--output should not include a file extension"
        shift 2
        ;;
      -i|--in-place)
        in_place=1
        convert=1

        # Optional backup suffix, like: -i .bak image.png.
        # If -i is followed by one remaining argument, that argument is IMAGE.
        if (( $# >= 3 )) && [[ "${2:-}" != -* ]]; then
          backup_suffix="$2"
          shift 2
        else
          shift
        fi
        ;;
      -r|--reason)
        reason=1
        shift
        ;;
      --json)
        json_output=1
        shift
        ;;
      -q|--quality)
        jpg_quality="${2:-}"
        require_jpeg_quality "--quality" "$jpg_quality"
        shift 2
        ;;
      --max-analysis-px)
        max_analysis_px="${2:-}"
        require_positive_uint "--max-analysis-px" "$max_analysis_px"
        shift 2
        ;;
      --png-colors)
        png_color_threshold="${2:-}"
        require_positive_uint "--png-colors" "$png_color_threshold"
        shift 2
        ;;
      --png-leniency)
        png_leniency="${2:-}"
        require_positive_decimal "--png-leniency" "$png_leniency"
        shift 2
        ;;
      -v|--version)
        print_version
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done

  file="${1:-}"

  [[ -n "$file" ]] || {
    usage >&2
    exit 2
  }

  [[ -f "$file" ]] || die "not a file: $file"

  if [[ -n "${2:-}" ]]; then
    die "unexpected extra argument: $2"
  fi

  if [[ -n "$output" && "$convert" -eq 0 ]]; then
    die "--output requires --convert"
  fi
}

main() {
  local converted_path

  parse_args "$@"
  need_command magick
  if (( json_output == 1 )); then
    need_command jq
  fi

  recommend_format "$file"

  if (( convert == 1 )); then
    converted_path="$(convert_image "$file" "$recommendation")"

    if (( json_output == 1 )); then
      print_json_report "true" "$converted_path"
    else
      echo "$converted_path"
    fi
  elif (( json_output == 1 )); then
    print_json_report "false" ""
  else
    echo "$recommendation"
  fi
}

main "$@"

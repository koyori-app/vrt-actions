#!/usr/bin/env bash
# Validate and enumerate the PNG screenshots under a directory.
#
# When sourced, defines `collect_pngs`. When executed directly, it runs against
# $DIR and prints one "<name>\t<path>" line per screenshot to stdout, where
# <name> is the path relative to $DIR with the .png extension removed
# (e.g. $DIR/mobile/home.png -> "mobile/home"). This makes the scan, the
# PNG-only / size / empty checks, and the name derivation testable in isolation.
set -euo pipefail

_COLLECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$_COLLECT_DIR/lib.sh"

# collect_pngs DIR
# Populates the arrays PNG_NAMES and PNG_PATHS (parallel). Dies on any
# non-PNG file, an empty directory, or a PNG exceeding the size limit. All
# checks run before returning so nothing is uploaded from an invalid set.
collect_pngs() {
  local dir="$1"
  dir="$(strip_trailing_slash "$dir")"

  [ -d "$dir" ] || die "screenshots directory '${dir}' does not exist."

  local f rel name size
  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$dir" -type f -print0)

  if [ "${#files[@]}" -eq 0 ]; then
    die "screenshots directory '${dir}' contains no .png files."
  fi

  # Deterministic upload order without GNU sort: BSD sort on macOS runners has
  # no -z, and a newline-delimited `find | sort` would corrupt paths containing
  # newlines. The set is small (screenshots), so an in-shell insertion sort is
  # fine; LC_ALL=C keeps the byte-wise order identical across runner locales.
  local LC_ALL=C
  local i j v
  for ((i = 1; i < ${#files[@]}; i++)); do
    v="${files[$i]}"
    for ((j = i - 1; j >= 0; j--)); do
      [[ "${files[$j]}" > "$v" ]] || break
      files[j + 1]="${files[$j]}"
    done
    files[j + 1]="$v"
  done

  # Mirror the VRT API's constraints (PNG signature + IHDR dimensions, trimmed
  # name of 1..MAX_NAME_BYTES bytes, unique names) before the build is created,
  # so a bad file cannot leave an unfinalized build behind after upload starts.
  PNG_NAMES=()
  PNG_PATHS=()
  local trimmed_names=()
  local dims width height trimmed name_bytes seen
  for f in "${files[@]}"; do
    case "$f" in
      *.png | *.PNG) ;;
      *) die "found non-PNG file '${f}' under '${dir}'. Only .png files may be uploaded in screenshots mode." ;;
    esac

    size="$(wc -c <"$f" | tr -d '[:space:]')"
    if [ "$size" -gt "$MAX_PNG_BYTES" ]; then
      die "screenshot '${f}' is ${size} bytes, exceeding the ${MAX_PNG_BYTES}-byte (25 MiB) per-file limit."
    fi

    if ! dims="$(png_dimensions "$f")"; then
      die "screenshot '${f}' is not a valid PNG (missing PNG signature or IHDR chunk)."
    fi
    width="${dims%% *}"
    height="${dims##* }"
    if [ "$width" -lt 1 ] || [ "$width" -gt "$MAX_PNG_DIMENSION" ] ||
      [ "$height" -lt 1 ] || [ "$height" -gt "$MAX_PNG_DIMENSION" ]; then
      die "screenshot '${f}' is ${width}x${height}px; width and height must be between 1 and ${MAX_PNG_DIMENSION}."
    fi

    rel="${f#"$dir"/}"
    name="${rel%.[pP][nN][gG]}"

    trimmed="$(trim_whitespace "$name")"
    if [ -z "$trimmed" ]; then
      die "screenshot '${f}' derives an empty name after trimming. Rename the file so the path relative to '${dir}' (without .png) is non-empty."
    fi
    name_bytes="$(printf '%s' "$trimmed" | wc -c | tr -d '[:space:]')"
    if [ "$name_bytes" -gt "$MAX_NAME_BYTES" ]; then
      die "screenshot name '${trimmed}' is ${name_bytes} bytes, exceeding the ${MAX_NAME_BYTES}-byte limit. Shorten the path relative to '${dir}'."
    fi
    # The API trims names and compares them within a build, so foo.png and
    # foo.PNG (or " foo .png") collide even though the paths differ.
    for seen in ${trimmed_names[@]+"${trimmed_names[@]}"}; do
      if [ "$seen" = "$trimmed" ]; then
        die "duplicate screenshot name '${trimmed}' (from '${f}'). Names must be unique within a build after trimming; note that foo.png and foo.PNG collide."
      fi
    done
    trimmed_names+=("$trimmed")

    PNG_NAMES+=("$name")
    PNG_PATHS+=("$f")
  done
}

# Direct execution: scan $DIR and print the derived names.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  collect_pngs "${DIR:?set DIR to the screenshots directory}"
  i=0
  while [ "$i" -lt "${#PNG_PATHS[@]}" ]; do
    printf '%s\t%s\n' "${PNG_NAMES[$i]}" "${PNG_PATHS[$i]}"
    i=$((i + 1))
  done
fi

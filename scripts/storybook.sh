#!/usr/bin/env bash
# storybook mode: delegate to the vrt CLI, downloaded from koyori-app/vrt.
# Sourced by main.sh; relies on resolved globals and lib.sh helpers.
set -euo pipefail

readonly VRT_REPO="koyori-app/vrt"

# resolve_cli_tag echoes the release tag to download. For "latest" it picks the
# first tag_name starting with "cli-v" from the releases list (authless).
resolve_cli_tag() {
  if [ "$CLI_VERSION" != "latest" ]; then
    printf '%s' "$CLI_VERSION"
    return 0
  fi
  local tag
  tag="$(curl -sSL "https://api.github.com/repos/${VRT_REPO}/releases" |
    jq -r 'map(select(.tag_name | startswith("cli-v"))) | .[0].tag_name // empty')"
  [ -n "$tag" ] || die "could not resolve the latest 'cli-v*' release tag from ${VRT_REPO}. Pin one with cli-version, e.g. cli-version: cli-v0.1.0."
  printf '%s' "$tag"
}

# detect_target echoes the release target triple for the current runner.
detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}/${arch}" in
    Linux/x86_64) echo "x86_64-unknown-linux-gnu" ;;
    Linux/aarch64 | Linux/arm64) echo "aarch64-unknown-linux-gnu" ;;
    Darwin/x86_64) echo "x86_64-apple-darwin" ;;
    Darwin/arm64) echo "aarch64-apple-darwin" ;;
    *) die "unsupported runner OS/architecture '${os}/${arch}' for the vrt CLI. Use a linux/macos x86_64 or arm64 runner." ;;
  esac
}

# sha256_of FILE echoes the file's SHA-256 hex digest, portably.
sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

# download_cli echoes the path to a verified, executable vrt binary.
download_cli() {
  local tag target base asset dir
  tag="$(resolve_cli_tag)"
  target="$(detect_target)"
  base="https://github.com/${VRT_REPO}/releases/download/${tag}"
  asset="vrt-${target}.tar.gz"
  dir="$(mktemp -d)"

  log "Downloading vrt CLI ${tag} (${target})..."
  curl -sSL --fail -o "${dir}/${asset}" "${base}/${asset}" ||
    die "failed to download ${base}/${asset}. Check that release '${tag}' publishes ${asset}."
  curl -sSL --fail -o "${dir}/${asset}.sha256" "${base}/${asset}.sha256" ||
    die "failed to download the checksum ${base}/${asset}.sha256."

  local expected actual
  expected="$(awk '{print $1}' "${dir}/${asset}.sha256")"
  actual="$(sha256_of "${dir}/${asset}")"
  [ -n "$expected" ] || die "checksum file ${asset}.sha256 was empty."
  if [ "$expected" != "$actual" ]; then
    die "checksum mismatch for ${asset}: expected ${expected}, got ${actual}."
  fi
  log "Checksum verified for ${asset}."

  tar -xzf "${dir}/${asset}" -C "$dir"
  [ -f "${dir}/vrt" ] || die "extracted archive ${asset} does not contain a 'vrt' binary."
  chmod +x "${dir}/vrt"
  printf '%s' "${dir}/vrt"
}

run_storybook() {
  # 1: the Storybook build must exist and carry an index.json.
  [ -d "$DIR" ] || die "storybook directory '${DIR}' does not exist."
  [ -f "$DIR/index.json" ] || die "storybook directory '${DIR}' has no index.json. Point 'dir' at a built Storybook (storybook-static)."

  # 2: fetch and verify the CLI.
  local vrt
  vrt="$(download_cli)"

  # 3: build the argument list.
  local args=(upload --dir "$DIR" --branch "$BRANCH" --commit "$COMMIT" --json)
  if [ "$ONLY_CHANGED" = "true" ]; then
    args+=(--only-changed)
    if [ -n "$STATS_JSON" ]; then
      args+=(--stats-json "$STATS_JSON")
    fi
  fi
  if [ "$WAIT" = "true" ]; then
    args+=(--wait)
  fi

  # 4: run the CLI. stdout carries a single JSON line; logs go to stderr.
  log "Running: vrt ${args[*]}"
  local out cli_exit
  set +e
  out="$(VRT_URL="$URL" VRT_TOKEN="$TOKEN" VRT_PROJECT="${TENANT}/${PROJECT_SLUG}" "$vrt" "${args[@]}")"
  cli_exit=$?
  set -e

  # Parse the last stdout line as JSON, in case anything else leaked to stdout.
  local json
  json="$(printf '%s\n' "$out" | grep -E '^\s*\{' | tail -n 1)"
  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    die "vrt CLI did not emit a JSON result on stdout (exit ${cli_exit}). storybook mode needs cli-v0.1.0 or newer (the --json flag). Raw stdout: ${out}"
  fi

  BUILD_ID="$(printf '%s' "$json" | jq -r '.build_id')"
  BUILD_NUMBER="$(printf '%s' "$json" | jq -r '.build_number')"
  TENANT="$(printf '%s' "$json" | jq -r '.tenant_slug // empty')"
  PROJECT_SLUG="$(printf '%s' "$json" | jq -r '.project_slug // empty')"
  RESULT="$(printf '%s' "$json" | jq -r '.status')"
  local cli_json_exit
  cli_json_exit="$(printf '%s' "$json" | jq -r '.exit_code // empty')"

  [ -n "$BUILD_ID" ] && [ "$BUILD_ID" != "null" ] || die "vrt CLI JSON missing build_id: ${json}"
  compute_build_url

  if [ "$WAIT" = "true" ]; then
    # Trust the CLI's own result code (mirrors the documented mapping).
    if [ -n "$cli_json_exit" ]; then
      CODE="$cli_json_exit"
    else
      CODE="$(status_to_exit_code "$RESULT")"
    fi
  else
    CODE=0
  fi
}

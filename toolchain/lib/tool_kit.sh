#!/usr/bin/env bash
# =============================================================================
# tool_kit.sh — slim helpers for optional-library installs (VASP Windows)
#
# Adapted from ABACUS toolchain/scripts/tool_kit.sh
# (ABACUS Development Team). Kept functions: report_*, get_nprocs / jobs,
# remove_path, prepend_path, checksum, download_pkg_from_url, retrieve_package.
#
# Download policy (enforced here): download → SHA256 vs pin → only then unpack.
# Never blind-extract. Prefer extract_verified_archive / verify_before_extract.
# =============================================================================
# shellcheck disable=SC2086,SC2155,SC2164

SCRIPT_NAME="${SCRIPT_NAME:-tool_kit.sh}"
time_start=$(date +%s)

# ----------------------------------------------------------------------------
# Timing / reporting
# ----------------------------------------------------------------------------

report_timing() {
  time_stop=$(date +%s)
  printf "Step %s took %0.2f seconds.\n" "$1" $((time_stop - time_start))
}

report_warning() {
  if [ $# -gt 1 ]; then
    local __lineno=", line $1"
    local __message="$2"
  else
    local __lineno=''
    local __message="$1"
  fi
  echo "WARNING: (${SCRIPT_NAME}${__lineno}) $__message" >&2
}

report_error() {
  if [ $# -gt 1 ]; then
    local __lineno=", line $1"
    local __message="$2"
  else
    local __lineno=''
    local __message="$1"
  fi
  echo "ERROR: (${SCRIPT_NAME}${__lineno}) $__message" >&2
}

# ----------------------------------------------------------------------------
# Parallel jobs helper
# ----------------------------------------------------------------------------

get_nprocs() {
  if [ -n "${NPROCS_OVERWRITE:-}" ]; then
    echo "${NPROCS_OVERWRITE}" | sed 's/^0*//'
  elif command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    echo 1
  fi
}

# Alias used by install scripts; honour NUM_CORES / toolchain jobs env.
toolchain_jobs() {
  if [ -n "${NUM_CORES:-}" ]; then
    echo "${NUM_CORES}"
  elif [ -n "${TOOLCHAIN_JOBS:-}" ]; then
    echo "${TOOLCHAIN_JOBS}"
  else
    local n
    n=$(get_nprocs)
    # Cap to reduce OOM on Windows/MSYS2 hosts
    if [ "${n}" -gt 8 ] 2>/dev/null; then
      echo 8
    else
      echo "${n}"
    fi
  fi
}

# ----------------------------------------------------------------------------
# PATH helpers
# ----------------------------------------------------------------------------

remove_path() {
  local __path_name=$1
  local __directory=$2
  local __path
  eval "__path=\${${__path_name}:-}"
  __path=${__path//:$__directory:/:}
  __path=${__path#$__directory:}
  __path=${__path%:$__directory}
  __path=$(echo "$__path" | sed "s#^$__directory\$##g")
  eval "${__path_name}=\"${__path}\""
  eval "export ${__path_name}"
}

prepend_path() {
  # $1 = path variable name; $2 = directory
  remove_path "$1" "$2"
  eval "$1=\"$2\${$1:+\":\$$1\"}\""
  eval "export $1"
}

# ----------------------------------------------------------------------------
# Download + checksum lock (SHA256 required before any unpack)
# ----------------------------------------------------------------------------

# Reject empty / non-hex pins so we never "succeed" without a real digest.
require_sha256_pin() {
  local __sha256="$1"
  local __label="${2:-archive}"
  if [ -z "${__sha256}" ]; then
    report_error "empty SHA256 pin for ${__label}; refuse to proceed"
    return 1
  fi
  if [ "${#__sha256}" -ne 64 ]; then
    report_error "SHA256 pin for ${__label} must be 64 hex chars (got ${#__sha256})"
    return 1
  fi
  case "${__sha256}" in
    *[!0-9a-fA-F]*)
      report_error "SHA256 pin for ${__label} contains non-hex characters"
      return 1
      ;;
  esac
  return 0
}

checksum() {
  local __filename=$1
  local __sha256=$2
  local __shasum_command='sha256sum'
  require_sha256_pin "${__sha256}" "${__filename}" || return 1
  command -v "$__shasum_command" >/dev/null 2>&1 ||
    __shasum_command="shasum -a 256"
  # Quiet check; callers print a short OK / error line.
  echo "$__sha256  $__filename" | ${__shasum_command} --check --status
}

# verify_before_extract: mandatory gate — re-check pin, delete bad file on mismatch.
# usage: verify_before_extract sha256 filename
verify_before_extract() {
  local __sha256="$1"
  local __filename="$2"
  require_sha256_pin "${__sha256}" "${__filename}" || return 1
  if [ ! -f "${__filename}" ]; then
    report_error "archive missing (cannot extract): ${__filename}"
    return 1
  fi
  if [ ! -s "${__filename}" ]; then
    rm -vf "${__filename}"
    report_error "archive is empty (0 bytes); deleted ${__filename}"
    return 1
  fi
  if checksum "${__filename}" "${__sha256}"; then
    echo "Checksum of ${__filename} OK (verified before extract)"
    return 0
  fi
  rm -vf "${__filename}"
  report_error "Checksum of ${__filename} mismatch vs pin; removed bad file, abort."
  return 1
}

download_pkg_from_url() {
  # usage: download_pkg_from_url sha256 filename url
  local __sha256="$1"
  local __filename="$2"
  local __url="$3"
  local DOWNLOADER_FLAGS="--quiet --show-progress"

  require_sha256_pin "${__sha256}" "${__filename}" || return 1

  if command -v wget >/dev/null 2>&1; then
    if ! wget ${DOWNLOADER_FLAGS} "$__url" -O "$__filename"; then
      rm -f "$__filename"
      if ! wget ${DOWNLOADER_FLAGS} --no-check-certificate "$__url" -O "$__filename"; then
        rm -f "$__filename"
        report_error "failed to download $__url"
        return 1
      fi
    fi
  elif command -v curl >/dev/null 2>&1; then
    if ! curl -fL --progress-bar "$__url" -o "$__filename"; then
      rm -f "$__filename"
      report_error "failed to download $__url"
      return 1
    fi
  else
    report_error "neither wget nor curl found"
    return 1
  fi

  if checksum "$__filename" "$__sha256"; then
    echo "Checksum of $__filename OK"
  else
    rm -vf "${__filename}"
    report_error "Checksum of $__filename could not be verified, abort."
    return 1
  fi
}

# retrieve_package: reuse cached tarball if checksum matches, else re-download.
# Always ends with a verified on-disk archive (or non-zero exit).
retrieve_package() {
  local __sha256="$1"
  local __filename="$2"
  local __url="$3"

  require_sha256_pin "${__sha256}" "${__filename}" || return 1

  if ! [ -f "${__filename}" ]; then
    download_pkg_from_url "${__sha256}" "${__filename}" "${__url}" || return 1
  else
    if ! checksum "$__filename" "$__sha256"; then
      echo "$__filename is found but checksum is wrong; delete and re-download"
      rm -vf "${__filename}"
      download_pkg_from_url "${__sha256}" "${__filename}" "${__url}" || return 1
    else
      echo "$__filename is found and checksum is right"
    fi
  fi

  # Final gate: never return success with an unverified on-disk archive.
  if ! checksum "${__filename}" "${__sha256}"; then
    rm -vf "${__filename}"
    report_error "Checksum of ${__filename} failed final verify; removed bad file, abort."
    return 1
  fi
  return 0
}

# extract_verified_archive: re-verify SHA256, then tar/unzip. Never blind extract.
# usage: extract_verified_archive sha256 filename [extra tar/unzip args...]
# Example: extract_verified_archive "$sha" "$pkg" -C "$outdir"
extract_verified_archive() {
  local __sha256="$1"
  local __filename="$2"
  shift 2

  verify_before_extract "${__sha256}" "${__filename}" || return 1

  case "${__filename}" in
    *.tar.gz | *.tgz)
      tar -xzf "${__filename}" "$@"
      ;;
    *.tar.bz2)
      tar -xjf "${__filename}" "$@"
      ;;
    *.tar.xz)
      tar -xJf "${__filename}" "$@"
      ;;
    *.tar)
      tar -xf "${__filename}" "$@"
      ;;
    *.zip)
      unzip -q "${__filename}" "$@"
      ;;
    *)
      report_error "unsupported archive format (refusing blind extract): ${__filename}"
      return 1
      ;;
  esac
}

#!/usr/bin/env bash
# =============================================================================
# inject_vtst.sh ? optional VTST (+ PyAMFF) inject into a VASP source tree
#
# When VASP_VTST=ON, overlay user-supplied vtstcode into ${SRC_ROOT}/src,
# copy pyamff_fortran/ + CMake overlay, patch main.F (TSIF + unconditional
# chain_init), insert core objects (incl. ml_pyamff.o) before chain.o in
# .objects, and hook staged cmake/CMakeLists/CMakeLists_src.txt to build and
# link pyamff_fortran. Does not modify makefile.
#
# Env:
#   VASP_VTST      ON to inject; anything else ? no-op exit 0 (default OFF)
#   SRC_ROOT       VASP tree root (must contain src/main.F, src/.objects)
#   VTST_CODE_DIR  unpacked vtstcode dir containing chain.F
#   CMAKE_OVERLAY_DIR  optional; default ${REPO_ROOT}/cmake_overlays
#
# Usage (MSYS2 UCRT64; independent of build_pipeline):
#   VASP_VTST=ON SRC_ROOT=/path/to/vasp.6.6.0 \
#     VTST_CODE_DIR=/path/to/vtstcode6.6.0 \
#     bash toolchain/scripts/inject_vtst.sh
# =============================================================================
set -euo pipefail

log() { printf '\033[1;34m[vtst]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[vtst]\033[0m %s\n' "$*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CMAKE_OVERLAY_DIR="${CMAKE_OVERLAY_DIR:-${REPO_ROOT}/cmake_overlays}"
PYAMFF_CMAKE_SRC="${CMAKE_OVERLAY_DIR}/CMakeLists_pyamff_fortran.txt"

# Official core object list (incl. ml_pyamff) ? inserted before chain.o
# Do NOT put pyamff_fortran/*.o here; CMake builds that as a separate lib.
# shellcheck disable=SC2016
VTST_CORE_OBJECTS_LINE1='bfgs.o dynmat.o instanton.o lbfgs.o sd.o cg.o dimer.o bbm.o \'
VTST_CORE_OBJECTS_LINE2='fire.o lanczos.o neb.o qm.o ml_pyamff.o opt.o \'
VTST_OBJECTS_MARKER='# --- VTST_INJECT (inject_vtst.sh) ---'
VTST_PYAMFF_CMAKE_MARKER='# --- VTST_PYAMFF (inject_vtst.sh) ---'

VASP_VTST="${VASP_VTST:-OFF}"

if [ "${VASP_VTST}" != "ON" ]; then
  log "VASP_VTST=${VASP_VTST} ? skip inject"
  exit 0
fi

[ -n "${SRC_ROOT:-}" ] || die "SRC_ROOT is required when VASP_VTST=ON"
[ -n "${VTST_CODE_DIR:-}" ] || die "VTST_CODE_DIR is required when VASP_VTST=ON"

SRC_ROOT="$(cd "${SRC_ROOT}" && pwd)" || die "SRC_ROOT not found: ${SRC_ROOT}"
VTST_CODE_DIR="$(cd "${VTST_CODE_DIR}" && pwd)" || die "VTST_CODE_DIR not found: ${VTST_CODE_DIR}"

SRC_DIR="${SRC_ROOT}/src"
MAIN_F="${SRC_DIR}/main.F"
OBJECTS_F="${SRC_DIR}/.objects"
CHAIN_F="${SRC_DIR}/chain.F"
CHAIN_BAK="${SRC_DIR}/chain.F.pre_vtst"
CMAKE_SRC_LISTS="${SRC_ROOT}/cmake/CMakeLists/CMakeLists_src.txt"

[ -d "${SRC_DIR}" ] || die "missing ${SRC_DIR}"
[ -f "${MAIN_F}" ] || die "missing ${MAIN_F}"
[ -f "${OBJECTS_F}" ] || die "missing ${OBJECTS_F}"
[ -f "${CHAIN_F}" ] || die "missing stock ${CHAIN_F} (unpack VASP first)"
[ -f "${PYAMFF_CMAKE_SRC}" ] || die "missing PyAMFF CMake overlay: ${PYAMFF_CMAKE_SRC}"

# Resolve vtstcode root: accept the dir itself or a nested vtstcode6.6.0/
VTST_SRC="${VTST_CODE_DIR}"
if [ ! -f "${VTST_SRC}/chain.F" ]; then
  if [ -f "${VTST_CODE_DIR}/vtstcode6.6.0/chain.F" ]; then
    VTST_SRC="${VTST_CODE_DIR}/vtstcode6.6.0"
  else
    die "no chain.F under ${VTST_CODE_DIR} (expected vtstcode tree)"
  fi
fi

log "VASP_VTST=ON"
log "SRC_ROOT=${SRC_ROOT}"
log "VTST_SRC=${VTST_SRC}"
log "REPO_ROOT=${REPO_ROOT}"

# -----------------------------------------------------------------------------
# 1) Backup stock chain.F once
# -----------------------------------------------------------------------------
if [ ! -f "${CHAIN_BAK}" ]; then
  cp -f "${CHAIN_F}" "${CHAIN_BAK}"
  log "backed up chain.F -> chain.F.pre_vtst"
else
  log "chain.F.pre_vtst already present ? keep"
fi

# -----------------------------------------------------------------------------
# 2) Overlay ALL core *.F (including ml_pyamff.F)
# -----------------------------------------------------------------------------
copied=0
shopt -s nullglob
for f in "${VTST_SRC}"/*.F; do
  base="$(basename "${f}")"
  cp -f "${f}" "${SRC_DIR}/${base}"
  copied=$((copied + 1))
done
shopt -u nullglob

[ "${copied}" -gt 0 ] || die "no core *.F copied from ${VTST_SRC}"
[ -f "${SRC_DIR}/chain.F" ] || die "chain.F missing after overlay"
[ -f "${SRC_DIR}/ml_pyamff.F" ] || die "ml_pyamff.F missing after overlay (required for VTST 6.6.0)"
log "copied ${copied} *.F into src/ (including ml_pyamff.F)"

# -----------------------------------------------------------------------------
# 2b) Copy pyamff_fortran/ + install CMakeLists overlay
# -----------------------------------------------------------------------------
if [ ! -d "${VTST_SRC}/pyamff_fortran" ]; then
  die "missing ${VTST_SRC}/pyamff_fortran (required for VTST 6.6.0 / ML_PyAMFF)"
fi

PYAMFF_DST="${SRC_DIR}/pyamff_fortran"
rm -rf "${PYAMFF_DST}"
if command -v rsync >/dev/null 2>&1; then
  rsync -a "${VTST_SRC}/pyamff_fortran/" "${PYAMFF_DST}/"
else
  mkdir -p "${PYAMFF_DST}"
  cp -a "${VTST_SRC}/pyamff_fortran/." "${PYAMFF_DST}/"
fi
cp -f "${PYAMFF_CMAKE_SRC}" "${PYAMFF_DST}/CMakeLists.txt"
[ -f "${PYAMFF_DST}/CMakeLists.txt" ] || die "failed to install pyamff_fortran/CMakeLists.txt"
log "copied pyamff_fortran/ + CMakeLists overlay"

# -----------------------------------------------------------------------------
# 3) Idempotent main.F: TSIF arg + unconditional chain_init
# -----------------------------------------------------------------------------
patch_main_f() {
  local tmp
  tmp="$(mktemp)"
  # TSIF: insert before LATT_CUR%A inside the CHAIN_FORCE continuation, once.
  # chain_init: drop IF (LCHAIN) guard (official VTST install for VASP >= 6.2).
  awk '
    BEGIN { in_cf = 0; has_tsif = 0; did_tsif = 0 }
    /CALL[[:space:]]+CHAIN_FORCE/ { in_cf = 1; has_tsif = 0 }
    in_cf && /TSIF/ { has_tsif = 1 }
    in_cf && /LATT_CUR%A/ && !has_tsif && !did_tsif {
      sub(/LATT_CUR%A/, "TSIF,LATT_CUR%A")
      did_tsif = 1
      has_tsif = 1
    }
    in_cf && /IO%IU6/ { in_cf = 0 }
    {
      line = $0
      if (match(line, /IF[[:space:]]*\([[:space:]]*LCHAIN[[:space:]]*\)[[:space:]]*CALL[[:space:]]+chain_init/)) {
        sub(/IF[[:space:]]*\([[:space:]]*LCHAIN[[:space:]]*\)[[:space:]]*CALL[[:space:]]+chain_init/,
            "CALL chain_init", line)
      }
      print line
    }
  ' "${MAIN_F}" > "${tmp}"
  mv -f "${tmp}" "${MAIN_F}"
}

# TSIF may sit several continuation lines after CALL CHAIN_FORCE ? scan the call.
main_f_chain_force_has_tsif() {
  awk '
    BEGIN { in_cf = 0; found = 0 }
    /CALL[[:space:]]+CHAIN_FORCE/ { in_cf = 1 }
    in_cf && /TSIF/ { found = 1; exit }
    in_cf && /IO%IU6/ { in_cf = 0 }
    END { exit !found }
  ' "${MAIN_F}"
}

# Detect prior inject (idempotent skip of rewrites is still safe; log status)
if main_f_chain_force_has_tsif; then
  log "main.F: CHAIN_FORCE already has TSIF"
else
  log "main.F: inserting TSIF into CHAIN_FORCE"
fi
if grep -qE 'IF[[:space:]]*\([[:space:]]*LCHAIN[[:space:]]*\)[[:space:]]*CALL[[:space:]]+chain_init' "${MAIN_F}"; then
  log "main.F: making chain_init unconditional"
else
  log "main.F: chain_init already unconditional (or pattern absent)"
fi

patch_main_f

# Verify expected hooks after patch
if ! main_f_chain_force_has_tsif; then
  die "main.F: failed to ensure TSIF in CHAIN_FORCE call"
fi
if grep -qE 'IF[[:space:]]*\([[:space:]]*LCHAIN[[:space:]]*\)[[:space:]]*CALL[[:space:]]+chain_init' "${MAIN_F}"; then
  die "main.F: still has IF (LCHAIN) CALL chain_init"
fi
if ! grep -qE 'CALL[[:space:]]+chain_init' "${MAIN_F}"; then
  die "main.F: CALL chain_init not found after patch"
fi
log "main.F: OK (TSIF + unconditional chain_init)"

# -----------------------------------------------------------------------------
# 4) Idempotent .objects: insert/upgrade core list before chain.o
# -----------------------------------------------------------------------------
# Replace an existing VTST block when ml_pyamff.o is missing (failed v1 trees).
replace_vtst_objects_block() {
  local tmp
  tmp="$(mktemp)"
  awk -v marker="${VTST_OBJECTS_MARKER}" \
      -v l1="${VTST_CORE_OBJECTS_LINE1}" \
      -v l2="${VTST_CORE_OBJECTS_LINE2}" '
    BEGIN { skip = 0; replaced = 0 }
    $0 == marker {
      print marker
      # Preserve indentation of the next non-empty line if present later;
      # use two-space indent matching typical .objects style.
      indent = "  "
      print indent l1
      print indent l2
      skip = 1
      replaced = 1
      next
    }
    skip {
      # Skip old VTST object continuation lines until chain.o
      if ($0 ~ /(^|[[:space:]\\])chain\.o([[:space:]\\]|$)/) {
        skip = 0
        print
      }
      next
    }
    { print }
    END {
      if (!replaced) exit 2
    }
  ' "${OBJECTS_F}" > "${tmp}" || {
    rm -f "${tmp}"
    die ".objects: failed to replace VTST block with ml_pyamff.o"
  }
  mv -f "${tmp}" "${OBJECTS_F}"
  log ".objects: upgraded VTST block (added ml_pyamff.o before opt.o)"
}

insert_vtst_objects_block() {
  local tmp
  tmp="$(mktemp)"
  awk -v marker="${VTST_OBJECTS_MARKER}" \
      -v l1="${VTST_CORE_OBJECTS_LINE1}" \
      -v l2="${VTST_CORE_OBJECTS_LINE2}" '
    BEGIN { inserted = 0 }
    !inserted && $0 ~ /(^|[[:space:]\\])chain\.o([[:space:]\\]|$)/ {
      indent = ""
      if (match($0, /^[[:space:]]+/)) indent = substr($0, RSTART, RLENGTH)
      print marker
      print indent l1
      print indent l2
      inserted = 1
    }
    { print }
    END {
      if (!inserted) exit 2
    }
  ' "${OBJECTS_F}" > "${tmp}" || {
    rm -f "${tmp}"
    die ".objects: failed to insert VTST objects before chain.o"
  }
  mv -f "${tmp}" "${OBJECTS_F}"
  log ".objects: inserted VTST core objects (incl. ml_pyamff.o) before chain.o"
}

patch_objects() {
  if grep -qF "${VTST_OBJECTS_MARKER}" "${OBJECTS_F}"; then
    if grep -q 'ml_pyamff\.o' "${OBJECTS_F}"; then
      log ".objects: VTST marker + ml_pyamff.o present ? keep"
      return 0
    fi
    log ".objects: VTST marker present but ml_pyamff.o missing ? upgrade"
    replace_vtst_objects_block
    return 0
  fi

  # Legacy inject without marker: bfgs/opt present but no ml_pyamff
  if grep -q 'bfgs\.o' "${OBJECTS_F}" && grep -q 'opt\.o' "${OBJECTS_F}"; then
    if grep -q 'ml_pyamff\.o' "${OBJECTS_F}"; then
      log ".objects: bfgs.o/opt.o/ml_pyamff.o already listed ? keep"
      return 0
    fi
    # Insert marker+full list before first opt.o line is fragile; die and ask
    # for a clean tree, or replace the opt.o-containing VTST-ish lines.
    # Prefer inserting ml_pyamff.o immediately before opt.o once.
    local tmp
    tmp="$(mktemp)"
    awk '
      BEGIN { done = 0 }
      !done && /(^|[[:space:]\\])opt\.o([[:space:]\\]|$)/ {
        line = $0
        sub(/opt\.o/, "ml_pyamff.o opt.o", line)
        print line
        done = 1
        next
      }
      { print }
      END { if (!done) exit 2 }
    ' "${OBJECTS_F}" > "${tmp}" || {
      rm -f "${tmp}"
      die ".objects: failed to insert ml_pyamff.o before opt.o"
    }
    mv -f "${tmp}" "${OBJECTS_F}"
    log ".objects: inserted ml_pyamff.o before existing opt.o (legacy upgrade)"
    return 0
  fi

  if ! grep -q 'chain\.o' "${OBJECTS_F}"; then
    die ".objects: chain.o not found (cannot insert VTST objects)"
  fi

  insert_vtst_objects_block
}

patch_objects

# Sanity: core objects appear before chain.o, and ml_pyamff.o is present
if ! grep -q 'ml_pyamff\.o' "${OBJECTS_F}"; then
  die ".objects: ml_pyamff.o missing after patch"
fi
if ! awk '
  /bfgs\.o/ { bfgs = NR }
  /ml_pyamff\.o/ { ml = NR }
  /opt\.o/ { opt = NR }
  /(^|[[:space:]\\])chain\.o([[:space:]\\]|$)/ { chain = NR }
  END { exit !(bfgs && ml && opt && chain && bfgs < chain && ml < chain && opt < chain && ml <= opt) }
' "${OBJECTS_F}"; then
  die ".objects: VTST objects (incl. ml_pyamff.o) must appear before chain.o"
fi
log ".objects: OK (ml_pyamff.o before opt.o / chain.o)"

# -----------------------------------------------------------------------------
# 5) Idempotent staged CMakeLists_src.txt: add_subdirectory + link + mod -I
# -----------------------------------------------------------------------------
# True when existing VTST_PYAMFF hooks already have link + module include + deps.
cmake_pyamff_hooks_complete() {
  grep -qF "${VTST_PYAMFF_CMAKE_MARKER}" "${CMAKE_SRC_LISTS}" \
    && grep -q 'add_subdirectory(pyamff_fortran)' "${CMAKE_SRC_LISTS}" \
    && grep -q 'PRIVATE pyamff_fortran' "${CMAKE_SRC_LISTS}" \
    && grep -q 'Fortran_MODULE_DIRECTORY' "${CMAKE_SRC_LISTS}" \
    && grep -q 'add_dependencies([^)]*pyamff_fortran)' "${CMAKE_SRC_LISTS}"
}

# Strip every VTST_PYAMFF marker block (subdir and/or link) so we can re-insert.
# Bounded: only consume the marked if()/endif() (or a marker stub until blank /
# next marker). Never swallow past into an unrelated endif.
strip_cmake_pyamff_blocks() {
  local tmp
  tmp="$(mktemp)"
  awk -v marker="${VTST_PYAMFF_CMAKE_MARKER}" '
    BEGIN { skip = 0; depth = 0; saw_if = 0; skip_blank = 0 }
    skip_blank {
      skip_blank = 0
      if ($0 ~ /^[[:space:]]*$/) next
      # fall through to print non-blank
    }
    $0 == marker {
      skip = 1
      depth = 0
      saw_if = 0
      next
    }
    skip {
      # Another marker ends the previous stub and starts a new strip region
      if ($0 == marker) {
        depth = 0
        saw_if = 0
        next
      }
      if ($0 ~ /^[[:space:]]*if[[:space:]]*\(/) {
        depth++
        saw_if = 1
        next
      }
      if (saw_if && ($0 ~ /^[[:space:]]*endif[[:space:]]*\(/ || $0 ~ /^[[:space:]]*endif[[:space:]]*$/)) {
        depth--
        if (depth <= 0) {
          skip = 0
          depth = 0
          saw_if = 0
          skip_blank = 1
        }
        next
      }
      # Marker-only / incomplete stub: stop at blank line (do not hunt endif)
      if (!saw_if && $0 ~ /^[[:space:]]*$/) {
        skip = 0
        next
      }
      # Unrelated endif before any if in this block ? stop and keep the line
      if (!saw_if && ($0 ~ /^[[:space:]]*endif[[:space:]]*\(/ || $0 ~ /^[[:space:]]*endif[[:space:]]*$/)) {
        skip = 0
        print
        next
      }
      next
    }
    { print }
  ' "${CMAKE_SRC_LISTS}" > "${tmp}"
  mv -f "${tmp}" "${CMAKE_SRC_LISTS}"
}

insert_cmake_pyamff_hooks() {
  local tmp
  tmp="$(mktemp)"
  awk -v marker="${VTST_PYAMFF_CMAKE_MARKER}" '
    BEGIN { did_subdir = 0; did_link = 0 }
    !did_subdir && /^[[:space:]]*add_subdirectory\(parser\)[[:space:]]*$/ {
      print
      print ""
      print marker
      print "if(EXISTS \"${CMAKE_CURRENT_SOURCE_DIR}/pyamff_fortran/CMakeLists.txt\")"
      print "  add_subdirectory(pyamff_fortran)"
      print "endif()"
      did_subdir = 1
      next
    }
    !did_link && /^[[:space:]]*vasp_create_executable\(vasp_ncl / {
      print
      print ""
      print marker
      print "if(TARGET pyamff_fortran)"
      print "  foreach(_vasp_variant vasp_std vasp_gam vasp_ncl)"
      print "    target_link_libraries(${_vasp_variant} PRIVATE pyamff_fortran)"
      print "    target_include_directories(${_vasp_variant} PRIVATE"
      print "      $<TARGET_PROPERTY:pyamff_fortran,Fortran_MODULE_DIRECTORY>)"
      print "    add_dependencies(${_vasp_variant} pyamff_fortran)"
      print "  endforeach()"
      print "endif()"
      did_link = 1
      next
    }
    { print }
    END {
      if (!did_subdir) exit 2
      if (!did_link) exit 3
    }
  ' "${CMAKE_SRC_LISTS}" > "${tmp}" || {
    local rc=$?
    rm -f "${tmp}"
    if [ "${rc}" -eq 2 ]; then
      die "CMakeLists_src.txt: could not find add_subdirectory(parser)"
    fi
    if [ "${rc}" -eq 3 ]; then
      die "CMakeLists_src.txt: could not find vasp_create_executable(vasp_ncl ...)"
    fi
    die "CMakeLists_src.txt: patch failed (exit ${rc})"
  }
  mv -f "${tmp}" "${CMAKE_SRC_LISTS}"
}

patch_cmake_src() {
  if [ ! -f "${CMAKE_SRC_LISTS}" ]; then
    die "missing staged ${CMAKE_SRC_LISTS} (cmake setup must run before inject)"
  fi

  if cmake_pyamff_hooks_complete; then
    log "CMakeLists_src.txt: VTST_PYAMFF hooks complete (link+mod-I+deps) ? keep"
    return 0
  fi

  if grep -qF "${VTST_PYAMFF_CMAKE_MARKER}" "${CMAKE_SRC_LISTS}"; then
    log "CMakeLists_src.txt: VTST_PYAMFF present but incomplete ? strip and re-apply"
    strip_cmake_pyamff_blocks
  elif grep -q 'pyamff_fortran' "${CMAKE_SRC_LISTS}"; then
    # Incomplete / manual hooks without our marker ? refuse double-insert
    die "CMakeLists_src.txt: pyamff_fortran references exist without ${VTST_PYAMFF_CMAKE_MARKER}.
  Refusing to double-insert. Re-run cmake setup for a clean staged CMakeLists_src.txt,
  or remove the partial pyamff_fortran hooks and re-run inject."
  fi

  insert_cmake_pyamff_hooks
  log "CMakeLists_src.txt: added pyamff_fortran subdir + link + module include + deps"
}

patch_cmake_src

# Windows materializes cmake/CMakeLists/CMakeLists_src.txt -> src/CMakeLists.txt
# as a real file at setup time. Patching only the staged copy leaves src/ stale.
sync_src_cmakelists() {
  local src_lists="${SRC_DIR}/CMakeLists.txt"
  if [ ! -f "${src_lists}" ]; then
    log "src/CMakeLists.txt absent ? skip sync (unusual)"
    return 0
  fi
  if [ -L "${src_lists}" ]; then
    log "src/CMakeLists.txt is symlink ? staged patch is live"
    return 0
  fi
  cp -f "${CMAKE_SRC_LISTS}" "${src_lists}"
  log "synced staged CMakeLists_src.txt -> src/CMakeLists.txt (Windows materialize)"
}

sync_src_cmakelists

# Verify on the file CMake actually loads (src/ when materialized)
CMAKE_VERIFY="${SRC_DIR}/CMakeLists.txt"
if [ ! -f "${CMAKE_VERIFY}" ]; then
  CMAKE_VERIFY="${CMAKE_SRC_LISTS}"
fi
if ! grep -q 'add_subdirectory(pyamff_fortran)' "${CMAKE_VERIFY}"; then
  die "${CMAKE_VERIFY}: add_subdirectory(pyamff_fortran) missing after patch/sync"
fi
if ! grep -q 'PRIVATE pyamff_fortran' "${CMAKE_VERIFY}"; then
  die "${CMAKE_VERIFY}: pyamff_fortran link hook missing after patch/sync"
fi
if ! grep -q 'Fortran_MODULE_DIRECTORY' "${CMAKE_VERIFY}"; then
  die "${CMAKE_VERIFY}: Fortran_MODULE_DIRECTORY include hook missing after patch/sync"
fi
if ! grep -q 'add_dependencies([^)]*pyamff_fortran)' "${CMAKE_VERIFY}"; then
  die "${CMAKE_VERIFY}: add_dependencies(pyamff_fortran) missing after patch/sync"
fi
log "CMakeLists: OK (pyamff link + module -I + deps; verified $(basename "${CMAKE_VERIFY}"))"

log "done (VTST + PyAMFF inject; makefile untouched)"
exit 0

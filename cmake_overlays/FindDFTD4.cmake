#.rst:
# FindDFTD4
# -----------
#
# Locates the DFT-D4 library for VASP (macro ``DFTD4``, API v2).
#
# Strategy:
# 1. Config-first: ``find_package(dftd4 CONFIG)`` (prefix via ``CMAKE_PREFIX_PATH``
#    / ``dftd4_ROOT`` / ``DFTD4_ROOT``).
# 2. Fallback: ``find_library`` for dftd4 + multicharge + mctc-lib + mstore.
#
# Imported target:
#
# ::
#
#   DFTD4::dftd4

set(_DFTD4_PATHS)
if(NOT POLICY CMP0074)
  list(APPEND _DFTD4_PATHS ${DFTD4_ROOT} $ENV{DFTD4_ROOT} ${dftd4_ROOT} $ENV{dftd4_ROOT})
endif()
if(DEFINED DFTD4_ROOT AND NOT "${DFTD4_ROOT}" STREQUAL "")
  list(APPEND _DFTD4_PATHS "${DFTD4_ROOT}")
endif()
if(DEFINED ENV{DFTD4_ROOT} AND NOT "$ENV{DFTD4_ROOT}" STREQUAL "")
  list(APPEND _DFTD4_PATHS "$ENV{DFTD4_ROOT}")
endif()

#-----------------------------------------------------------------------------
# 1) Config package (preferred; pulls transitive deps)
#-----------------------------------------------------------------------------
set(_DFTD4_CMAKE_PREFIX_PATH_SAVE "${CMAKE_PREFIX_PATH}")
if(_DFTD4_PATHS)
  list(PREPEND CMAKE_PREFIX_PATH ${_DFTD4_PATHS})
endif()

# Avoid Module-mode recursion into this file (package name differs: dftd4 vs DFTD4).
find_package(dftd4 ${DFTD4_FIND_VERSION} CONFIG QUIET)

set(CMAKE_PREFIX_PATH "${_DFTD4_CMAKE_PREFIX_PATH_SAVE}")
unset(_DFTD4_CMAKE_PREFIX_PATH_SAVE)

if(dftd4_FOUND)
  if(NOT TARGET DFTD4::dftd4)
    if(TARGET dftd4::dftd4)
      # ALIAS of non-GLOBAL imported targets is not portable; wrap instead.
      add_library(DFTD4::dftd4 INTERFACE IMPORTED)
      set_property(TARGET DFTD4::dftd4 PROPERTY INTERFACE_LINK_LIBRARIES dftd4::dftd4)
    else()
      message(FATAL_ERROR "dftd4 Config found but target dftd4::dftd4 is missing")
    endif()
  endif()
  set(DFTD4_FOUND TRUE)
  if(NOT DFTD4_MESSAGE_SHOWN)
    message(STATUS "Found DFTD4 (Config): dftd4::dftd4 -> DFTD4::dftd4")
  endif()
  set(DFTD4_MESSAGE_SHOWN TRUE CACHE INTERNAL "DFTD4 message shown flag")
  mark_as_advanced(DFTD4_FOUND)
  return()
endif()

#-----------------------------------------------------------------------------
# 2) Manual fallback (dftd4 + multicharge + mctc-lib + mstore)
#-----------------------------------------------------------------------------
find_library(
  DFTD4_LIBRARY
  NAMES dftd4
  HINTS ${_DFTD4_PATHS}
  PATH_SUFFIXES lib lib64
)
find_library(
  DFTD4_MULTICHARGE_LIBRARY
  NAMES multicharge
  HINTS ${_DFTD4_PATHS}
  PATH_SUFFIXES lib lib64
)
find_library(
  DFTD4_MCTC_LIBRARY
  NAMES mctc-lib mctc_lib
  HINTS ${_DFTD4_PATHS}
  PATH_SUFFIXES lib lib64
)
find_library(
  DFTD4_MSTORE_LIBRARY
  NAMES mstore
  HINTS ${_DFTD4_PATHS}
  PATH_SUFFIXES lib lib64
)

find_path(
  DFTD4_INCLUDE_DIR
  NAMES dftd4.h dftd4.mod dftd4_api.mod
  HINTS ${_DFTD4_PATHS}
  PATH_SUFFIXES include include/dftd4 module modules
)

set(DFTD4_DEP_LIBRARIES)
foreach(_dep DFTD4_MULTICHARGE_LIBRARY DFTD4_MCTC_LIBRARY DFTD4_MSTORE_LIBRARY)
  if(${_dep})
    list(APPEND DFTD4_DEP_LIBRARIES ${${_dep}})
  endif()
endforeach()
set(DFTD4_LIBRARIES ${DFTD4_LIBRARY} ${DFTD4_DEP_LIBRARIES})

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(DFTD4
  REQUIRED_VARS DFTD4_LIBRARY DFTD4_INCLUDE_DIR
  FAIL_MESSAGE "Could not find DFTD4. Build with CMake (WITH_API_V2=ON) and set CMAKE_PREFIX_PATH / DFTD4_ROOT."
)

if(DFTD4_FOUND)
  if(NOT DFTD4_MESSAGE_SHOWN)
    message(STATUS "Found DFTD4 (Module fallback): ${DFTD4_LIBRARIES}")
  endif()
  set(DFTD4_MESSAGE_SHOWN TRUE CACHE INTERNAL "DFTD4 message shown flag")
  if(NOT TARGET DFTD4::dftd4)
    add_library(DFTD4::dftd4 UNKNOWN IMPORTED)
    set_target_properties(DFTD4::dftd4 PROPERTIES
      IMPORTED_LOCATION "${DFTD4_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES "${DFTD4_INCLUDE_DIR}"
      INTERFACE_LINK_LIBRARIES "${DFTD4_DEP_LIBRARIES}"
    )
  endif()
endif()

mark_as_advanced(
  DFTD4_LIBRARY
  DFTD4_MULTICHARGE_LIBRARY
  DFTD4_MCTC_LIBRARY
  DFTD4_MSTORE_LIBRARY
  DFTD4_INCLUDE_DIR
)

#.rst:
# FindLibXC
# -----------
#
# Overlay for upstream vasp_cmake FindLibXC: modern LibXC (5+/6+/7+) ships the
# Fortran 2003 interface (``xcf03`` / ``xc_f03_*.mod``). Upstream still gates on
# the legacy ``xc_f90_types_m.mod`` name, which is absent from f03-only installs.
#
# Variables / target match upstream:
#
# ::
#
#   LibXC_FOUND
#   LibXC_LIBRARIES
#   LibXC_FORTRAN_LIBRARIES
#   LibXC_INCLUDE_DIRS
#   LibXC::libxc

set(_LibXC_PATHS)
if(NOT POLICY CMP0074)
  set(_LibXC_PATHS ${LibXC_ROOT} $ENV{LibXC_ROOT} ${LIBXC_ROOT} $ENV{LIBXC_ROOT})
endif()
if(DEFINED LibXC_ROOT AND NOT "${LibXC_ROOT}" STREQUAL "")
  list(APPEND _LibXC_PATHS "${LibXC_ROOT}")
endif()
if(DEFINED ENV{LibXC_ROOT} AND NOT "$ENV{LibXC_ROOT}" STREQUAL "")
  list(APPEND _LibXC_PATHS "$ENV{LibXC_ROOT}")
endif()

find_library(
  LibXC_LIBRARIES
  NAMES xc
  HINTS ${_LibXC_PATHS}
  PATH_SUFFIXES "libxc/lib" "libxc/lib64" "libxc" "lib" "lib64"
)

# Prefer Fortran 2003 binding; fall back to legacy f90 if present.
find_library(
  LibXC_FORTRAN_LIBRARIES
  NAMES xcf03 xcf90
  HINTS ${_LibXC_PATHS}
  PATH_SUFFIXES "libxc/lib" "libxc/lib64" "libxc" "lib" "lib64"
)

# C header (always required).
find_path(
  LibXC_C_INCLUDE_DIR
  NAMES xc.h
  HINTS ${_LibXC_PATHS}
  PATH_SUFFIXES "inc" "libxc" "libxc/include" "include/libxc" "include"
)

# Fortran module gate: f03 first, then legacy f90.
find_path(
  LibXC_F03_INCLUDE_DIR
  NAMES xc_f03_lib_m.mod xc_f03_types_m.mod
  HINTS ${_LibXC_PATHS}
  PATH_SUFFIXES "inc" "libxc" "libxc/include" "include/libxc" "include" "modules"
)

if(LibXC_F03_INCLUDE_DIR)
  set(LibXC_Fortran_INCLUDE_DIR "${LibXC_F03_INCLUDE_DIR}")
else()
  find_path(
    LibXC_F90_INCLUDE_DIR
    NAMES xc_f90_types_m.mod xc_f90_lib_m.mod
    HINTS ${_LibXC_PATHS}
    PATH_SUFFIXES "inc" "libxc" "libxc/include" "include/libxc" "include" "modules"
  )
  set(LibXC_Fortran_INCLUDE_DIR "${LibXC_F90_INCLUDE_DIR}")
endif()

set(LibXC_INCLUDE_DIRS ${LibXC_C_INCLUDE_DIR})
if(LibXC_Fortran_INCLUDE_DIR)
  list(APPEND LibXC_INCLUDE_DIRS ${LibXC_Fortran_INCLUDE_DIR})
  list(REMOVE_DUPLICATES LibXC_INCLUDE_DIRS)
endif()

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(LibXC
  REQUIRED_VARS LibXC_INCLUDE_DIRS LibXC_LIBRARIES LibXC_FORTRAN_LIBRARIES LibXC_C_INCLUDE_DIR LibXC_Fortran_INCLUDE_DIR
  FAIL_MESSAGE "Could not find LibXC (need libxc + libxcf03/xcf90 and xc_f03_*.mod or xc_f90_*.mod). Set LibXC_ROOT / CMAKE_PREFIX_PATH."
)

if(LibXC_FOUND)
  if(NOT LIBXC_MESSAGE_SHOWN)
    message(STATUS "Found LIBXC library: ${LibXC_LIBRARIES} (Fortran: ${LibXC_FORTRAN_LIBRARIES})")
    message(STATUS "  LibXC include dirs: ${LibXC_INCLUDE_DIRS}")
  endif()
  set(LIBXC_MESSAGE_SHOWN TRUE CACHE INTERNAL "Message shown flag")
  if(NOT TARGET LibXC::libxc)
    add_library(LibXC::libxc INTERFACE IMPORTED)
  endif()
  set_property(TARGET LibXC::libxc PROPERTY INTERFACE_LINK_LIBRARIES ${LibXC_LIBRARIES} ${LibXC_FORTRAN_LIBRARIES})
  set_property(TARGET LibXC::libxc PROPERTY INTERFACE_INCLUDE_DIRECTORIES ${LibXC_INCLUDE_DIRS})
endif()

mark_as_advanced(
  LibXC_LIBRARIES
  LibXC_FORTRAN_LIBRARIES
  LibXC_C_INCLUDE_DIR
  LibXC_F03_INCLUDE_DIR
  LibXC_F90_INCLUDE_DIR
  LibXC_INCLUDE_DIRS
)

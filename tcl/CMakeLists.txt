# Tcl 9 binding for libdatachannel.
#
# Two targets share one source file (rtc.c):
#
#   - rtc_tcl  (MODULE) -> rtc.so for `load` / `package require rtc`.
#       Links libtclstub so the .so resolves Tcl symbols against whatever
#       runtime loads it (single binary works against any Tcl 9.x).
#
#   - rtc_tcl_static (STATIC archive) -> for embedders that want to
#       link the extension into a custom tclsh and register it via
#       Tcl_StaticPackage + Rtc_Init. Compiled without USE_TCL_STUBS;
#       the host tclsh provides the Tcl symbols.
#
# LINKER_LANGUAGE CXX: the transitive link drags in libdatachannel (a C++
# static archive), so the linker has to be the C++ driver.

# Tcl 9 discovery - relies on CMake's standard prefix search
# (/usr, /usr/local, and anything passed via -DCMAKE_PREFIX_PATH=...).
# For a Tcl install in a non-standard location, pass:
#   -DCMAKE_PREFIX_PATH=/path/to/tcl-install
# or override the resolved vars directly:
#   -DRTC_TCL_INCLUDE_DIR=...  -DRTC_TCL_STUB_LIBRARY=...
find_path(RTC_TCL_INCLUDE_DIR tcl.h
  PATH_SUFFIXES tcl9.0 tcl
  REQUIRED)

find_library(RTC_TCL_STUB_LIBRARY tclstub
  REQUIRED)

message(STATUS "rtc/tcl: tcl.h        = ${RTC_TCL_INCLUDE_DIR}")
message(STATUS "rtc/tcl: tclstub lib  = ${RTC_TCL_STUB_LIBRARY}")

# -- Shared module (the loadable extension) -----------------------------
set(_rtc_sources rtc_runtime.c rtc_generated.c rtc_special.c)
add_library(rtc_tcl MODULE ${_rtc_sources})

set_target_properties(rtc_tcl PROPERTIES
  PREFIX ""                 # `load` wants `rtc.so`, not `librtc.so`
  OUTPUT_NAME "rtc"
  LINKER_LANGUAGE CXX)

target_compile_definitions(rtc_tcl PRIVATE
  USE_TCL_STUBS
  RTC_PACKAGE_VERSION="${PROJECT_VERSION}")

target_include_directories(rtc_tcl PRIVATE
  ${RTC_TCL_INCLUDE_DIR})

target_link_libraries(rtc_tcl PRIVATE
  Rtc::libdatachannel
  ${RTC_TCL_STUB_LIBRARY})

# Drop pkgIndex.tcl next to the .so so TCLLIBPATH=<build>/tcl resolves
# `package require rtc`.
configure_file(pkgIndex.tcl.in
  ${CMAKE_CURRENT_BINARY_DIR}/pkgIndex.tcl @ONLY)

# -- Static archive (for embedding in a custom tclsh) -------------------
add_library(rtc_tcl_static STATIC ${_rtc_sources})

set_target_properties(rtc_tcl_static PROPERTIES
  OUTPUT_NAME "rtc_tcl"
  LINKER_LANGUAGE CXX)

target_compile_definitions(rtc_tcl_static PRIVATE
  RTC_PACKAGE_VERSION="${PROJECT_VERSION}")
  # No USE_TCL_STUBS: the host tclsh provides Tcl symbols directly.

target_include_directories(rtc_tcl_static PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${RTC_TCL_INCLUDE_DIR})

target_link_libraries(rtc_tcl_static PUBLIC
  Rtc::libdatachannel)

add_library(Rtc::tcl ALIAS rtc_tcl_static)

# Bundled-deps build mode: compile mbedtls + libdatachannel from source
# into a private vendor prefix, then expose Rtc::libdatachannel as an
# INTERFACE IMPORTED target that folds the resulting static archives —
# plus libstdc++ — into whoever links it.
#
# ExternalProject_Add expresses the install-first ordering libdatachannel's
# configure-time find_package(MbedTLS) requires, so this is a single-command
# build (no separate shell script).

include(ExternalProject)

set(RTC_VENDOR_PREFIX ${CMAKE_BINARY_DIR}/vendor)
set(_lib ${RTC_VENDOR_PREFIX}/lib)
set(_inc ${RTC_VENDOR_PREFIX}/include)

# CMake validates IMPORTED targets' INTERFACE_INCLUDE_DIRECTORIES exist at
# configure time; pre-create the path since ExternalProject populates it later.
file(MAKE_DIRECTORY ${_inc})

set(_mbedtls_user_cfg ${CMAKE_SOURCE_DIR}/cmake/mbedtls-user-config.h)
set(_libdc_overrides ${CMAKE_SOURCE_DIR}/cmake/libdatachannel-overrides.cmake)

set(_common_cache_args
  -DCMAKE_INSTALL_PREFIX:PATH=${RTC_VENDOR_PREFIX}
  -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
  -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON
  -DBUILD_SHARED_LIBS:BOOL=OFF)

# --- mbedtls 3.6.6 (commit-pinned) -------------------------------------------
ExternalProject_Add(mbedtls_external
  GIT_REPOSITORY    https://github.com/Mbed-TLS/mbedtls.git
  GIT_TAG           5b64a9fdb979c8971561ec78221b528e3cc4e00a
  GIT_SUBMODULES_RECURSE TRUE
  PREFIX            ${CMAKE_BINARY_DIR}/_mbedtls
  CMAKE_CACHE_ARGS
    ${_common_cache_args}
    -DENABLE_PROGRAMS:BOOL=OFF
    -DENABLE_TESTING:BOOL=OFF
    -DUSE_SHARED_MBEDTLS_LIBRARY:BOOL=OFF
    -DUSE_STATIC_MBEDTLS_LIBRARY:BOOL=ON
    -DMBEDTLS_FATAL_WARNINGS:BOOL=OFF
    -DMBEDTLS_USER_CONFIG_FILE:FILEPATH=${_mbedtls_user_cfg}
  BUILD_BYPRODUCTS
    ${_lib}/libmbedtls.a
    ${_lib}/libmbedx509.a
    ${_lib}/libmbedcrypto.a)

# --- libdatachannel 0.24.3 (commit-pinned) -----------------------------------
ExternalProject_Add(libdatachannel_external
  GIT_REPOSITORY    https://github.com/paullouisageneau/libdatachannel.git
  GIT_TAG           c47f5d77c124c35c31ac8378ad613295a124d354
  GIT_SUBMODULES_RECURSE TRUE
  PREFIX            ${CMAKE_BINARY_DIR}/_libdatachannel
  DEPENDS           mbedtls_external
  CMAKE_CACHE_ARGS
    ${_common_cache_args}
    -DCMAKE_PREFIX_PATH:PATH=${RTC_VENDOR_PREFIX}
    -DCMAKE_PROJECT_INCLUDE_BEFORE:FILEPATH=${_libdc_overrides}
    -DRTC_MBEDTLS_USER_CONFIG:FILEPATH=${_mbedtls_user_cfg}
    -DUSE_MBEDTLS:BOOL=ON
    -DNO_EXAMPLES:BOOL=ON
    -DNO_TESTS:BOOL=ON
    -DPREFER_SYSTEM_LIB:BOOL=OFF
  BUILD_BYPRODUCTS
    ${_lib}/libdatachannel.a
    ${_lib}/libjuice.a
    ${_lib}/libsrtp2.a
    ${_lib}/libusrsctp.a)

# --- Imported static archives ------------------------------------------------
# Each maps to the .a that the corresponding ExternalProject install will
# produce; add_dependencies wires the build order so cmake builds the
# external project before anything that links the IMPORTED target.

function(_rtc_static_lib name external archive)
  add_library(${name} STATIC IMPORTED GLOBAL)
  set_target_properties(${name} PROPERTIES
    IMPORTED_LOCATION ${archive}
    INTERFACE_INCLUDE_DIRECTORIES ${_inc})
  add_dependencies(${name} ${external})
endfunction()

_rtc_static_lib(Rtc::_libdatachannel libdatachannel_external ${_lib}/libdatachannel.a)
_rtc_static_lib(Rtc::_juice          libdatachannel_external ${_lib}/libjuice.a)
_rtc_static_lib(Rtc::_srtp2          libdatachannel_external ${_lib}/libsrtp2.a)
_rtc_static_lib(Rtc::_usrsctp        libdatachannel_external ${_lib}/libusrsctp.a)
_rtc_static_lib(Rtc::_mbedtls        mbedtls_external        ${_lib}/libmbedtls.a)
_rtc_static_lib(Rtc::_mbedx509       mbedtls_external        ${_lib}/libmbedx509.a)
_rtc_static_lib(Rtc::_mbedcrypto     mbedtls_external        ${_lib}/libmbedcrypto.a)

# --- Public INTERFACE dep ----------------------------------------------------
add_library(Rtc::libdatachannel INTERFACE IMPORTED)
target_link_libraries(Rtc::libdatachannel INTERFACE
  Rtc::_libdatachannel
  Rtc::_juice
  Rtc::_srtp2
  Rtc::_usrsctp
  Rtc::_mbedtls
  Rtc::_mbedx509
  Rtc::_mbedcrypto
  Threads::Threads)
# Fold libstdc++ into anything that links Rtc::libdatachannel. Requires the
# linker driver to be g++ — see tcl/CMakeLists.txt (LINKER_LANGUAGE CXX).
#
# libgcc_s.so.1 is intentionally left dynamic. AppImage / linuxdeploy
# convention treats it as host-provided alongside libc/libm — it's a hard
# dep of glibc on every distro. -static-libgcc would only partially help
# anyway (the versioned _Unwind_* symbols libstdc++.a expects don't fully
# resolve from libgcc_eh.a), and mixing static libgcc.a helpers with a
# dynamic libgcc_s.so for unwinding is incoherent.
target_link_options(Rtc::libdatachannel INTERFACE -static-libstdc++)

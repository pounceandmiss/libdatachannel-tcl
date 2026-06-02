# Bundled-libdatachannel build mode: compile libdatachannel + its juice / srtp2
# / usrsctp deps from source into a private vendor prefix, then expose
# Rtc::libdatachannel as an INTERFACE IMPORTED target that folds the resulting
# static archives — plus mbedtls (consumed via find_package against the caller's
# CMAKE_PREFIX_PATH) and libstdc++ — into whoever links it.
#
# mbedtls is NOT bundled here. The caller must install it (e.g. via the parent
# project's build system) at a prefix on CMAKE_PREFIX_PATH and must build it
# with the same MBEDTLS_USER_CONFIG_FILE we point libdatachannel at below.
# Otherwise the SSL config struct layout diverges between caller and callee
# (mbedtls_ssl_config.dtls_srtp_profile_list lands at a different offset),
# NULL-derefing in client_hello.

include(ExternalProject)

set(RTC_VENDOR_PREFIX ${CMAKE_BINARY_DIR}/vendor)
set(_lib ${RTC_VENDOR_PREFIX}/lib)
set(_inc ${RTC_VENDOR_PREFIX}/include)

# CMake validates IMPORTED targets' INTERFACE_INCLUDE_DIRECTORIES exist at
# configure time; pre-create the path since ExternalProject populates it later.
file(MAKE_DIRECTORY ${_inc})

set(_mbedtls_user_cfg ${CMAKE_SOURCE_DIR}/cmake/mbedtls-user-config.h)
set(_libdc_overrides ${CMAKE_SOURCE_DIR}/cmake/libdatachannel-overrides.cmake)

# Pull in mbedtls's CMake config exports (installed at <prefix>/lib/cmake/MbedTLS
# by mbedtls 3.6+). MbedTLS::MbedTLS is the aggregate name libdatachannel's
# bundled FindMbedTLS.cmake creates at its build time — re-assemble it here
# from the official CONFIG-mode lowercase exports so anything linking
# Rtc::libdatachannel pulls in all three mbedtls archives.
find_package(MbedTLS CONFIG REQUIRED)
if(NOT TARGET MbedTLS::MbedTLS)
  add_library(MbedTLS::MbedTLS INTERFACE IMPORTED)
  target_link_libraries(MbedTLS::MbedTLS INTERFACE
    MbedTLS::mbedtls MbedTLS::mbedx509 MbedTLS::mbedcrypto)
endif()

set(_common_cache_args
  -DCMAKE_INSTALL_PREFIX:PATH=${RTC_VENDOR_PREFIX}
  # keep installs in vendor/lib; GNUInstallDirs picks lib64 on some distros
  -DCMAKE_INSTALL_LIBDIR:STRING=lib
  -DCMAKE_BUILD_TYPE:STRING=${CMAKE_BUILD_TYPE}
  -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON
  -DBUILD_SHARED_LIBS:BOOL=OFF
  # ExternalProject sub-builds do not inherit the parent toolchain, so a
  # cross build would compile libdatachannel + juice/srtp2/usrsctp (and
  # mbedtls) with the host compiler and emit host-format objects the cross
  # linker can't use. Forward it explicitly; empty on a native build, where
  # it's a harmless no-op.
  -DCMAKE_TOOLCHAIN_FILE:FILEPATH=${CMAKE_TOOLCHAIN_FILE})

# --- libdatachannel 0.24.3 (commit-pinned) -----------------------------------
# CMAKE_PREFIX_PATH is forwarded from this configure so libdatachannel's own
# find_package(MbedTLS) (via its bundled FindMbedTLS.cmake) discovers the
# same external install we found above.
ExternalProject_Add(libdatachannel_external
  GIT_REPOSITORY    https://github.com/paullouisageneau/libdatachannel.git
  GIT_TAG           c47f5d77c124c35c31ac8378ad613295a124d354
  GIT_SUBMODULES_RECURSE TRUE
  PREFIX            ${CMAKE_BINARY_DIR}/_libdatachannel
  CMAKE_CACHE_ARGS
    ${_common_cache_args}
    -DCMAKE_PREFIX_PATH:PATH=${CMAKE_PREFIX_PATH}
    -DCMAKE_PROJECT_INCLUDE_BEFORE:FILEPATH=${_libdc_overrides}
    -DRTC_MBEDTLS_USER_CONFIG:FILEPATH=${_mbedtls_user_cfg}
    -DUSE_MBEDTLS:BOOL=ON
    -DNO_EXAMPLES:BOOL=ON
    -DNO_TESTS:BOOL=ON
    -DPREFER_SYSTEM_LIB:BOOL=OFF
    # libsrtp defaults ENABLE_WARNINGS_AS_ERRORS=ON for its srtp2 target. Its
    # debug_print("0x%08x", ntohl(ssrc)) then trips -Wformat under mingw, whose
    # ntohl returns u_long -- a distinct type from the uint32_t %x wants, even
    # though both are 32-bit. Doesn't fire on glibc (uint32_t == unsigned int).
    -DENABLE_WARNINGS_AS_ERRORS:BOOL=OFF
  BUILD_BYPRODUCTS
    ${_lib}/libdatachannel.a
    ${_lib}/libjuice.a
    ${_lib}/libsrtp2.a
    ${_lib}/libusrsctp.a)

# --- Imported static archives ------------------------------------------------
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

# --- Public INTERFACE dep ----------------------------------------------------
add_library(Rtc::libdatachannel INTERFACE IMPORTED)
target_link_libraries(Rtc::libdatachannel INTERFACE
  Rtc::_libdatachannel
  Rtc::_juice
  Rtc::_srtp2
  Rtc::_usrsctp
  MbedTLS::MbedTLS
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

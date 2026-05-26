cmake_minimum_required(VERSION 3.21)
project(rtc
  VERSION 0.1.0
  LANGUAGES C CXX)

option(RTC_BUNDLE_LIBDATACHANNEL
  "Build libdatachannel (and juice/srtp2/usrsctp) from source as static \
archives, folding them into the Tcl extension with no runtime .so dependency. \
mbedtls is consumed via find_package against the caller's CMAKE_PREFIX_PATH, \
never bundled here."
  OFF)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

add_compile_options(-Wall -Wextra)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

list(APPEND CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)

find_package(Threads REQUIRED)

if(RTC_BUNDLE_LIBDATACHANNEL)
  # Builds libdatachannel via ExternalProject_Add into
  # ${CMAKE_BINARY_DIR}/vendor and consumes mbedtls via find_package against
  # the caller's CMAKE_PREFIX_PATH; exposes Rtc::libdatachannel as an
  # imported target that folds the resulting static archives - plus
  # libstdc++ - into anything that links it.
  include(BundleDeps)
else()
  # libdatachannel installs that link mbedtls statically (e.g. zippy's
  # vendored prefix) export `MbedTLS::MbedTLS` in LibDataChannelTargets'
  # INTERFACE_LINK_LIBRARIES - an aggregate that libdatachannel's
  # build-time cmake/Modules/FindMbedTLS.cmake creates but that the
  # installed LibDataChannelConfig.cmake doesn't find_dependency() or
  # recreate. Re-assemble it from the official MbedTLSConfig exports so
  # find_package(LibDataChannel) succeeds against those installs.
  #
  # Distro packages of libdatachannel are typically shared and don't
  # reference MbedTLS::MbedTLS in their export, so this lookup stays
  # QUIET / non-REQUIRED. If MbedTLS really is needed and missing,
  # find_package(LibDataChannel REQUIRED) below produces the real error.
  find_package(MbedTLS CONFIG QUIET)
  if(MbedTLS_FOUND AND NOT TARGET MbedTLS::MbedTLS)
    add_library(MbedTLS::MbedTLS INTERFACE IMPORTED)
    target_link_libraries(MbedTLS::MbedTLS INTERFACE
      MbedTLS::mbedtls MbedTLS::mbedx509 MbedTLS::mbedcrypto)
  endif()
  find_package(LibDataChannel REQUIRED)
  add_library(Rtc::libdatachannel INTERFACE IMPORTED)
  target_link_libraries(Rtc::libdatachannel INTERFACE LibDataChannel::LibDataChannel)
endif()

add_subdirectory(tcl)

enable_testing()
add_subdirectory(tests)

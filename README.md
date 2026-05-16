# rtc - Tcl 9 bindings for libdatachannel

A thin Tcl wrapper over [libdatachannel](https://libdatachannel.org/)'s C
API.

## Build

Requires CMake >= 3.21, Tcl 9.0, and one of:

- **System libdatachannel** (>= 0.24) - the default.
- **Bundled** - pass `-DRTC_BUNDLE_DEPS=ON` to vendor libdatachannel
  0.24.3 + mbedtls 3.6.6 from source as static archives. Slower first
  build; produces a `rtc.so` with no runtime `.so` dependency on
  libdatachannel.

```
cmake -S . -B build
cmake --build build
```

The Tcl extension lands at `build/tcl/rtc.so` with a `pkgIndex.tcl`
beside it. Point Tcl at it via `TCLLIBPATH`:

```
TCLLIBPATH=$PWD/build/tcl tclsh9.0
% package require rtc
0.1.0
```

## Hello peer connection

```tcl
package require rtc
::rtc::set-log-level warning

set pc [::rtc::pc::new -ice-servers {stun:stun.l.google.com:19302}]

# Callbacks fire on libdatachannel worker threads and are dispatched
# onto the Tcl main thread via Tcl_ThreadQueueEvent. The script gets
# the rtc id appended first, then event-specific args.
::rtc::pc::on-state-change $pc [list apply {{pc state} {
    puts "pc $pc state: $state"
}}]
::rtc::pc::on-local-description $pc [list apply {{pc sdp type} {
    puts "local $type SDP (len=[string length $sdp])"
}}]
```

## Tcl command surface

The Tcl namespace mirrors libdatachannel's implicit class system: the
first-int argument of each `rtcXxx` function names the receiver class.

| Tcl namespace      | rtc functions handled                          |
|--------------------|------------------------------------------------|
| `::rtc::pc::*`     | `rtcXxx(int pc, ...)` - peer-connection methods |
| `::rtc::track::*`  | `rtcXxx(int tr, ...)` - track methods           |
| `::rtc::dc::*`     | `rtcXxx(int dc, ...)` - data-channel methods    |
| `::rtc::common::*` | `rtcXxx(int id, ...)` - track/dc/ws shared API  |
| `::rtc::ws::*`     | `rtcXxx(int ws, ...)` - websocket client        |
| `::rtc::*`         | global functions (`preload`, `cleanup`, etc.)   |

Conventions:
- Leaf names are kebab-cased and have the class token stripped (e.g.
  `rtcGetTrackMid` -> `::rtc::track::get-mid`; `rtcClosePeerConnection`
  -> `::rtc::pc::close`).
- Callback setters become `on-<event>` registration commands. Passing
  an empty string unregisters: `::rtc::pc::on-state-change $pc ""`.
- All callback scripts receive the rtc id as their first appended
  argument, then any event-specific args (state strings, SDP strings,
  binary message bytes, etc.).
- Negative libdatachannel return codes raise a Tcl error with
  `errorCode {RTC invalid|failure|not-avail|too-small}`.

## Handle ownership

rtc ids returned by commands like `::rtc::pc::new`, `::rtc::pc::add-track`,
and `::rtc::pc::create-data-channel` are the **raw libdatachannel integer
ids** - not Tcl-side wrappers. This is deliberate: a C consumer (e.g. a
separate audio playback library) can take the same int and call
`rtcSet*Callback(id, ...)` directly.

Each `rtcSet*Callback` slot is single-writer in libdatachannel. The
binding never touches `rtcSetUserPointer` / `rtcGetUserPointer`, leaving
that slot free for C consumers' own state. Tcl-side registration via
`::rtc::*::on-...` and direct C-side `rtcSet*Callback` calls race for
the same slot - **last writer wins per slot**.

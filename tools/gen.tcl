#!/usr/bin/env tclsh9.0
#
# tools/gen.tcl - emit tcl/rtc_generated.c from libdatachannel's rtc.h.
#
# libdatachannel's C API is regular enough to bind mechanically. We exploit
# four patterns by regex over the header:
#
#   (1) First int-arg name -> Tcl namespace
#         int pc -> ::rtc::pc::*       (peer connection methods)
#         int tr -> ::rtc::track::*    (track methods)
#         int dc -> ::rtc::dc::*       (data-channel methods)
#         int id -> ::rtc::common::*   (track/dc/ws shared API)
#         int ws -> ::rtc::ws::*       (websocket methods)
#         no int -> ::rtc::*           (global/library functions)
#
#   (2) Out-string:   int rtcGetX(int X, char *buf, int size)
#         Emit a command that calls once with NULL/0 to size, allocates,
#         calls again, returns the resulting string.
#
#   (3) Callback setter:   int rtcSet*Callback(int X, rtcXxxCallbackFunc cb)
#         Emit a `::rtc::<ns>::on-<event>` command that registers a Tcl
#         command-prefix (or "" to clear). The runtime installs a trampoline
#         that queues a Tcl_ThreadQueueEvent for dispatch on the main thread.
#
#   (4) Plain int method:   int rtcSomething(int X, scalar...)
#         Direct wrapper: parse args, call, map negative return to TCL_ERROR.
#
# Anything that doesn't fit (structs in/out, multiple out-strings, in/out
# size args, etc.) is listed at the end of the run and hand-written in
# tcl/rtc_special.c.
#
# Usage:  tclsh9.0 tools/gen.tcl ?-h /path/to/rtc.h? ?-o output.c?
#         (defaults: /usr/include/rtc/rtc.h -> tcl/rtc_generated.c)

package require Tcl 9.0

set ::header_path /usr/include/rtc/rtc.h
set ::output_path tcl/rtc_generated.c
set ::header_out  tcl/rtc_generated.h

# -- arg parse ---------------------------------------------------------
for {set i 0} {$i < [llength $::argv]} {incr i} {
    set a [lindex $::argv $i]
    switch -- $a {
        -h { set ::header_path [lindex $::argv [incr i]] }
        -o { set ::output_path [lindex $::argv [incr i]] }
        default { puts stderr "unknown arg: $a"; exit 2 }
    }
}

# -- helpers -----------------------------------------------------------

# CamelCase -> kebab-case (for Tcl command names)
proc kebab {s} {
    set s [regsub -all {([a-z0-9])([A-Z])} $s {\1-\2}]
    set s [regsub -all {([A-Z]+)([A-Z][a-z])} $s {\1-\2}]
    string tolower $s
}

# CamelCase -> snake_case (for C identifiers)
proc snake {s} {
    set s [regsub -all {([a-z0-9])([A-Z])} $s {\1_\2}]
    set s [regsub -all {([A-Z]+)([A-Z][a-z])} $s {\1_\2}]
    string tolower $s
}

# Read + canonicalize the header. Strip preprocessor lines and the
# RTC_C_EXPORT / RTC_API attribute macros. Keep "const" so the pattern
# detector can distinguish out-buffers (char *) from input strings
# (const char *). RTC_DEPRECATED is rewritten to a sentinel so the
# function pass can drop deprecated entries.
proc canonicalize {raw} {
    set s $raw
    regsub -all -line {^\s*#.*$} $s {} s
    regsub -all -line {//[^\n]*} $s {} s
    regsub -all {/\*.*?\*/} $s {} s
    regsub -all {RTC_C_EXPORT|RTC_API} $s {} s
    regsub -all {RTC_DEPRECATED} $s { __RTC_DEPRECATED__ } s
    # Normalize pointer spacing: `T *N` and `T*N` -> `T* N`.
    regsub -all {(\w)\s*\*} $s {\1*} s
    regsub -all {\*(\w)} $s {* \1} s
    regsub -all {\s+} $s { } s
    return $s
}

# Split a function-arg list ("int pc, char* buf, int size") into a flat list
# of {type name type name ...} suitable for `foreach {t n} $argList`.
proc split_args {argstr} {
    set argstr [string trim $argstr]
    if {$argstr eq "" || $argstr eq "void"} { return {} }
    set out {}
    foreach pair [split $argstr ,] {
        set pair [string trim $pair]
        # last whitespace splits type from name
        set sp [string last " " $pair]
        if {$sp < 0} {
            # unnamed param - bail
            return -code error "unnamed param in: $argstr"
        }
        lappend out [string trim [string range $pair 0 [expr {$sp-1}]]]
        lappend out [string trim [string range $pair $sp end]]
    }
    return $out
}

set fh [open $::header_path r]
set raw [read $fh]
close $fh
set src [canonicalize $raw]

# -- enums -------------------------------------------------------------
# typedef enum { RTC_FOO = N, ... } rtcXxx;
# Build a (cName -> { {RTC_NAME value} ... }) table.
array set ::enums {}

foreach {- body name} [regexp -all -inline -- {typedef enum *\{([^\}]*)\} *(\w+) *;} $src] {
    set entries {}
    # strip trailing commas, split on comma
    foreach ent [split $body ,] {
        set ent [string trim $ent]
        if {$ent eq ""} continue
        if {[regexp {^(\w+)\s*=\s*(-?\d+)$} $ent - k v]} {
            lappend entries [list $k $v]
        } elseif {[regexp {^(\w+)$} $ent - k]} {
            # auto-increment (rare in rtc.h, but handle it)
            set v [expr {[llength $entries]}]
            lappend entries [list $k $v]
        }
    }
    set ::enums($name) $entries
}

# -- callback typedefs -------------------------------------------------
# typedef void (*rtcXxxCallbackFunc)(args);
array set ::cb_types {}

foreach {- name args} [regexp -all -inline -- \
    {typedef void *\( *\* *(\w+) *\) *\(([^)]*)\) *;} $src] {
    set ::cb_types($name) [split_args $args]
}

# -- function declarations ---------------------------------------------
# Match: ReturnType rtcSomething(args);
# ReturnType is one of: int | void | bool | rtcMessage*
# The `;` terminator means rtc.h's `RTC_DEPRECATED static inline ... { ... }`
# packetization shims (no semicolon at the decl) never get picked up.
set ::funcs {}

foreach {full ret name args} [regexp -all -inline -- \
    {(?:^| )((?:__RTC_DEPRECATED__ +)?(?:int|void|bool|rtcMessage\*)) +(rtc\w+) *\(([^)]*)\) *;} $src] {
    if {[string match *__RTC_DEPRECATED__* $full]} {
        lappend ::skipped [list $name "deprecated"]
        continue
    }
    set ret [string trim $ret]
    lappend ::funcs [list $ret $name [split_args $args]]
}

# -- classify by first int-arg name ------------------------------------

# Returns one of: pc tr dc id ws "" (empty = no rtc handle, global function)
proc classify {arglist} {
    if {[llength $arglist] < 2} { return "" }
    lassign [lrange $arglist 0 1] t n
    if {$t ne "int"} { return "" }
    switch -- $n {
        pc - tr - dc - id - ws - wsserver { return $n }
        default { return "" }
    }
}

# Tcl namespace per class
array set ::ns_for {
    pc       ::rtc::pc
    tr       ::rtc::track
    dc       ::rtc::dc
    id       ::rtc::common
    ws       ::rtc::ws
    wsserver ::rtc::wsserver
    ""       ::rtc
}

# Strip "rtc" prefix and any occurrence of the receiver class's own name
# token. The namespace already identifies the class so repeating it in the
# leaf is redundant.
#
#   class  token-stripped
#   -----  -------------
#   pc     PeerConnection
#   tr     Track
#   dc     DataChannel
#   ws     WebSocket
#   ws-srv WebSocketServer
#   id     (none - "common" namespace, function names don't carry a class token)
#
# Factory functions like rtcCreateDataChannel(int pc, ...) classify as
# class=pc, so "DataChannel" is NOT stripped - leaf stays create-data-channel.
# rtcGetTrackMid(int tr) classifies as class=tr, so "Track" IS stripped -
# leaf becomes get-mid.
array set ::class_token {
    pc       PeerConnection
    tr       Track
    dc       DataChannel
    ws       WebSocket
    wsserver WebSocketServer
}
proc leaf_name {fname class} {
    set s [string range $fname 3 end]   ;# strip "rtc"
    if {[info exists ::class_token($class)]} {
        regsub -all $::class_token($class) $s {} s
    }
    set s [kebab $s]
    regsub -all -- {--+} $s - s
    set s [string trim $s -]
    return $s
}

# -- pattern detection -------------------------------------------------

proc is_outstring {arglist} {
    # last 3 args: (int X, char* buffer, int size)
    if {[llength $arglist] != 6} { return 0 }
    return [expr {[lindex $arglist 0] eq "int"
                  && [lindex $arglist 2] eq "char*"
                  && [lindex $arglist 4] eq "int"}]
}

proc is_callback_setter {fname arglist} {
    # (int X, rtcXxxCallbackFunc cb)  - generalized so it catches not just
    # rtcSet*Callback but also rtcChainPliHandler / rtcChainRembHandler.
    if {[llength $arglist] != 4} { return 0 }
    if {[lindex $arglist 0] ne "int"} { return 0 }
    set cbt [lindex $arglist 2]
    return [info exists ::cb_types($cbt)]
}

# Scalar arg type? Anything we can parse with Tcl_GetIntFromObj / etc.
proc is_scalar {t} {
    return [expr {$t in {
        int bool {unsigned int} size_t
        uint8_t uint16_t uint32_t int8_t int16_t int32_t
    }}]
}

# Map a scalar type to the C cast we use after Tcl_GetIntFromObj.
proc scalar_cast {t} {
    switch -- $t {
        int - bool { return "" }
        default    { return "($t)" }
    }
}

# -- open outputs + preamble -------------------------------------------

set ::fh_c [open $::output_path w]
set ::fh_h [open $::header_out w]

puts $::fh_c {/* AUTO-GENERATED by tools/gen.tcl from libdatachannel rtc.h.
 * Do not edit. Regenerate after libdatachannel header changes.
 */
#include "rtc_runtime.h"
#include "rtc_generated.h"
#include <rtc/rtc.h>
#include <tcl.h>
#include <string.h>}
puts $::fh_c ""

# -- enum -> string converters -----------------------------------------
# For every rtc*State enum we emit an int->const char* function so the
# Tcl side gets readable strings. Mapping: strip "RTC_" prefix, lowercase,
# split runs of caps with '-'.

proc enum_value_to_str {sym} {
    set s [string range $sym 4 end]   ;# strip "RTC_"
    set s [string map {_ -} $s]
    return [string tolower $s]
}

foreach enum_name [array names ::enums] {
    set fn "RtcEnumStr_[snake $enum_name]"
    puts $::fh_c "const char *${fn}(int v) \{"
    puts $::fh_c "    switch (v) \{"
    foreach entry $::enums($enum_name) {
        lassign $entry sym val
        puts $::fh_c "        case $val: return \"[enum_value_to_str $sym]\";"
    }
    puts $::fh_c "        default: return \"unknown\";"
    puts $::fh_c "    \}"
    puts $::fh_c "\}"
    puts $::fh_c ""
}

# -- pass 1: classify functions, build dispatch table ------------------

set ::skipped {}
set ::commands {}   ;# list of {cName tclName cmd_func_name}
set ::callback_slots {}  ;# list of {tclName setter trampoline_name slot_const}

# Helper: declare a slot constant. Returns the slot enum symbol.
set ::next_slot 1
set ::all_slots [dict create]
proc declare_slot {class event} {
    set sym "RTC_SLOT_[string toupper [string map {- _} ${class}_${event}]]"
    if {[dict exists $::all_slots $sym]} { return $sym }
    dict set ::all_slots $sym $::next_slot
    incr ::next_slot
    return $sym
}

# Shape tag -> runtime entry point. The tag is built by walking the
# callback's tail args: "I" for each int, "S" for each string/enum.
# Combinations actually present in libdatachannel right now:
#   ""    no args after id   -> open / closed / available / pli / etc.
#   "I"   one int            -> data-channel / track / remb
#   "S"   one string         -> error / state-change (enum to string)
#   "SS"  two strings        -> local-description / local-candidate
#   "SI"  string + size      -> message (binary blob)
array set ::shape_to_post {
    ""    RtcEnqueueNoArgs
    "I"   RtcEnqueueInt
    "S"   RtcEnqueueString
    "SS"  RtcEnqueueTwoStr
    "SI"  RtcEnqueueBytes
}

# Generate a trampoline C function and a Cmd_..._on_event wrapper for one
# (callback typedef x setter x slot). Returns nothing; writes to $::fh_c and
# appends to ::commands.
proc emit_callback_binding {fname class arglist} {
    # fname = rtcSetLocalDescriptionCallback, etc.
    set cb_type_arg [lindex $arglist 2]
    set cb_args $::cb_types($cb_type_arg)
    # Derive event name: rtcSetLocalDescriptionCallback -> local-description
    #                    rtcChainPliHandler             -> pli
    set ev $fname
    regsub {^rtc(Set|Chain|Add)} $ev {} ev
    regsub {(Callback|Handler)$} $ev {} ev
    set ev [kebab $ev]

    set slot [declare_slot $class $ev]
    set tramp "Tramp_[snake $class]_[string map {- _} $ev]"
    set cmd   "Cmd_[snake $class]_on_[string map {- _} $ev]"

    # Build trampoline parameter list (verbatim from typedef) and the
    # body that calls RtcEnqueueCallback with shape-specific args. The
    # shape tag ($ts, computed below) encodes the args AFTER the first
    # int (the rtc id) and selects the runtime entry point.
    set first_int_name [lindex $cb_args 1]
    # tail args (after first int)
    set tail [lrange $cb_args 2 end-2]   ;# drop trailing void* ptr

    set proto_args {}
    foreach {t n} $cb_args {
        lappend proto_args "$t $n"
    }
    set proto [join $proto_args ", "]

    # Emit trampoline.
    puts $::fh_c "static void $tramp\($proto\) \{"
    puts $::fh_c "    (void)ptr;"
    # Build the RtcEnqueueCallback call: it always takes (id, slot, then variadic args matching shape).
    # We expose a fixed dispatch function per shape to keep the API stable.
    # Build the RtcEnqueue_* variant and its args. Enum types are decoded
    # to a static string in the trampoline itself so the runtime stays
    # generic (no per-slot decoder table).
    set call_args [list $first_int_name $slot]
    set ts ""
    foreach {t n} $tail {
        if {$t eq "char*" || $t eq "const char*"} {
            lappend call_args $n
            append ts S
        } elseif {$t eq "int" || [is_scalar $t]} {
            if {$t eq "int"} {
                lappend call_args $n
            } else {
                lappend call_args "(int)$n"
            }
            append ts I
        } elseif {[info exists ::enums($t)]} {
            lappend call_args "RtcEnumStr_[snake $t]($n)"
            append ts S
        } else {
            # Unknown type - leave a TODO; user must hand-edit.
            lappend call_args "/* TODO: $t $n */ 0"
            append ts I
        }
    }
    if {![info exists ::shape_to_post($ts)]} {
        error "no RtcEnqueue variant for callback shape '$ts' (function $fname)"
    }
    set post_name $::shape_to_post($ts)
    puts $::fh_c "    ${post_name}([join $call_args ", "]);"
    puts $::fh_c "\}"
    puts $::fh_c ""

    # Emit registration command: args = pc cmdPrefix (cmdPrefix "" clears).
    puts $::fh_c "static int $cmd\(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv\[\]) \{"
    puts $::fh_c "    (void)cd;"
    puts $::fh_c "    if (objc != 3) \{ Tcl_WrongNumArgs(interp, 1, objv, \"$class cmdPrefix\"); return TCL_ERROR; \}"
    puts $::fh_c "    int id;"
    puts $::fh_c "    if (Tcl_GetIntFromObj(interp, objv\[1\], &id) != TCL_OK) return TCL_ERROR;"
    puts $::fh_c "    return RtcRegisterCallback(interp, id, $slot, objv\[2\],"
    puts $::fh_c "        (RtcSetterFn)$fname, (void(*)(void))$tramp);"
    puts $::fh_c "\}"
    puts $::fh_c ""

    set tcl_name "$::ns_for($class)::on-$ev"
    lappend ::commands [list $fname $tcl_name $cmd]
}

# -- pass 2: walk functions --------------------------------------------

foreach f $::funcs {
    lassign $f ret name args
    set class [classify $args]

    # Skip media interceptor - sync-return doesn't fit thread-queue model.
    if {$name eq "rtcSetMediaInterceptorCallback"} {
        lappend ::skipped [list $name "sync-return callback (media interceptor)"]
        continue
    }
    # Skip rtcSendMessage - generic plain-int wrapper would stringify the
    # payload via Tcl_GetString, mangling embedded NULs. Hand-written in
    # rtc_special.c with Tcl_GetByteArrayFromObj.
    if {$name eq "rtcSendMessage"} {
        lappend ::skipped [list $name "binary payload (hand-written in specials)"]
        continue
    }

    if {[is_callback_setter $name $args]} {
        emit_callback_binding $name $class $args
        continue
    }

    if {$ret eq "int" && [is_outstring $args]} {
        # int rtcGetX(int X, char *buffer, int size)
        set leaf [leaf_name $name $class]
        set cmd "Cmd_[snake $class]_[string map {- _} $leaf]"
        puts $::fh_c "static int $cmd\(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv\[\]) \{"
        puts $::fh_c "    (void)cd;"
        puts $::fh_c "    if (objc != 2) \{ Tcl_WrongNumArgs(interp, 1, objv, \"$class\"); return TCL_ERROR; \}"
        puts $::fh_c "    int id;"
        puts $::fh_c "    if (Tcl_GetIntFromObj(interp, objv\[1\], &id) != TCL_OK) return TCL_ERROR;"
        puts $::fh_c "    return RtcCmd_OutString(interp, $name, id);"
        puts $::fh_c "\}"
        puts $::fh_c ""
        set tcl_name "$::ns_for($class)::$leaf"
        lappend ::commands [list $name $tcl_name $cmd]
        continue
    }

    # Plain int method: int rtcX(int X, scalar...)
    # Only handle scalar args after the first int - input strings (const
    # char *) are fine; a mutable char * signals an out-buffer and goes
    # to specials. Likewise any pointer/struct arg is special.
    if {$ret eq "int" || $ret eq "bool"} {
        set ok 1
        foreach {t n} $args {
            if {[is_scalar $t] || $t eq "const char*"} { continue }
            set ok 0
            break
        }
        if {$ok} {
            set leaf [leaf_name $name $class]
            set cmd "Cmd_[snake $class]_[string map {- _} $leaf]"

            # Build arg parsing code.
            puts $::fh_c "static int $cmd\(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv\[\]) \{"
            puts $::fh_c "    (void)cd;"
            set ntotal [expr {[llength $args] / 2}]
            set wnstr ""
            foreach {t n} $args { append wnstr "$n " }
            set wnstr [string trimright $wnstr]
            puts $::fh_c "    if (objc != [expr {1 + $ntotal}]) \{ Tcl_WrongNumArgs(interp, 1, objv, \"$wnstr\"); return TCL_ERROR; \}"
            set i 1
            set call_args {}
            foreach {t n} $args {
                if {$t eq "const char*"} {
                    puts $::fh_c "    const char *v_$n = Tcl_GetString(objv\[$i\]);"
                    lappend call_args "v_$n"
                } elseif {[is_scalar $t]} {
                    puts $::fh_c "    int raw_$n;"
                    puts $::fh_c "    if (Tcl_GetIntFromObj(interp, objv\[$i\], &raw_$n) != TCL_OK) return TCL_ERROR;"
                    lappend call_args "[scalar_cast $t]raw_$n"
                }
                incr i
            }
            if {$ret eq "int"} {
                puts $::fh_c "    int rc = ${name}([join $call_args ", "]);"
                # rtcDelete*: drop our per-id callback registry entry so
                # long-lived processes don't leak it across connection
                # churn. Safe regardless of rc - runtime helper no-ops on
                # ids it has never seen.
                if {[string match rtcDelete* $name]} {
                    puts $::fh_c "    RtcUnregisterAllCallbacks(raw_$class);"
                }
                puts $::fh_c "    return RtcReturnInt(interp, rc);"
            } else {
                puts $::fh_c "    bool rc = ${name}([join $call_args ", "]);"
                puts $::fh_c "    Tcl_SetObjResult(interp, Tcl_NewBooleanObj(rc));"
                puts $::fh_c "    return TCL_OK;"
            }
            puts $::fh_c "\}"
            puts $::fh_c ""
            set tcl_name "$::ns_for($class)::[leaf_name $name $class]"
            lappend ::commands [list $name $tcl_name $cmd]
            continue
        }
    }

    # void rtcX(void) - for rtcPreload, rtcCleanup.
    if {$ret eq "void" && ($args eq "" || $args eq {})} {
        set leaf [leaf_name $name $class]
        set cmd "Cmd_[snake $class]_[string map {- _} $leaf]"
        puts $::fh_c "static int $cmd\(void *cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv\[\]) \{"
        puts $::fh_c "    (void)cd; (void)objv;"
        puts $::fh_c "    if (objc != 1) \{ Tcl_WrongNumArgs(interp, 1, objv, \"\"); return TCL_ERROR; \}"
        puts $::fh_c "    ${name}();"
        puts $::fh_c "    return TCL_OK;"
        puts $::fh_c "\}"
        puts $::fh_c ""
        set tcl_name "$::ns_for($class)::$leaf"
        lappend ::commands [list $name $tcl_name $cmd]
        continue
    }

    lappend ::skipped [list $name "no pattern match (ret=$ret args={$args})"]
}

# -- command-registration table + slot-id header -----------------------

puts $::fh_c "const RtcCommand RtcGeneratedCommands\[\] = \{"
foreach c $::commands {
    lassign $c rtcname tclname cfunc
    puts $::fh_c "    \{ \"$tclname\", $cfunc \},"
}
puts $::fh_c "    \{ NULL, NULL \}"
puts $::fh_c "\};"

puts $::fh_h "/* AUTO-GENERATED by tools/gen.tcl. Do not edit. */"
puts $::fh_h "#ifndef RTC_GENERATED_H"
puts $::fh_h "#define RTC_GENERATED_H"
puts $::fh_h ""
puts $::fh_h "/* Callback slot ids - one per rtcSet*Callback or rtcChain*Handler. */"
foreach {sym n} $::all_slots {
    puts $::fh_h "#define $sym $n"
}
puts $::fh_h "#define RTC_SLOT_MAX $::next_slot"
puts $::fh_h ""
puts $::fh_h "#endif /* RTC_GENERATED_H */"

close $::fh_c
close $::fh_h

# -- summary -----------------------------------------------------------

puts stderr "wrote [llength $::commands] commands -> $::output_path"
puts stderr "                    + slot ids -> $::header_out"
puts stderr "skipped [llength $::skipped] entry points:"
foreach s $::skipped {
    lassign $s n why
    puts stderr "  $n   ($why)"
}

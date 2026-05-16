/*
 * rtc_runtime.h - hand-written runtime supporting the generated bindings.
 *
 * The generator (tools/gen.tcl) emits one Tcl command wrapper per rtc*
 * entry point that matches a known pattern (out-string, plain int method,
 * or callback setter). Wrappers call into the helpers declared below.
 *
 * Threading model:
 *   libdatachannel fires callbacks on its worker threads. Trampolines
 *   here capture (rtc id, slot, args), queue a Tcl_Event with
 *   Tcl_ThreadQueueEvent, and return immediately. The event handler runs
 *   on the Tcl thread that registered the callback and invokes the
 *   command-prefix script.
 *
 *   libdatachannel's user pointer (rtcSetUserPointer / rtcGetUserPointer)
 *   is intentionally NOT used by this runtime. C consumers that hold the
 *   rtc int id can read/write the user pointer themselves and install
 *   their own callbacks via rtcSet*Callback - last writer wins per slot,
 *   so a C-installed callback simply replaces our trampoline.
 */

#ifndef RTC_RUNTIME_H
#define RTC_RUNTIME_H

#include <tcl.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Command table entry - generator emits one array of these. */
typedef struct {
    const char     *name;     /* fully-qualified Tcl command */
    Tcl_ObjCmdProc *proc;
} RtcCommand;

extern const RtcCommand RtcGeneratedCommands[];
extern const RtcCommand RtcSpecialCommands[];

/* Generic shapes for rtcSet*Callback setters. The generator casts each
 * specific signature to this and back - the cast is safe because the
 * runtime never invokes through the pointer; it just relays it to the
 * library. */
typedef int (*RtcSetterFn)(int id, void (*cb)(void));

/* -- return-value helpers (called from generated wrappers) --------- */

/* Maps a negative libdatachannel error code to TCL_ERROR with a named
 * error code (-1 invalid, -2 failure, -3 not-avail, -4 too-small). Zero
 * or positive results are returned as the integer Tcl result with
 * TCL_OK. */
int RtcReturnInt(Tcl_Interp *interp, int rc);

/* Out-string pattern: function signature `int fn(int id, char *buf, int size)`.
 * Calls fn(id, NULL, 0) to determine length, allocates, calls again,
 * returns the resulting string as the interp result. */
int RtcCmd_OutString(Tcl_Interp *interp,
                     int (*fn)(int, char *, int),
                     int id);

/* -- callback registration (generated wrappers call this) ---------- */

/* Registers `script` (a Tcl command prefix, may be Tcl_NewObj() / empty
 * to unregister) as the handler for (id, slot). If script is non-empty,
 * the runtime calls `setter(id, trampoline)` to install our trampoline
 * with libdatachannel; if empty, it calls `setter(id, NULL)` and clears
 * the stored script. */
int RtcRegisterCallback(Tcl_Interp *interp,
                        int id, int slot,
                        Tcl_Obj *script,
                        RtcSetterFn setter,
                        void (*trampoline)(void));

/* Drops the registry entry for `id` (all per-slot scripts decref'd, the
 * entry and its scripts array freed, hash entry removed). Called from
 * `*::delete` wrappers after the corresponding rtcDelete*. Safe to call
 * for an id that was never registered (no-op). Any callback events that
 * libdatachannel queued before the delete and that are still pending in
 * the Tcl event loop become no-ops in dispatch. */
void RtcUnregisterAllCallbacks(int id);

/* -- trampoline post helpers (generated trampolines call these) ---- */

/* One variant per distinct callback-argument shape in libdatachannel.
 * Each allocates a Tcl_Event, copies any strings/bytes, and dispatches
 * via Tcl_ThreadQueueEvent onto the thread that registered the slot.
 * Safe to call from any thread. */
void RtcEnqueueNoArgs   (int rtcId, int slot);
void RtcEnqueueInt      (int rtcId, int slot, int i1);
void RtcEnqueueString   (int rtcId, int slot, const char *s1);
void RtcEnqueueTwoStr   (int rtcId, int slot, const char *s1, const char *s2);
void RtcEnqueueBytes    (int rtcId, int slot, const char *data, int size);

/* -- module init -------------------------------------------------- */

#ifndef RTC_PACKAGE_VERSION
#define RTC_PACKAGE_VERSION "0.1.0"
#endif

#ifdef __cplusplus
}
#endif

#endif /* RTC_RUNTIME_H */

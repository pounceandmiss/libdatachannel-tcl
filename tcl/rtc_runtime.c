/*
 * rtc_runtime.c - see rtc_runtime.h for design notes.
 */

#include "rtc_runtime.h"
#include "rtc_generated.h"

#include <rtc/rtc.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define RTC_PKG_NAME "rtc"

/* -- global registry -------------------------------------------------
 * Keyed by rtc int id. Each entry pins the interp + thread that
 * registered the first callback for that id; all later registrations
 * for the same id must come from the same thread (typical use).
 *
 * The libdatachannel user pointer is NOT used by this runtime - C
 * consumers holding the int id own that slot for their own state.
 * -------------------------------------------------------------------- */

typedef struct {
    Tcl_Interp     *interp;
    Tcl_ThreadId    thread;
    /* one cmd-prefix per slot; NULL if no script is registered */
    Tcl_Obj       **scripts;   /* length = RTC_SLOT_MAX, lazily allocated */
} RtcSlotEntry;

static Tcl_Mutex     g_mutex = NULL;
static Tcl_HashTable g_registry;
static int           g_inited = 0;

static void EnsureRegistry(void) {
    Tcl_MutexLock(&g_mutex);
    if (!g_inited) {
        Tcl_InitHashTable(&g_registry, TCL_ONE_WORD_KEYS);
        g_inited = 1;
    }
    Tcl_MutexUnlock(&g_mutex);
}

static RtcSlotEntry *FindEntry_locked(int id) {
    Tcl_HashEntry *he = Tcl_FindHashEntry(&g_registry, (void *)(intptr_t)id);
    return he ? (RtcSlotEntry *)Tcl_GetHashValue(he) : NULL;
}

static RtcSlotEntry *GetOrCreateEntry_locked(int id,
                                             Tcl_Interp *interp,
                                             Tcl_ThreadId thread) {
    int isNew;
    Tcl_HashEntry *he = Tcl_CreateHashEntry(&g_registry, (void *)(intptr_t)id, &isNew);
    RtcSlotEntry *ent;
    if (isNew) {
        ent = (RtcSlotEntry *)ckalloc(sizeof(*ent));
        ent->interp  = interp;
        ent->thread  = thread;
        ent->scripts = (Tcl_Obj **)ckalloc(sizeof(Tcl_Obj *) * (size_t)RTC_SLOT_MAX);
        memset(ent->scripts, 0, sizeof(Tcl_Obj *) * (size_t)RTC_SLOT_MAX);
        Tcl_SetHashValue(he, ent);
    } else {
        ent = (RtcSlotEntry *)Tcl_GetHashValue(he);
        /* Last-writer-wins on (interp, thread). Realistic use is single
         * interp per process, so this is a defensive update. */
        ent->interp = interp;
        ent->thread = thread;
    }
    return ent;
}

/* -- return-value helpers ------------------------------------------ */

static const char *err_code_for(int rc) {
    switch (rc) {
        case -1: return "invalid";
        case -2: return "failure";
        case -3: return "not-avail";
        case -4: return "too-small";
        default: return "rtc";
    }
}

int RtcReturnInt(Tcl_Interp *interp, int rc) {
    if (rc < 0) {
        const char *code = err_code_for(rc);
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("rtc error: %s", code));
        Tcl_SetErrorCode(interp, "RTC", code, (char *)NULL);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
    return TCL_OK;
}

int RtcCmd_OutString(Tcl_Interp *interp,
                     int (*fn)(int, char *, int),
                     int id) {
    int sz = fn(id, NULL, 0);
    if (sz < 0) return RtcReturnInt(interp, sz);
    /* libdatachannel returns the size INCLUDING the NUL terminator. */
    char *buf = (char *)ckalloc((size_t)sz + 1);
    int rc = fn(id, buf, sz);
    if (rc < 0) {
        ckfree(buf);
        return RtcReturnInt(interp, rc);
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, -1));
    ckfree(buf);
    return TCL_OK;
}

/* -- callback registration ----------------------------------------- */

int RtcRegisterCallback(Tcl_Interp *interp,
                        int id, int slot,
                        Tcl_Obj *script,
                        RtcSetterFn setter,
                        void (*trampoline)(void)) {
    EnsureRegistry();

    Tcl_Size slen = 0;
    if (script) (void)Tcl_GetStringFromObj(script, &slen);
    int clearing = (slen == 0);

    /* Hold g_mutex across the setter call so that concurrent
     * registrations can't install trampolines in an order that
     * inverts the script-slot writes. libdatachannel's setters never
     * fire callbacks synchronously, so no deadlock against the
     * trampoline-side acquire. */
    Tcl_Obj *prev = NULL;
    int rc;
    Tcl_MutexLock(&g_mutex);
    RtcSlotEntry *ent = clearing
        ? FindEntry_locked(id)
        : GetOrCreateEntry_locked(id, interp, Tcl_GetCurrentThread());
    if (ent && slot >= 0 && slot < RTC_SLOT_MAX) {
        prev = ent->scripts[slot];
        if (clearing) {
            ent->scripts[slot] = NULL;
        } else {
            Tcl_IncrRefCount(script);
            ent->scripts[slot] = script;
        }
    }
    rc = setter(id, clearing ? NULL : trampoline);
    Tcl_MutexUnlock(&g_mutex);
    if (prev) Tcl_DecrRefCount(prev);

    return RtcReturnInt(interp, rc);
}

/* -- event dispatching ---------------------------------------------- */

typedef struct { Tcl_Event ev; int rtcId; int slot; } EvNoArgs;
typedef struct { Tcl_Event ev; int rtcId; int slot; int i1; } EvInt;
typedef struct { Tcl_Event ev; int rtcId; int slot; char *s1; } EvString;
typedef struct { Tcl_Event ev; int rtcId; int slot; char *s1; char *s2; } EvTwoStr;
typedef struct { Tcl_Event ev; int rtcId; int slot; char *data; int size; } EvBytes;

/* Look up the registered script for (rtcId, slot) under mutex, bumping
 * its refcount. Returns NULL if absent. */
static Tcl_Obj *acquire_script(int rtcId, int slot, Tcl_Interp **out_interp) {
    Tcl_Obj *s = NULL;
    Tcl_MutexLock(&g_mutex);
    RtcSlotEntry *ent = FindEntry_locked(rtcId);
    if (ent && slot >= 0 && slot < RTC_SLOT_MAX) {
        s = ent->scripts[slot];
        if (s) {
            Tcl_IncrRefCount(s);
            if (out_interp) *out_interp = ent->interp;
        }
    }
    Tcl_MutexUnlock(&g_mutex);
    return s;
}

static int eval_with_args(Tcl_Interp *interp, Tcl_Obj *script,
                          int rtcId, Tcl_Obj **extra, int n_extra) {
    Tcl_Obj **prefix;
    Tcl_Size  prefix_n;
    if (Tcl_ListObjGetElements(NULL, script, &prefix_n, &prefix) != TCL_OK) {
        /* Treat the script as a single command word. */
        prefix_n = 1;
        prefix = &script;
    }
    int total = (int)prefix_n + 1 + n_extra;
    Tcl_Obj **argv = (Tcl_Obj **)ckalloc(sizeof(Tcl_Obj *) * (size_t)total);
    for (int i = 0; i < prefix_n; i++) {
        argv[i] = prefix[i];
        Tcl_IncrRefCount(argv[i]);
    }
    argv[prefix_n] = Tcl_NewIntObj(rtcId);
    Tcl_IncrRefCount(argv[prefix_n]);
    for (int i = 0; i < n_extra; i++) {
        argv[prefix_n + 1 + i] = extra[i];
        Tcl_IncrRefCount(argv[prefix_n + 1 + i]);
    }
    int rc = Tcl_EvalObjv(interp, total, argv, TCL_EVAL_GLOBAL);
    if (rc == TCL_ERROR) Tcl_BackgroundError(interp);
    for (int i = 0; i < total; i++) Tcl_DecrRefCount(argv[i]);
    ckfree((char *)argv);
    return rc;
}

static int DispatchNoArgs(Tcl_Event *evPtr, int flags) {
    (void)flags;
    EvNoArgs *e = (EvNoArgs *)evPtr;
    Tcl_Interp *interp = NULL;
    Tcl_Obj *s = acquire_script(e->rtcId, e->slot, &interp);
    if (s && interp) {
        eval_with_args(interp, s, e->rtcId, NULL, 0);
        Tcl_DecrRefCount(s);
    }
    return 1;
}

static int DispatchInt(Tcl_Event *evPtr, int flags) {
    (void)flags;
    EvInt *e = (EvInt *)evPtr;
    Tcl_Interp *interp = NULL;
    Tcl_Obj *s = acquire_script(e->rtcId, e->slot, &interp);
    if (s && interp) {
        Tcl_Obj *args[1] = { Tcl_NewIntObj(e->i1) };
        eval_with_args(interp, s, e->rtcId, args, 1);
        Tcl_DecrRefCount(s);
    }
    return 1;
}

static int DispatchString(Tcl_Event *evPtr, int flags) {
    (void)flags;
    EvString *e = (EvString *)evPtr;
    Tcl_Interp *interp = NULL;
    Tcl_Obj *s = acquire_script(e->rtcId, e->slot, &interp);
    if (s && interp) {
        Tcl_Obj *args[1] = { Tcl_NewStringObj(e->s1 ? e->s1 : "", -1) };
        eval_with_args(interp, s, e->rtcId, args, 1);
        Tcl_DecrRefCount(s);
    }
    if (e->s1) ckfree(e->s1);
    return 1;
}

static int DispatchTwoStr(Tcl_Event *evPtr, int flags) {
    (void)flags;
    EvTwoStr *e = (EvTwoStr *)evPtr;
    Tcl_Interp *interp = NULL;
    Tcl_Obj *s = acquire_script(e->rtcId, e->slot, &interp);
    if (s && interp) {
        Tcl_Obj *args[2] = {
            Tcl_NewStringObj(e->s1 ? e->s1 : "", -1),
            Tcl_NewStringObj(e->s2 ? e->s2 : "", -1)
        };
        eval_with_args(interp, s, e->rtcId, args, 2);
        Tcl_DecrRefCount(s);
    }
    if (e->s1) ckfree(e->s1);
    if (e->s2) ckfree(e->s2);
    return 1;
}

static int DispatchBytes(Tcl_Event *evPtr, int flags) {
    (void)flags;
    EvBytes *e = (EvBytes *)evPtr;
    Tcl_Interp *interp = NULL;
    Tcl_Obj *s = acquire_script(e->rtcId, e->slot, &interp);
    if (s && interp) {
        Tcl_Obj *args[1] = {
            Tcl_NewByteArrayObj((unsigned char *)(e->data ? e->data : ""),
                                e->size)
        };
        eval_with_args(interp, s, e->rtcId, args, 1);
        Tcl_DecrRefCount(s);
    }
    if (e->data) ckfree(e->data);
    return 1;
}

/* Predicate for Tcl_DeleteEvents in RtcUnregisterAllCallbacks: matches
 * any of our events whose rtcId equals *(int*)cd, frees any auxiliary
 * payload (since the dispatch proc that normally frees it will not run
 * when the event is removed), and returns 1 to drop the event. */
static int MatchEventForId(Tcl_Event *ev, void *cd) {
    int target = (int)(intptr_t)cd;
    if (ev->proc == DispatchNoArgs) {
        return ((EvNoArgs *)ev)->rtcId == target;
    } else if (ev->proc == DispatchInt) {
        return ((EvInt *)ev)->rtcId == target;
    } else if (ev->proc == DispatchString) {
        EvString *e = (EvString *)ev;
        if (e->rtcId != target) return 0;
        if (e->s1) ckfree(e->s1);
        return 1;
    } else if (ev->proc == DispatchTwoStr) {
        EvTwoStr *e = (EvTwoStr *)ev;
        if (e->rtcId != target) return 0;
        if (e->s1) ckfree(e->s1);
        if (e->s2) ckfree(e->s2);
        return 1;
    } else if (ev->proc == DispatchBytes) {
        EvBytes *e = (EvBytes *)ev;
        if (e->rtcId != target) return 0;
        if (e->data) ckfree(e->data);
        return 1;
    }
    return 0;
}

void RtcUnregisterAllCallbacks(int id) {
    if (!g_inited) return;

    /* Drain any pending events for this id from the registered thread's
     * queue before tearing down the registry entry. libdatachannel has
     * already promised (via its rtcDelete*) not to fire new callbacks
     * for this id, so once we drain the queue here no event can reach
     * a future entry that recycles the same int id. Tcl_DeleteEvents
     * operates on the current thread's queue only, so this is a no-op
     * if the caller is not the registered thread - that case can't race
     * because dispatch wouldn't run there either. */
    Tcl_DeleteEvents(MatchEventForId, (void *)(intptr_t)id);

    Tcl_Obj **scripts = NULL;
    Tcl_MutexLock(&g_mutex);
    Tcl_HashEntry *he = Tcl_FindHashEntry(&g_registry, (void *)(intptr_t)id);
    if (he) {
        RtcSlotEntry *ent = (RtcSlotEntry *)Tcl_GetHashValue(he);
        scripts = ent->scripts;
        Tcl_DeleteHashEntry(he);
        ckfree(ent);
    }
    Tcl_MutexUnlock(&g_mutex);
    /* Decref outside the mutex - Tcl_DecrRefCount can run arbitrary
     * free hooks if the script is the last reference. */
    if (scripts) {
        for (int i = 0; i < RTC_SLOT_MAX; i++) {
            if (scripts[i]) Tcl_DecrRefCount(scripts[i]);
        }
        ckfree((char *)scripts);
    }
}

/* -- Post helpers --------------------------------------------------- */

static char *xstrdup_ck(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    char *p = (char *)ckalloc(n + 1);
    memcpy(p, s, n + 1);
    return p;
}

static Tcl_ThreadId thread_for(int id) {
    Tcl_ThreadId t = 0;
    Tcl_MutexLock(&g_mutex);
    RtcSlotEntry *ent = FindEntry_locked(id);
    if (ent) t = ent->thread;
    Tcl_MutexUnlock(&g_mutex);
    return t;
}

void RtcEnqueueNoArgs(int rtcId, int slot) {
    Tcl_ThreadId t = thread_for(rtcId);
    if (!t) return;
    EvNoArgs *e = (EvNoArgs *)ckalloc(sizeof(*e));
    e->ev.proc = DispatchNoArgs;
    e->ev.nextPtr = NULL;
    e->rtcId = rtcId;
    e->slot  = slot;
    Tcl_ThreadQueueEvent(t, &e->ev, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(t);
}

void RtcEnqueueInt(int rtcId, int slot, int i1) {
    Tcl_ThreadId t = thread_for(rtcId);
    if (!t) return;
    EvInt *e = (EvInt *)ckalloc(sizeof(*e));
    e->ev.proc = DispatchInt;
    e->ev.nextPtr = NULL;
    e->rtcId = rtcId;
    e->slot  = slot;
    e->i1    = i1;
    Tcl_ThreadQueueEvent(t, &e->ev, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(t);
}

void RtcEnqueueString(int rtcId, int slot, const char *s1) {
    Tcl_ThreadId t = thread_for(rtcId);
    if (!t) return;
    EvString *e = (EvString *)ckalloc(sizeof(*e));
    e->ev.proc = DispatchString;
    e->ev.nextPtr = NULL;
    e->rtcId = rtcId;
    e->slot  = slot;
    e->s1    = xstrdup_ck(s1);
    Tcl_ThreadQueueEvent(t, &e->ev, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(t);
}

void RtcEnqueueTwoStr(int rtcId, int slot, const char *s1, const char *s2) {
    Tcl_ThreadId t = thread_for(rtcId);
    if (!t) return;
    EvTwoStr *e = (EvTwoStr *)ckalloc(sizeof(*e));
    e->ev.proc = DispatchTwoStr;
    e->ev.nextPtr = NULL;
    e->rtcId = rtcId;
    e->slot  = slot;
    e->s1    = xstrdup_ck(s1);
    e->s2    = xstrdup_ck(s2);
    Tcl_ThreadQueueEvent(t, &e->ev, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(t);
}

void RtcEnqueueBytes(int rtcId, int slot, const char *data, int size) {
    Tcl_ThreadId t = thread_for(rtcId);
    if (!t) return;
    EvBytes *e = (EvBytes *)ckalloc(sizeof(*e));
    e->ev.proc = DispatchBytes;
    e->ev.nextPtr = NULL;
    e->rtcId = rtcId;
    e->slot  = slot;
    if (data && size > 0) {
        e->data = (char *)ckalloc((size_t)size);
        memcpy(e->data, data, (size_t)size);
        e->size = size;
    } else {
        e->data = NULL;
        e->size = 0;
    }
    Tcl_ThreadQueueEvent(t, &e->ev, TCL_QUEUE_TAIL);
    Tcl_ThreadAlert(t);
}

/* -- module init --------------------------------------------------- */

DLLEXPORT int Rtc_Init(Tcl_Interp *interp);

static void register_commands(Tcl_Interp *interp) {
    /* Pre-create the namespaces so empty ones (e.g. ::rtc::wsserver
     * before any command is created in it) are still navigable. */
    static const char *namespaces[] = {
        "::rtc", "::rtc::pc", "::rtc::track", "::rtc::dc",
        "::rtc::common", "::rtc::ws", "::rtc::wsserver", NULL
    };
    for (const char **ns = namespaces; *ns; ns++) {
        Tcl_CreateNamespace(interp, *ns, NULL, NULL);
    }
    Tcl_ResetResult(interp);
    for (const RtcCommand *c = RtcGeneratedCommands; c->name; c++) {
        Tcl_CreateObjCommand(interp, c->name, c->proc, NULL, NULL);
    }
    for (const RtcCommand *c = RtcSpecialCommands; c->name; c++) {
        /* Specials override anything the generator emitted under the same name. */
        Tcl_CreateObjCommand(interp, c->name, c->proc, NULL, NULL);
    }
}

int Rtc_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "9.0", 0) == NULL) return TCL_ERROR;
    EnsureRegistry();
    register_commands(interp);
    if (Tcl_PkgProvide(interp, RTC_PKG_NAME, RTC_PACKAGE_VERSION) != TCL_OK) {
        return TCL_ERROR;
    }
    return TCL_OK;
}

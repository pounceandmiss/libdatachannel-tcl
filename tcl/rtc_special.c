/*
 * rtc_special.c - entry points the generator can't handle mechanically.
 *
 * Anything that takes/returns a struct, has in/out parameters, or two
 * out-strings is hand-written here. Generator skips them by name.
 *
 * Currently bound:
 *   ::rtc::pc::new                - rtcCreatePeerConnection (rtcConfiguration)
 *   ::rtc::common::receive-message - rtcReceiveMessage (in/out int *size)
 *   ::rtc::common::send-message   - rtcSendMessage (binary payload)
 *   ::rtc::set-log-level          - rtcInitLogger
 *
 * Pattern-matched cousins that already work through the generator:
 *   set-local/remote-description, add-remote-candidate, get-local-description,
 *   get-remote-description, create-offer/answer, get-local/remote-address,
 *   add-track (SDP-string form), all callback setters, etc.
 */

#include "rtc_runtime.h"

#include <rtc/rtc.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* -- ::rtc::pc::new -------------------------------------------------- */

static int parse_certificate_type(Tcl_Interp *interp, Tcl_Obj *o,
                                  rtcCertificateType *out) {
    static const char *names[] = {"default", "ecdsa", "rsa", NULL};
    int idx;
    if (Tcl_GetIndexFromObj(interp, o, names, "certificate-type", 0, &idx)
        != TCL_OK) return TCL_ERROR;
    *out = (rtcCertificateType)idx;   /* enum values match name index */
    return TCL_OK;
}

static int parse_transport_policy(Tcl_Interp *interp, Tcl_Obj *o,
                                  rtcTransportPolicy *out) {
    static const char *names[] = {"all", "relay", NULL};
    int idx;
    if (Tcl_GetIndexFromObj(interp, o, names, "transport-policy", 0, &idx)
        != TCL_OK) return TCL_ERROR;
    *out = (rtcTransportPolicy)idx;
    return TCL_OK;
}

static int Cmd_pc_new(void *cd, Tcl_Interp *interp, int objc,
                      Tcl_Obj *const objv[]) {
    (void)cd;
    rtcConfiguration cfg = {0};
    /* Defaults match the C struct (zeroed); set the bool defaults
     * explicitly for readability. */
    cfg.certificateType    = RTC_CERTIFICATE_DEFAULT;
    cfg.iceTransportPolicy = RTC_TRANSPORT_POLICY_ALL;

    const char **ice_servers = NULL;
    int          ice_count   = 0;

    for (int i = 1; i < objc; i += 2) {
        if (i + 1 >= objc) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf(
                "option %s requires a value", Tcl_GetString(objv[i])));
            if (ice_servers) ckfree((char *)ice_servers);
            return TCL_ERROR;
        }
        const char *opt = Tcl_GetString(objv[i]);
        Tcl_Obj    *val = objv[i + 1];
        int intval;
        if (strcmp(opt, "-ice-servers") == 0) {
            Tcl_Size  nlist;
            Tcl_Obj **list_items;
            if (Tcl_ListObjGetElements(interp, val, &nlist, &list_items)
                != TCL_OK) goto fail;
            if (ice_servers) ckfree((char *)ice_servers);
            ice_servers = (const char **)ckalloc(sizeof(char *) * (size_t)(nlist + 1));
            for (Tcl_Size j = 0; j < nlist; j++) {
                ice_servers[j] = Tcl_GetString(list_items[j]);
            }
            ice_count = (int)nlist;
            cfg.iceServers      = ice_servers;
            cfg.iceServersCount = ice_count;
        } else if (strcmp(opt, "-proxy-server") == 0) {
            cfg.proxyServer = Tcl_GetString(val);
        } else if (strcmp(opt, "-bind-address") == 0) {
            cfg.bindAddress = Tcl_GetString(val);
        } else if (strcmp(opt, "-certificate-type") == 0) {
            if (parse_certificate_type(interp, val, &cfg.certificateType)
                != TCL_OK) goto fail;
        } else if (strcmp(opt, "-ice-transport-policy") == 0) {
            if (parse_transport_policy(interp, val, &cfg.iceTransportPolicy)
                != TCL_OK) goto fail;
        } else if (strcmp(opt, "-enable-ice-tcp") == 0) {
            if (Tcl_GetBooleanFromObj(interp, val, &intval) != TCL_OK) goto fail;
            cfg.enableIceTcp = (bool)intval;
        } else if (strcmp(opt, "-enable-ice-udp-mux") == 0) {
            if (Tcl_GetBooleanFromObj(interp, val, &intval) != TCL_OK) goto fail;
            cfg.enableIceUdpMux = (bool)intval;
        } else if (strcmp(opt, "-disable-auto-negotiation") == 0) {
            if (Tcl_GetBooleanFromObj(interp, val, &intval) != TCL_OK) goto fail;
            cfg.disableAutoNegotiation = (bool)intval;
        } else if (strcmp(opt, "-force-media-transport") == 0) {
            if (Tcl_GetBooleanFromObj(interp, val, &intval) != TCL_OK) goto fail;
            cfg.forceMediaTransport = (bool)intval;
        } else if (strcmp(opt, "-port-range-begin") == 0) {
            if (Tcl_GetIntFromObj(interp, val, &intval) != TCL_OK) goto fail;
            cfg.portRangeBegin = (uint16_t)intval;
        } else if (strcmp(opt, "-port-range-end") == 0) {
            if (Tcl_GetIntFromObj(interp, val, &intval) != TCL_OK) goto fail;
            cfg.portRangeEnd = (uint16_t)intval;
        } else if (strcmp(opt, "-mtu") == 0) {
            if (Tcl_GetIntFromObj(interp, val, &cfg.mtu) != TCL_OK) goto fail;
        } else if (strcmp(opt, "-max-message-size") == 0) {
            if (Tcl_GetIntFromObj(interp, val, &cfg.maxMessageSize)
                != TCL_OK) goto fail;
        } else {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("unknown option: %s", opt));
            goto fail;
        }
    }

    int pc = rtcCreatePeerConnection(&cfg);
    if (ice_servers) ckfree((char *)ice_servers);
    return RtcReturnInt(interp, pc);

fail:
    if (ice_servers) ckfree((char *)ice_servers);
    return TCL_ERROR;
}

/* -- ::rtc::common::receive-message ---------------------------------- */

static int Cmd_common_receive_message(void *cd, Tcl_Interp *interp, int objc,
                                      Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "id");
        return TCL_ERROR;
    }
    int id;
    if (Tcl_GetIntFromObj(interp, objv[1], &id) != TCL_OK) return TCL_ERROR;

    /* Probe: NULL buffer returns RTC_ERR_SUCCESS with *size set to the
     * required buffer length. Positive = binary byte count; negative =
     * string mode, |*size| includes the trailing NUL. Empty queue
     * returns RTC_ERR_NOT_AVAIL. */
    int sz = 0;
    int rc = rtcReceiveMessage(id, NULL, &sz);
    if (rc == RTC_ERR_NOT_AVAIL) {
        Tcl_SetObjResult(interp, Tcl_NewByteArrayObj(NULL, 0));
        return TCL_OK;
    }
    if (rc < 0) {
        return RtcReturnInt(interp, rc);
    }
    int is_text = (sz < 0);
    int cap = is_text ? -sz : sz;
    if (cap <= 0) {
        Tcl_SetObjResult(interp, is_text
            ? Tcl_NewStringObj("", 0)
            : Tcl_NewByteArrayObj(NULL, 0));
        return TCL_OK;
    }

    char *buf = (char *)ckalloc((size_t)cap);
    sz = cap;   /* libdatachannel abs()'s the input; sign is restored on output */
    rc = rtcReceiveMessage(id, buf, &sz);
    if (rc < 0) {
        ckfree(buf);
        return RtcReturnInt(interp, rc);
    }
    if (sz < 0) {
        int slen = -sz - 1;
        if (slen < 0) slen = 0;
        Tcl_SetObjResult(interp, Tcl_NewStringObj(buf, slen));
    } else {
        Tcl_SetObjResult(interp, Tcl_NewByteArrayObj((unsigned char *)buf, sz));
    }
    ckfree(buf);
    return TCL_OK;
}

/* -- ::rtc::common::send-message ------------------------------------- */
/* Binary-safe: data is read as a byte array so embedded NULs survive.
 * size < 0 selects libdatachannel's null-terminated string path (text
 * frame on websockets, string-mode message on data channels); in that
 * case the byte array is reinterpreted as a C string. size >= 0 sends
 * exactly that many bytes from the byte array. */

static int Cmd_send_message(void *cd, Tcl_Interp *interp, int objc,
                            Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "id data size");
        return TCL_ERROR;
    }
    int id;
    if (Tcl_GetIntFromObj(interp, objv[1], &id) != TCL_OK) return TCL_ERROR;
    int size;
    if (Tcl_GetIntFromObj(interp, objv[3], &size) != TCL_OK) return TCL_ERROR;

    Tcl_Size n = 0;
    const char *data;
    if (size < 0) {
        data = Tcl_GetStringFromObj(objv[2], &n);
    } else {
        data = (const char *)Tcl_GetByteArrayFromObj(objv[2], &n);
        if ((Tcl_Size)size > n) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf(
                "size %d exceeds data length %" TCL_SIZE_MODIFIER "d",
                size, n));
            return TCL_ERROR;
        }
    }
    int rc = rtcSendMessage(id, data, size);
    return RtcReturnInt(interp, rc);
}

/* -- ::rtc::set-log-level -------------------------------------------- */

static int Cmd_set_log_level(void *cd, Tcl_Interp *interp, int objc,
                             Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "level");
        return TCL_ERROR;
    }
    static const char *names[] = {
        "none", "fatal", "error", "warning", "info", "debug", "verbose", NULL
    };
    int idx;
    if (Tcl_GetIndexFromObj(interp, objv[1], names, "log-level", 0, &idx)
        != TCL_OK) return TCL_ERROR;
    rtcInitLogger((rtcLogLevel)idx, NULL);   /* default stderr sink */
    return TCL_OK;
}

/* -- registration --------------------------------------------------- */

const RtcCommand RtcSpecialCommands[] = {
    { "::rtc::pc::new",                 Cmd_pc_new                  },
    { "::rtc::common::receive-message", Cmd_common_receive_message  },
    { "::rtc::common::send-message",    Cmd_send_message            },
    { "::rtc::set-log-level",           Cmd_set_log_level           },
    { NULL, NULL }
};

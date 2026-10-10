#!/bin/bash
set -u

# EC20F call-state synchronizer.
#
# Some EC20F firmware/chan_quectel combinations miss the URCs that mark an
# outgoing call answered or released.  AT+CLCC is authoritative and the
# driver's existing CLCC parser correctly reconciles Dialing -> Active when a
# +CLCC voice record is present.
#
# There is one upstream edge case: when the remote party hangs up, AT+CLCC may
# return only OK (no +CLCC rows).  In that case at_response_clcc() is never
# called, so the old cpvt can remain Active forever.  This helper detects that
# condition from the synchronous AT response and requests hangup of the stale
# Quectel Asterisk channel after a small debounce.

CLCC_SYNC_ENABLED="${QUECTEL_CLCC_SYNC_ENABLED:-yes}"
CLCC_SYNC_INTERVAL="${QUECTEL_CLCC_SYNC_INTERVAL:-1}"
CLCC_EMPTY_LIMIT="${QUECTEL_CLCC_EMPTY_LIMIT:-2}"
CLCC_TIMEOUT_MS="${QUECTEL_CLCC_TIMEOUT_MS:-3000}"

declare -A CLCC_EMPTY_COUNT

log() {
    printf '[SimGo][clcc-sync] %s\n' "$*"
}

hangup_stale_channels() {
    local dev="$1"
    local chan

    while IFS= read -r chan; do
        [ -n "${chan}" ] || continue
        log "${dev}: modem has no voice CLCC; hanging up stale channel ${chan}"
        asterisk -rx "channel request hangup ${chan}" >/dev/null 2>&1 || true
    done < <(
        asterisk -rx "core show channels concise" 2>/dev/null |
            awk -F'!' -v dev="${dev}" 'index($1, "Quectel/" dev "-") == 1 {print $1}'
    )
}

clcc_sync_one() {
    local dev="$1" state="$2"
    local response count

    # Use the synchronous command so we can distinguish a real +CLCC voice
    # record from the EC20F's empty-list response.  The command still passes
    # through chan_quectel's normal parser, preserving Dialing -> Active sync.
    response="$(asterisk -rx "quectel at ${dev} AT+CLCC ${CLCC_TIMEOUT_MS}" 2>/dev/null)" || return 0

    # A timeout/error must never be interpreted as "no calls".
    if ! printf '%s\n' "${response}" | grep -q 'Response for AT command:'; then
        CLCC_EMPTY_COUNT["${dev}"]=0
        return 0
    fi

    # +CLCC: <idx>,<dir>,<stat>,<mode>,... ; mode 0 = voice.
    if printf '%s\n' "${response}" | grep -Eq '\+CLCC:[[:space:]]*[0-9]+,[[:space:]]*[01],[[:space:]]*[0-9]+,[[:space:]]*0,'; then
        CLCC_EMPTY_COUNT["${dev}"]=0
        return 0
    fi

    # Only synthesize release for a channel that the driver already considers
    # Active.  During Dialing/Alerting there can legitimately be a short period
    # before the modem exposes its voice CLCC row.
    if [ "${state}" != "Active" ]; then
        CLCC_EMPTY_COUNT["${dev}"]=0
        return 0
    fi

    count="${CLCC_EMPTY_COUNT["${dev}"]:-0}"
    count=$((count + 1))
    CLCC_EMPTY_COUNT["${dev}"]="${count}"

    if [ "${count}" -ge "${CLCC_EMPTY_LIMIT}" ]; then
        log "${dev}: Active in driver but AT+CLCC has no voice call (${count}/${CLCC_EMPTY_LIMIT})"
        hangup_stale_channels "${dev}"
        CLCC_EMPTY_COUNT["${dev}"]=0
    fi
}

clcc_sync_loop() {
    local dev state

    while true; do
        sleep "${CLCC_SYNC_INTERVAL}"

        # Process substitution keeps the while loop in this shell so the
        # per-device debounce counters persist between iterations.
        while read -r dev state; do
            [ -n "${dev:-}" ] || continue
            case "${state}" in
                Dialing|Alerting|Active|Incoming|Waiting|Releasing)
                    clcc_sync_one "${dev}" "${state}"
                    ;;
                *)
                    CLCC_EMPTY_COUNT["${dev}"]=0
                    ;;
            esac
        done < <(
            asterisk -rx "quectel show devices" 2>/dev/null |
                awk 'NR > 1 && $1 != "" {print $1, $3}'
        )
    done
}

case "${CLCC_SYNC_ENABLED}" in
    1|yes|YES|true|TRUE|on|ON)
        case "${CLCC_SYNC_INTERVAL}" in
            ''|*[!0-9.]*|0|0.0)
                log "invalid QUECTEL_CLCC_SYNC_INTERVAL='${CLCC_SYNC_INTERVAL}', using 1s"
                CLCC_SYNC_INTERVAL=1
                ;;
        esac
        case "${CLCC_EMPTY_LIMIT}" in
            ''|*[!0-9]*|0)
                log "invalid QUECTEL_CLCC_EMPTY_LIMIT='${CLCC_EMPTY_LIMIT}', using 2"
                CLCC_EMPTY_LIMIT=2
                ;;
        esac
        case "${CLCC_TIMEOUT_MS}" in
            ''|*[!0-9]*|0)
                log "invalid QUECTEL_CLCC_TIMEOUT_MS='${CLCC_TIMEOUT_MS}', using 3000"
                CLCC_TIMEOUT_MS=3000
                ;;
        esac
        log "enabled, interval=${CLCC_SYNC_INTERVAL}s empty_limit=${CLCC_EMPTY_LIMIT} timeout=${CLCC_TIMEOUT_MS}ms"
        clcc_sync_loop &
        ;;
    *)
        log "disabled"
        ;;
esac

exec /start.sh "$@"

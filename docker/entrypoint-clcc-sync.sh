#!/bin/bash
set -u

# EC20F call-state synchronizer.
#
# The modem can establish an outgoing voice call while chan_quectel remains in
# Dialing/Alerting until AT+CLCC is requested.  Poll CLCC only during those
# transitional states and use the asynchronous CLI command.  Do not run a
# synchronous CMD_USER CLCC loop while a call is Active: on EC20F a NO CARRIER
# can arrive while that user command owns the AT queue and interfere with call
# teardown / immediate redial.

CLCC_SYNC_ENABLED="${QUECTEL_CLCC_SYNC_ENABLED:-yes}"
CLCC_SYNC_INTERVAL="${QUECTEL_CLCC_SYNC_INTERVAL:-1}"

log() {
    printf '[SimGo][clcc-sync] %s\n' "$*"
}

clcc_sync_loop() {
    local dev state

    while true; do
        sleep "${CLCC_SYNC_INTERVAL}"

        while read -r dev state; do
            [ -n "${dev:-}" ] || continue
            case "${state}" in
                Dialing|Alerting)
                    # Fire-and-forget.  chan_quectel's normal +CLCC parser will
                    # reconcile the cpvt state (for example Dialing -> Active).
                    # Queue contention is harmless here; the next poll retries.
                    asterisk -rx "quectel cmd ${dev} AT+CLCC" >/dev/null 2>&1 || true
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
        log "enabled, async interval=${CLCC_SYNC_INTERVAL}s states=Dialing,Alerting"
        clcc_sync_loop &
        ;;
    *)
        log "disabled"
        ;;
esac

exec /start.sh "$@"

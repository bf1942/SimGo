#!/bin/bash
set -u

# EC20F call-state synchronizer.
#
# Some EC20F firmware/chan_quectel combinations do not deliver (or do not
# parse) the unsolicited call-state transition that marks an outgoing call as
# answered.  The modem is already in a voice call, but chan_quectel can remain
# in Dialing, so Asterisk keeps the PJSIP leg in Ring and never creates the
# full duplex media bridge.  A manual AT+CLCC immediately reconciles the
# driver state.  The same stale state can remain after hangup and make the next
# call fail with cause 44.
#
# Poll AT+CLCC only while chan_quectel reports a live/transitional call state.
# The driver's existing CLCC parser remains the single authority for changing
# cpvt/Asterisk state; this helper does not synthesize call state itself.

CLCC_SYNC_ENABLED="${QUECTEL_CLCC_SYNC_ENABLED:-yes}"
CLCC_SYNC_INTERVAL="${QUECTEL_CLCC_SYNC_INTERVAL:-1}"

log() {
    printf '[SimGo][clcc-sync] %s\n' "$*"
}

clcc_sync_loop() {
    while true; do
        sleep "${CLCC_SYNC_INTERVAL}"

        # Asterisk is unavailable for a short time during startup/restart.
        # Treat that as normal and retry on the next iteration.
        asterisk -rx "quectel show devices" 2>/dev/null \
            | awk 'NR > 1 && $1 != "" {print $1, $3}' \
            | while read -r dev state; do
                case "${state}" in
                    Dialing|Alerting|Active|Incoming|Waiting|Releasing)
                        # Use the exact CLI path proven to make chan_quectel's
                        # CLCC parser transition Dialing -> Active and clear
                        # stale calls after release.
                        asterisk -rx "quectel cmd ${dev} AT+CLCC" >/dev/null 2>&1 || true
                        ;;
                esac
            done
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
        log "enabled, interval=${CLCC_SYNC_INTERVAL}s"
        clcc_sync_loop &
        ;;
    *)
        log "disabled"
        ;;
esac

exec /start.sh "$@"

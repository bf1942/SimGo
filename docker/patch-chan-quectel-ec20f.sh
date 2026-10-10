#!/bin/sh
set -eu

file="${1:-at_response.c}"
tmp="${file}.simgo.tmp"

# Patch EC20F call teardown by semantic location instead of source line numbers.
#
# 1) Remote hangup:
#    EC20F may report only NO CARRIER. Preserve upstream CMD_USER handling, then
#    release the cpvt through CALL_STATE_RELEASED without mutating the AT queue
#    after the release transition.
#
# 2) Local/SIP-side hangup:
#    channel_hangup() queues AT+CHUP and drops the Asterisk channel reference.
#    Some EC20F firmware returns OK but emits no CEND/NO CARRIER afterwards.
#    Upstream only clears CALL_FLAG_NEED_HANGUP on that OK, leaving an orphan
#    Active cpvt that blocks the next call. Treat successful AT+CHUP/CHLD=1x as
#    authoritative and release the cpvt immediately.
awk '
BEGIN {
    in_nc = 0
    replaced_nc = 0
    saw_hangup_reset = 0
    inserted_local_release = 0
}
{
    if (!in_nc && $0 ~ /^[[:space:]]*case RES_NO_CARRIER:/) {
        in_nc = 1
        replaced_nc++

        print "\t\t\tcase RES_NO_CARRIER:"
        print "\t\t\t\tif (ecmd && ecmd->cmd == CMD_USER)"
        print "\t\t\t\t{"
        print "\t\t\t\t\tuser_cmd_sync_complete(pvt, task);"
        print "\t\t\t\t\tuser_cmd_response_emit(pvt, task);"
        print "\t\t\t\t\tat_queue_handle_result(pvt, at_res);"
        print "\t\t\t\t\treturn 0;"
        print "\t\t\t\t}"
        print "\t\t\t\t{"
        print "\t\t\t\t\tstruct cpvt *cpvt = NULL;"
        print ""
        print "\t\t\t\t\t/* SimGo EC20F: safe NO CARRIER release; do not mutate AT queue. */"
        print "\t\t\t\t\tif (task && task->cpvt && task->cpvt != &pvt->sys_chan)"
        print "\t\t\t\t\t\tcpvt = task->cpvt;"
        print "\t\t\t\t\tif (!cpvt && pvt->last_dialed_cpvt)"
        print "\t\t\t\t\t\tcpvt = pvt->last_dialed_cpvt;"
        print "\t\t\t\t\tif (!cpvt)"
        print "\t\t\t\t\t\tcpvt = active_cpvt(pvt);"
        print ""
        print "\t\t\t\t\tast_log(LOG_WARNING, \"[%s] Receive NO CARRIER\\n\", PVT_ID(pvt));"
        print "\t\t\t\t\tpvt->call_estb = 0;"
        print "\t\t\t\t\tif (cpvt)"
        print "\t\t\t\t\t{"
        print "\t\t\t\t\t\tCPVT_RESET_FLAGS(cpvt, CALL_FLAG_NEED_HANGUP);"
        print "\t\t\t\t\t\tchange_channel_state(cpvt, CALL_STATE_RELEASED, 0);"
        print "\t\t\t\t\t}"
        print "\t\t\t\t\treturn 0;"
        print "\t\t\t\t}"
        print ""
        next
    }

    if (in_nc) {
        if ($0 ~ /^[[:space:]]*case RES_CPIN:/) {
            in_nc = 0
            print
        }
        next
    }

    print

    # This reset is unique to the successful CMD_AT_CHUP/CMD_AT_CHLD_1x block
    # in the pinned upstream revision. Insert the release after its debug line
    # so the original cpvt is still available for logging first.
    if ($0 ~ /CPVT_RESET_FLAGS\(task->cpvt, CALL_FLAG_NEED_HANGUP\);/) {
        saw_hangup_reset = 1
        next
    }

    if (saw_hangup_reset && $0 ~ /task->cpvt->call_idx\);/) {
        print ""
        print "\t\t\t\t/* SimGo EC20F: AT+CHUP OK is authoritative for local hangup. */"
        print "\t\t\t\tif (task->cpvt && task->cpvt != &pvt->sys_chan)"
        print "\t\t\t\t{"
        print "\t\t\t\t\tpvt->call_estb = 0;"
        print "\t\t\t\t\tchange_channel_state(task->cpvt, CALL_STATE_RELEASED, 0);"
        print "\t\t\t\t}"
        saw_hangup_reset = 0
        inserted_local_release++
    }
}
END {
    if (replaced_nc != 1) {
        print "SimGo EC20F patch: expected exactly one NO CARRIER handler, replaced " replaced_nc > "/dev/stderr"
        exit 42
    }
    if (inserted_local_release != 1) {
        print "SimGo EC20F patch: expected exactly one local hangup release insertion, inserted " inserted_local_release > "/dev/stderr"
        exit 43
    }
}
' "$file" > "$tmp"

mv "$tmp" "$file"
grep -q 'SimGo EC20F: safe NO CARRIER release; do not mutate AT queue' "$file"
grep -q 'SimGo EC20F: AT+CHUP OK is authoritative for local hangup' "$file"

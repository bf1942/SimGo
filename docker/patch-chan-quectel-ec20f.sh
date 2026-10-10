#!/bin/sh
set -eu

file="${1:-at_response.c}"
tmp="${file}.simgo.tmp"

# Patch the RES_NO_CARRIER handler by semantic location instead of source line
# numbers.
#
# Important ordering rules for EC20F:
# - Preserve upstream CMD_USER handling unchanged. A terminal response owned by
#   a synchronous user command must complete that command and return.
# - For normal modem call teardown, release the cpvt using the same
#   CALL_STATE_RELEASED path used by CEND/RCEND.
# - Do NOT enqueue voice_disable/request_clcc and do NOT call
#   at_queue_handle_result after releasing the cpvt. Enqueuing a command changes
#   the AT queue head, and retiring the result afterwards can remove the wrong
#   task and crash Asterisk.
#
# cpvt selection order covers both an established call and a failed/immediate
# redial still represented by CALL_STATE_INIT:
#   1. current AT task cpvt, unless it is sys_chan
#   2. last_dialed_cpvt
#   3. active_cpvt
awk '
BEGIN { in_nc = 0; replaced = 0 }
{
    if (!in_nc && $0 ~ /^[[:space:]]*case RES_NO_CARRIER:/) {
        in_nc = 1
        replaced++

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
}
END {
    if (replaced != 1) {
        print "SimGo EC20F patch: expected exactly one NO CARRIER handler, replaced " replaced > "/dev/stderr"
        exit 42
    }
}
' "$file" > "$tmp"

mv "$tmp" "$file"
grep -q 'SimGo EC20F: safe NO CARRIER release; do not mutate AT queue' "$file"

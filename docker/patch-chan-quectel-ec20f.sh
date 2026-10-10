#!/bin/sh
set -eu

file="${1:-at_response.c}"
tmp="${file}.simgo.tmp"

# Patch the RES_NO_CARRIER handler by semantic location instead of source line
# numbers.  EC20F may report NO CARRIER while a synchronous/user AT command is
# at the head of the queue.  Upstream handles CMD_USER first and returns, which
# can swallow the call-release event and leave an INIT/Dialing cpvt behind.
#
# Release the call first, choosing the cpvt in this order:
#   1. the current AT task's cpvt (unless it is sys_chan)
#   2. last_dialed_cpvt (covers an orphan CALL_STATE_INIT)
#   3. active_cpvt (normal answered call)
# Then complete/remove the AT queue result.  No extra CLCC is queued here; the
# modem has already authoritatively reported that the carrier is gone.
awk '
BEGIN { in_nc = 0; replaced = 0 }
{
    if (!in_nc && $0 ~ /^[[:space:]]*case RES_NO_CARRIER:/) {
        in_nc = 1
        replaced++

        print "\t\t\tcase RES_NO_CARRIER:"
        print "\t\t\t\t{"
        print "\t\t\t\t\tstruct cpvt *cpvt = NULL;"
        print ""
        print "\t\t\t\t\t/* SimGo EC20F: release call state before CMD_USER handling. */"
        print "\t\t\t\t\tif (task && task->cpvt && task->cpvt != &pvt->sys_chan)"
        print "\t\t\t\t\t\tcpvt = task->cpvt;"
        print "\t\t\t\t\tif (!cpvt && pvt->last_dialed_cpvt)"
        print "\t\t\t\t\t\tcpvt = pvt->last_dialed_cpvt;"
        print "\t\t\t\t\tif (!cpvt)"
        print "\t\t\t\t\t\tcpvt = active_cpvt(pvt);"
        print ""
        print "\t\t\t\t\tast_log(LOG_WARNING, \"[%s] Receive NO CARRIER\\n\", PVT_ID(pvt));"
        print "\t\t\t\t\tpvt->call_estb = 0;"
        print ""
        print "\t\t\t\t\tif (cpvt)"
        print "\t\t\t\t\t{"
        print "\t\t\t\t\t\tif (CPVT_IS_SOUND_SOURCE(cpvt))"
        print "\t\t\t\t\t\t\tvoice_disable(pvt);"
        print "\t\t\t\t\t\tCPVT_RESET_FLAGS(cpvt, CALL_FLAG_NEED_HANGUP);"
        print "\t\t\t\t\t\tchange_channel_state(cpvt, CALL_STATE_RELEASED, 0);"
        print "\t\t\t\t\t}"
        print ""
        print "\t\t\t\t\tif (ecmd && ecmd->cmd == CMD_USER)"
        print "\t\t\t\t\t{"
        print "\t\t\t\t\t\tuser_cmd_sync_complete(pvt, task);"
        print "\t\t\t\t\t\tuser_cmd_response_emit(pvt, task);"
        print "\t\t\t\t\t}"
        print ""
        print "\t\t\t\t\t/* Always retire the command that received NO CARRIER. */"
        print "\t\t\t\t\tat_queue_handle_result(pvt, at_res);"
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
grep -q 'SimGo EC20F: release call state before CMD_USER handling' "$file"

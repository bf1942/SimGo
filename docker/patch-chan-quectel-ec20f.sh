#!/bin/sh
set -eu

file="${1:-at_response.c}"
tmp="${file}.simgo.tmp"

# Patch by semantic location rather than a unified-diff line number. Upstream
# at_response.c has moved between revisions, which made the old .patch brittle.
# This rewrite only touches the RES_NO_CARRIER handler after its log line and
# fails the image build unless exactly one handler is changed.
awk '
BEGIN { in_nc = 0; saw_log = 0; replaced = 0 }
{
    if ($0 ~ /^[[:space:]]*case RES_NO_CARRIER:/) {
        in_nc = 1
    }

    if (in_nc && $0 ~ /Receive NO CARRIER/) {
        saw_log = 1
        print
        next
    }

    if (in_nc && saw_log && $0 ~ /^[[:space:]]*return 0;[[:space:]]*$/) {
        print ""
        print "\t\t\t\t/* SimGo EC20F: remote hangup may only emit NO CARRIER. */"
        print "\t\t\t\t{"
        print "\t\t\t\t\tstruct cpvt *cpvt = active_cpvt(pvt);"
        print "\t\t\t\t\tif (cpvt)"
        print "\t\t\t\t\t{"
        print "\t\t\t\t\t\tif (CPVT_IS_SOUND_SOURCE(cpvt))"
        print "\t\t\t\t\t\t\tvoice_disable(pvt);"
        print "\t\t\t\t\t\tpvt->call_estb = 0;"
        print "\t\t\t\t\t\tCPVT_RESET_FLAGS(cpvt, CALL_FLAG_NEED_HANGUP);"
        print "\t\t\t\t\t\tchange_channel_state(cpvt, CALL_STATE_RELEASED, 0);"
        print "\t\t\t\t\t}"
        print "\t\t\t\t\trequest_clcc(pvt);"
        print "\t\t\t\t}"
        print "\t\t\t\treturn 0;"
        in_nc = 0
        saw_log = 0
        replaced++
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
grep -q 'SimGo EC20F: remote hangup may only emit NO CARRIER' "$file"

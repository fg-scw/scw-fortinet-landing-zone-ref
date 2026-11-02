#!/usr/bin/env bash
# Offline test of fortigate.sh policy: cli and sleep are stubbed, nothing
# leaves the machine. Run: bash modules/hub/test_fortigate.sh
set -u
export FGT_STATE_DIR=$(mktemp -d)
trap 'rm -rf "$FGT_STATE_DIR"' EXIT
. "$(dirname "$0")/fortigate.sh"
set +e

calls=$FGT_STATE_DIR/calls
sleep() { :; }
cli() { # $1 host; answers from MODE_<last octet>, records what was sent
  local in mode
  in=$(cat)
  echo "$1 $(head -1 <<<"$in")" >>"$calls"
  mode=$(eval echo "\${MODE_${1##*.}:-}")
  case "$in" in
  'get system status') echo "Current HA mode: $mode" ;;
  'show firewall policy') printf '    edit %s\n' 1 2 3 4 5 ;;
  esac
}

fails=0
check() { # name, expected, got
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=1; fi
}

export FGT_HOSTS="10.0.6.11=bastion@192.0.2.1:61000 10.0.6.12=bastion@192.0.2.2:61000"
export FGT_CONFIG=$(echo 'config firewall policy' | base64) FGT_POLICY_IDS="1 2 3"

check "jump of fw2" bastion@192.0.2.2:61000 "$(jump 10.0.6.12)"

MODE_11="a-p, secondary" MODE_12="a-p, primary"
: >"$calls"; policy 2>/dev/null
check "push on the primary" 0 $?
check "push before deleting stale ids" "10.0.6.12 config firewall policy|10.0.6.12 show firewall policy|10.0.6.12 config firewall policy" \
  "$(grep -v 'get system status\|diagnose' "$calls" | paste -sd '|' -)"

MODE_11="standalone" MODE_12=""
: >"$calls"; policy 2>/dev/null
check "lone standalone node refused" 1 $?

MODE_11="a-p, primary" MODE_12="a-p, primary"
: >"$calls"; policy 2>/dev/null
check "two primaries refused" 1 $?
check "nothing pushed to a split pair" 0 "$(grep -vc 'get system status' "$calls")"

exit $fails

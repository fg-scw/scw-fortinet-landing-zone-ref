#!/usr/bin/env bash
# FortiGate checks and policy over SSH through a Public Gateway bastion, on the
# management NIC (the firewalls have no public IP). A node configures itself at
# first boot from its cloud-init user data (firewall.tf).
#   fortigate.sh ready    waits for the user data (admin key accepted) and the license,
#                         then checks port <-> MAC (firewall.tf)
#   fortigate.sh policy   pushes the policy and failover automation CLI to the FGCP
#                         primary, which syncs the secondary (policy.tf)
# Inputs come from the environment, never argv, since they carry secrets:
#   ready:  FGT_HOST FGT_JUMP (bastion "bastion@<ip>:<port>") FGT_LICENSED (1|0)
#           FGT_MACS ("port2=<mac> ...")
#   policy: FGT_HOSTS ("<ip>=<bastion> ...", each node through the bastion of
#           its zone) FGT_CONFIG FGT_POLICY_IDS ("1 2 ...")
# The runner needs ssh, the private key of one of admin_ssh_public_keys, and
# an address in admin_cidrs (bastion).
set -euo pipefail

# Host keys: trust on first use, then pinned. Each node has its own
# known_hosts on the runner. ready clears it, since a rebuilt node keeps its IP
# with a new key. Later connections must match. Files live in a private per-user
# directory across runs, never under fixed names in a shared /tmp.
umask 077
STATE=${FGT_STATE_DIR:-$HOME/.cache/landing-zone-fortigate}
mkdir -p "$STATE"
[ -O "$STATE" ] && chmod 700 "$STATE" || { echo "$STATE is not owned by $(id -un)" >&2; exit 1; }
kh() { echo "$STATE/known_hosts-$1"; }
jump() { # $1 host; its bastion from FGT_HOSTS, else FGT_JUMP
  local e
  for e in ${FGT_HOSTS:-}; do [ "${e%%=*}" = "$1" ] && { echo "${e#*=}"; return; }; done
  echo "$FGT_JUMP"
}
cfg() { # $1 host; writes and prints its ssh config
  local f="$STATE/ssh-$1" j b
  j=$(jump "$1") b=${j%:*}
  cat >"$f" <<EOC
Host bastion
  HostName ${b#*@}
  User ${b%@*}
  Port ${j##*:}
  ProxyJump none
  UserKnownHostsFile $(kh bastion)
Host *
  ProxyJump bastion
  UserKnownHostsFile $(kh "$1")
  StrictHostKeyChecking accept-new
  LogLevel ERROR
  ConnectTimeout 10
  ServerAliveInterval 5
  ServerAliveCountMax 3
EOC
  echo "$f"
}
# FortiOS output for a refused CLI line. The session goes on, so this output is the only signal.
CLI_ERRORS='Command fail|Unknown action|command parse error|value parse error|entry not found|node_check_object fail|object check operator error|Attribute .* MUST be set'

# Terraform hides the output of provisioners handling secrets, so keep a log per node on the runner.
log() { echo "$(date +%T) fortigate.sh [${FGT_HOST:-policy}] $*" | tee -a "$STATE/${FGT_HOST:-policy}.log" >&2; }

cli() { # $1 host; CLI on stdin; prints the output, fails on a refused line
  local out
  out=$(ssh -F "$(cfg "$1")" -o BatchMode=yes "admin@$1" 2>&1 | tr -d '\r') || true
  printf '%s\n' "$out"
  if grep -E -q "$CLI_ERRORS" <<<"$out"; then
    log "CLI refused: $(grep -E -B3 "$CLI_ERRORS" <<<"$out" | tr '\n' ' ')"
    return 1
  fi
}

# grep must read all cli output (no -q): with pipefail, an early exit fails the pipeline on SIGPIPE.

# ConnectTimeout only bounds the bastion leg: a rebooting node can hang, hence the deadline.
status() { # $1 host; `get system status`, empty until the admin key is accepted
  local f="$STATE/status-$1"
  : >"$f"
  ssh -F "$(cfg "$1")" -o BatchMode=yes "admin@$1" 'get system status' >"$f" 2>/dev/null &
  local p=$!
  { sleep 20; kill "$p" 2>/dev/null; } &
  wait "$p" 2>/dev/null || true
  tr -d '\r' <"$f"
}

check_macs() { # $1 host; FGT_MACS "port2=<mac> ..."
  local m port want got
  for m in $FGT_MACS; do
    port=${m%=*} want=${m#*=}
    got=$(cli "$1" <<<"diagnose hardware deviceinfo nic $port" | sed -n 's/^Permanent Hwaddr:[[:space:]]*//p' | tr 'A-F' 'a-f')
    if [ "$got" != "$want" ]; then
      log "$port has MAC '$got', expected $want (PCI order changed?): policy not pushed"
      return 1
    fi
  done
}

# A standalone node is never primary: the pair did not form a cluster.
is_primary() { cli "$1" <<<'get system status' | grep -E 'Current HA mode: a-p, (primary|master)' >/dev/null; }

ready() {
  local h=$FGT_HOST
  # A rebuilt node and its rebuilt Public Gateway (which may reuse an old public IP) present new host keys.
  rm -f "$(kh "$h")"
  local j b; j=$(jump "$h"); b=${j%:*}
  ssh-keygen -R "[${b#*@}]:${j##*:}" -f "$(kh bastion)" >/dev/null 2>&1 || true
  log "waiting for the user data (admin key accepted)"
  for _ in $(seq 90); do
    status "$h" | grep 'Version:' >/dev/null && break
    sleep 10
  done
  status "$h" | grep 'Version:' >/dev/null || {
    log "admin key never accepted: user data not applied (console: diagnose debug cloudinit show)"
    return 1
  }
  if [ "$FGT_LICENSED" = 1 ]; then
    log "waiting for the licence"
    for _ in $(seq 60); do
      status "$h" | grep 'License Status: Valid' >/dev/null && break
      sleep 10
    done
    status "$h" | grep 'License Status: Valid' >/dev/null || { log "licence still not valid"; return 1; }
  fi
  check_macs "$h"
  # Clear the cloud-init log, which holds the user data CLI and its passwords.
  cli "$h" <<<'diagnose debug cloudinit clear' >/dev/null
  log "done"
}

primaries() { # the nodes of FGT_HOSTS that say they are the FGCP primary
  local e
  for e in $FGT_HOSTS; do is_primary "${e%%=*}" && echo "${e%%=*}"; done
  return 0
}

policy() {
  local primary=
  # A rebuilt node rejoining triggers a re-election, so the primary may not answer for a while.
  # Wait for exactly one: with two, the pair never formed a cluster and a push reaches one node only.
  for _ in $(seq 20); do
    primary=$(primaries)
    [ "$(wc -l <<<"$primary")" -eq 1 ] && [ -n "$primary" ] && break
    sleep 15
  done
  [ "$(wc -l <<<"$primary")" -eq 1 ] && [ -n "$primary" ] ||
    { log "need exactly one primary, got: ${primary:-none} (cluster not formed?)"; return 1; }
  FGT_HOST=$primary
  log "pushing policy"
  base64 -d <<<"$FGT_CONFIG" | cli "$primary" >/dev/null
  # Policy ids are positions 1..N. Delete the ids the new policy no longer has, after the push,
  # so a failed push never leaves a partial policy.
  local stale
  stale=$(cli "$primary" <<<'show firewall policy' | sed -n 's/^ *edit \([0-9]*\)$/\1/p' |
    grep -v -x -F -f <(tr ' ' '\n' <<<"$FGT_POLICY_IDS") || true)
  if [ -n "$stale" ]; then
    { echo 'config firewall policy'; for i in $stale; do echo "delete $i"; done; echo end; } | cli "$primary" >/dev/null
  fi
  # The automation starts after the first election: align the data VIPs now, and again once
  # a redeployed container with new NIC MACs is live.
  cli "$primary" <<<'diagnose automation test lz-ipam-reconcile' >/dev/null
  sleep 30
  cli "$primary" <<<'diagnose automation test lz-ipam-reconcile' >/dev/null
  log "done"
}

# Sourced (tests): functions only.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
ready | policy) "$1" ;;
*) echo "usage: $0 ready|policy" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# FortiGate checks and policy over SSH through a Public Gateway bastion, on
# the management NIC of the node (no public IP on the firewalls). A node
# configures itself at first boot from its cloud-init user data (firewall.tf).
#   fortigate.sh ready    a new node: waits for its user data to be applied (admin key accepted)
#                         and its licence, checks port <-> MAC (firewall.tf)
#   fortigate.sh policy   policy and failover automation CLI on the FGCP
#                         primary, which syncs the secondary (policy.tf)
# Inputs come from the environment, never argv (secrets):
#   all:    FGT_JUMP (bastion "bastion@<ip>:<port>")
#   ready:  FGT_HOST FGT_LICENSED (1|0) FGT_MACS ("port2=<mac> ...")
#   policy: FGT_HOSTS ("<ip> <ip>") FGT_CONFIG FGT_POLICY_IDS ("1 2 ...")
# The runner needs ssh, the private key of one of admin_ssh_public_keys, and
# an address in admin_cidrs (bastion).
set -euo pipefail

# Host keys: trust on first use, then pinned. Each node has its own
# known_hosts on the runner; ready starts it afresh (a rebuilt node has
# a new key on the same IP), every later connection must match it. One ssh
# config per node carries the bastion. They live in a private per-user
# directory, kept between runs (pinned keys), never under fixed names in a
# shared /tmp.
umask 077
STATE=${FGT_STATE_DIR:-$HOME/.cache/landing-zone-fortigate}
mkdir -p "$STATE"
[ -O "$STATE" ] && chmod 700 "$STATE" || { echo "$STATE is not owned by $(id -un)" >&2; exit 1; }
kh() { echo "$STATE/known_hosts-$1"; }
cfg() { # $1 host; writes and prints its ssh config
  local f="$STATE/ssh-$1" b=${FGT_JUMP%:*}
  cat >"$f" <<EOC
Host bastion
  HostName ${b#*@}
  User ${b%@*}
  Port ${FGT_JUMP##*:}
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
# What FortiOS prints when a CLI line is refused; the session goes on, so the
# output is the only way to notice.
CLI_ERRORS='Command fail|Unknown action|command parse error|value parse error|entry not found|node_check_object fail|object check operator error|Attribute .* MUST be set'

# Terraform hides the output of a provisioner that gets secrets: also keep
# a log per node on the runner.
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

# grep after cli reads all its input: with pipefail, grep -q would stop at the
# first match and fail the pipeline on the writer's SIGPIPE.

# Through the bastion, ConnectTimeout only bounds the bastion leg: a call to
# a rebooting node can hang, so it gets its own deadline.
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

is_primary() { cli "$1" <<<'get system status' | grep -E 'Current HA mode: (a-p, (primary|master)|standalone)' >/dev/null; }

ready() {
  local h=$FGT_HOST
  # A rebuilt node has a new host key on the same IP.
  rm -f "$(kh "$h")"
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
  # The cloud-init log holds the user data CLI, passwords included.
  cli "$h" <<<'diagnose debug cloudinit clear' >/dev/null
  log "done"
}

policy() {
  local h primary=
  for h in $FGT_HOSTS; do is_primary "$h" && { primary=$h; break; }; done
  [ -n "$primary" ] || { log "no primary among $FGT_HOSTS"; return 1; }
  FGT_HOST=$primary
  # Policy ids are positions: drop the ids the new policy no longer has.
  local stale
  stale=$(cli "$primary" <<<'show firewall policy' | sed -n 's/^ *edit \([0-9]*\)$/\1/p' |
    grep -v -x -F -f <(tr ' ' '\n' <<<"$FGT_POLICY_IDS") || true)
  if [ -n "$stale" ]; then
    { echo 'config firewall policy'; for i in $stale; do echo "delete $i"; done; echo end; } | cli "$primary" >/dev/null
  fi
  log "pushing policy"
  base64 -d <<<"$FGT_CONFIG" | cli "$primary" >/dev/null
  # The first election precedes the automation: align the data VIPs now,
  # and again once a function redeployed with new NIC MACs is live.
  cli "$primary" <<<'diagnose automation test lz-ipam-reconcile' >/dev/null
  sleep 30
  cli "$primary" <<<'diagnose automation test lz-ipam-reconcile' >/dev/null
  log "done"
}

case "${1:-}" in
ready | policy) "$1" ;;
*) echo "usage: $0 ready|policy" >&2; exit 2 ;;
esac

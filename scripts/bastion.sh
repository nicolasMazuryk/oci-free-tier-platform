# Bastion session helpers (source after lib.sh). Sets SSH_OPTS / TARGET for a VM.
SSH_KEY="${SSH_KEY:-$HOME/.ssh/oci_core}"
KNOWN_HOSTS="$HOME/.ssh/known_hosts_oci_core"
CACHE_DIR="$HOME/.cache/oci-core"; mkdir -p "$CACHE_DIR"
REGION="${REGION:-uk-london-1}"

vm_ip() { case "$1" in cloud) echo "${CLOUD_IP:-10.0.2.10}";; ops) echo "${OPS_IP:-10.0.2.20}";; *) die "VM must be cloud|ops";; esac; }

core_compartment() {
  local c="$CACHE_DIR/core-compartment"
  [[ -s $c ]] || oci iam compartment list --compartment-id "$TF_VAR_tenancy_ocid" --name core \
      --lifecycle-state ACTIVE --query 'data[0].id' --raw-output > "$c"
  cat "$c"
}

bastion_id() {
  oci bastion bastion list --compartment-id "$(core_compartment)" --name core-bastion \
    --bastion-lifecycle-state ACTIVE --all --query 'data[0].id' --raw-output
}

# session_for <vm> -> prints an ACTIVE port-forwarding session id to <vm>:22 (reused or new)
session_for() {
  local vm="$1" ip cache sid state bid
  ip="$(vm_ip "$vm")"; cache="$CACHE_DIR/session-$vm"
  if [[ -s $cache ]]; then
    sid="$(cat "$cache")"
    state="$(oci bastion session get --session-id "$sid" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    if [[ $state == ACTIVE ]]; then
      local created ttl now
      read -r created ttl < <(oci bastion session get --session-id "$sid" \
        --query 'data.["time-created","session-ttl-in-seconds"]' --raw-output | jq -r '"\(.[0]) \(.[1])"')
      now=$(date -u +%s)
      created=$(python3 -c "import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()))" "$created")
      if (( created + ttl - now > 600 )); then echo "$sid"; return; fi
    fi
  fi
  bid="$(bastion_id)"; [[ -n $bid && $bid != null ]] || die "core-bastion not found (is the core layer applied?)"
  log "creating Bastion port-forwarding session to $vm ($ip:22)"
  sid="$(oci bastion session create-port-forwarding --bastion-id "$bid" \
    --display-name "core-ssh-$vm-$(whoami)" --ssh-public-key-file "$SSH_KEY.pub" \
    --target-private-ip "$ip" --target-port 22 --session-ttl 10800 \
    --wait-for-state SUCCEEDED --wait-for-state FAILED --max-wait-seconds 300 2>/dev/null \
    --query 'data.resources[0].identifier' --raw-output)"
  [[ $sid == ocid1.bastionsession* ]] || die "session creation failed: $sid"
  session_wait_ready "$sid" "$ip"
  echo "$sid" > "$cache"; echo "$sid"
}

# session_wait_ready <sid> <ip>: a new session reports ACTIVE before the Bastion host accepts its key, so the first
# connection fails with "Permission denied (publickey)". Retry a no-op ssh through it for up to ~30 s.
session_wait_ready() {
  local sid="$1" ip="$2" i
  for i in 1 2 3 4 5 6; do
    ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -o "UserKnownHostsFile=$KNOWN_HOSTS" -o LogLevel=ERROR -o ConnectTimeout=10 \
      -o "ProxyCommand=ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o LogLevel=ERROR -W %h:%p -p 22 $sid@host.bastion.$REGION.oci.oraclecloud.com" \
      "ubuntu@$ip" true </dev/null >/dev/null 2>&1 && return 0
    (( i < 6 )) && { log "Bastion session not accepting the key yet: retry $i/5 in 5 s"; sleep 5; }
  done
  log "Bastion session still refuses the key after ~30 s: continuing (the next command may fail)"
}

# ssh_opts <vm> -> fills SSH_OPTS array and TARGET
ssh_opts() {
  local vm="$1" sid ip
  sid="$(session_for "$vm")"; ip="$(vm_ip "$vm")"
  local proxy="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o ServerAliveInterval=30 -W %h:%p -p 22 $sid@host.bastion.$REGION.oci.oraclecloud.com"
  SSH_OPTS=(-i "$SSH_KEY" -o "ProxyCommand=$proxy" -o StrictHostKeyChecking=accept-new
            -o "UserKnownHostsFile=$KNOWN_HOSTS" -o ServerAliveInterval=30 -o ConnectTimeout=30)
  TARGET="ubuntu@$ip"
}

# ssh_config <vm> -> writes a per-VM ssh config, sets SSH_CFG and SSH_HOST (for rsync/scp)
ssh_config() {
  local vm="$1" sid ip
  sid="$(session_for "$vm")"; ip="$(vm_ip "$vm")"
  SSH_CFG="$CACHE_DIR/ssh_config-$vm"; SSH_HOST="core-$vm"
  cat > "$SSH_CFG" <<CFG
Host core-$vm
  HostName $ip
  User ubuntu
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile $KNOWN_HOSTS
  ServerAliveInterval 30
  ConnectTimeout 30
  LogLevel ERROR
  ProxyCommand ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KNOWN_HOSTS -o LogLevel=ERROR -W %h:%p -p 22 $sid@host.bastion.$REGION.oci.oraclecloud.com
CFG
}

#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage:
  rotate-node-pki.sh [--compose-file FILE] [--min-days DAYS] [--restore] \
    [--allow-ca-change] \
    NEW_NODE_PKI_DIR INSTALLED_PKI_DIR NODE=IP

Install a validated leaf-certificate bundle and recreate the affected services.
Run on one cluster node at a time. --allow-ca-change is reserved for the guarded
scripts/rotate-node-ca.sh wrapper.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  if [[ ${rotation_started:-false} == true ]]; then
    printf 'Previous files are in %s\n' "$backup_dir" >&2
  fi
  exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
compose_file="$script_dir/../compose.yml"
min_days=30
restore=false
allow_ca_change=false
while [[ ${1:-} == --* ]]; do
  case $1 in
    --compose-file)
      [[ $# -ge 2 ]] || die '--compose-file requires a value'
      compose_file=$2
      shift 2
      ;;
    --min-days)
      [[ $# -ge 2 ]] || die '--min-days requires a value'
      min_days=$2
      shift 2
      ;;
    --restore)
      restore=true
      min_days=0
      shift
      ;;
    --allow-ca-change)
      allow_ca_change=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ $restore == false ]] || min_days=0

[[ $# -eq 3 ]] || {
  usage >&2
  exit 2
}

for command in cmp curl date docker grep install mv readlink stat; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done
[[ -f $compose_file ]] || die "Compose file not found: $compose_file"
compose_dir=$(cd "$(dirname "$compose_file")" && pwd -P)
compose_file="$compose_dir/$(basename "$compose_file")"
env_file="$compose_dir/.env"
[[ -f $env_file ]] || die "Compose environment file not found: $env_file"

new_dir=${1%/}
pki_dir=${2%/}
identity=$3
[[ -d $new_dir ]] || die "new node PKI directory not found: $new_dir"
[[ -d $pki_dir ]] || die "installed PKI directory not found: $pki_dir"
new_dir=$(cd "$new_dir" && pwd -P)
pki_dir=$(cd "$pki_dir" && pwd -P)
[[ $new_dir != "$pki_dir" ]] || die 'new and installed PKI directories are the same'
directory_mode=$(stat -c '%a' "$new_dir")
directory_mode=${directory_mode: -3}
[[ $directory_mode =~ ^[0-7]{3}$ ]] || die "could not read permissions on $new_dir"
(( (8#$directory_mode & 077) == 0 )) || \
  die "staged PKI directory must not be accessible by group or others: $new_dir"
[[ $identity == *=* ]] || die "invalid node identity '$identity'; expected NODE=IP"
node=${identity%%=*}
ip=${identity#*=}

compose=(docker compose --project-directory "$compose_dir" --env-file "$env_file" --file "$compose_file")
"${compose[@]}" config --quiet
compose_environment=$("${compose[@]}" config --environment)

compose_value() {
  local wanted=$1 key value result='' found=false
  while IFS='=' read -r key value; do
    if [[ $key == "$wanted" ]]; then
      [[ $found == false ]] || die "duplicate $wanted in effective Compose environment"
      result=$value
      found=true
    fi
  done <<<"$compose_environment"
  [[ $found == true && -n $result ]] || die "$wanted is empty or absent from the effective Compose environment"
  printf '%s\n' "$result"
}

effective_node=$(compose_value NODE_NAME)
effective_ip=$(compose_value NODE_IP)
effective_pki=$(compose_value PKI_DIR)
[[ $effective_node == "$node" ]] || \
  die "node identity mismatch: command names $node, Compose names $effective_node"
[[ $effective_ip == "$ip" ]] || \
  die "node address mismatch: command uses $ip, Compose uses $effective_ip"
if [[ $effective_pki != /* ]]; then
  effective_pki="$compose_dir/$effective_pki"
fi
[[ -d $effective_pki ]] || die "effective Compose PKI directory not found: $effective_pki"
effective_pki=$(cd "$effective_pki" && pwd -P)
[[ $effective_pki == "$pki_dir" ]] || \
  die "installed PKI mismatch: command uses $pki_dir, Compose mounts $effective_pki"

"$script_dir/validate-node-pki.sh" --min-days "$min_days" "$new_dir" "$identity"
ca_changed=false
if ! cmp -s "$new_dir/ca.crt" "$pki_dir/ca.crt"; then
  [[ $allow_ca_change == true ]] || \
    die 'ca.crt differs; use the CA rotation playbook'
  ca_changed=true
fi

docker inspect etcd >/dev/null 2>&1 || die 'etcd container not found'
docker inspect spilo >/dev/null 2>&1 || die 'spilo container not found'
docker inspect haproxy >/dev/null 2>&1 || die 'HAProxy container not found'

for container in etcd spilo; do
  running_hostname=$(docker inspect --format '{{.Config.Hostname}}' "$container")
  [[ $running_hostname == "$effective_node" ]] || \
    die "$container hostname $running_hostname does not match effective node $effective_node"
done
etcd_arguments=$(docker inspect --format '{{range .Args}}{{println .}}{{end}}' etcd)
grep -Fxq -- "--listen-peer-urls=https://$effective_ip:2380" <<<"$etcd_arguments" || \
  die "running etcd does not listen on effective node address $effective_ip"

assert_mount_source() {
  local container=$1 destination=$2 expected=$3 actual
  actual=$(docker inspect --format \
    "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{println .Source}}{{end}}{{end}}" \
    "$container")
  [[ -n $actual ]] || die "$container does not mount $destination"
  actual=$(readlink -f -- "$actual") || die "cannot resolve $container mount source: $actual"
  expected=$(readlink -f -- "$expected") || die "cannot resolve expected PKI file: $expected"
  [[ $actual == "$expected" ]] || \
    die "$container mounts $actual at $destination, expected $expected"
}

assert_mount_source etcd /etc/etcd/pki/ca.crt "$pki_dir/ca.crt"
assert_mount_source etcd /etc/etcd/pki/node.crt "$pki_dir/node.crt"
assert_mount_source etcd /etc/etcd/pki/node.key "$pki_dir/node.key"
assert_mount_source spilo /run/pki/ca.crt "$pki_dir/ca.crt"
assert_mount_source spilo /run/pki/node.crt "$pki_dir/node.crt"
assert_mount_source spilo /run/pki/node.key "$pki_dir/node.key"
assert_mount_source spilo /run/pki/patroni.crt "$pki_dir/patroni.crt"
assert_mount_source spilo /run/pki/patroni.key "$pki_dir/patroni.key"
assert_mount_source haproxy /etc/haproxy/pki/ca.crt "$pki_dir/ca.crt"
if docker inspect alloy >/dev/null 2>&1; then
  assert_mount_source alloy /etc/alloy/pki/ca.crt "$pki_dir/ca.crt"
  assert_mount_source alloy /etc/alloy/pki/monitoring.crt "$pki_dir/monitoring.crt"
  assert_mount_source alloy /etc/alloy/pki/monitoring.key "$pki_dir/monitoring.key"
fi

if [[ $restore == false ]]; then
  docker exec spilo patronictl -c /home/postgres/postgres.yml list >/dev/null 2>&1 || \
    die 'Patroni is not healthy before rotation'
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_dir="${pki_dir}.backup-$timestamp"
[[ ! -e $backup_dir ]] || die "backup already exists: $backup_dir"
install -d -m 0700 "$backup_dir"

files=(ca.crt node.crt node.key patroni.crt patroni.key monitoring.crt monitoring.key)
for file in "${files[@]}"; do
  [[ -f $pki_dir/$file ]] || die "missing installed file: $pki_dir/$file"
  install -m 0644 "$pki_dir/$file" "$backup_dir/$file"
done

rotation_started=true
rotation_failed() {
  local status=$?
  trap - ERR
  if [[ ${rotation_started:-false} == true ]]; then
    printf 'error: rotation stopped; previous files are in %s\n' "$backup_dir" >&2
    printf 'Restore with this helper\x27s --restore option after correcting the problem.\n' >&2
  fi
  exit "$status"
}
trap rotation_failed ERR

for file in "${files[@]}"; do
  temporary="$pki_dir/.${file}.new.$$"
  install -m 0644 "$new_dir/$file" "$temporary"
  mv -f -- "$temporary" "$pki_dir/$file"
done

wait_running() {
  local container=$1
  for _ in {1..30}; do
    [[ $(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null) == true ]] && return 0
    sleep 1
  done
  return 1
}

wait_patroni() {
  for _ in {1..60}; do
    if docker exec spilo patronictl -c /home/postgres/postgres.yml list >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

printf 'Recreating etcd...\n'
"${compose[@]}" up --detach --no-deps --force-recreate etcd
wait_running etcd || die 'etcd did not start within 30 seconds'
etcd_metrics=$(curl --fail --silent --show-error \
  --connect-timeout 5 \
  --max-time 10 \
  --cacert "$pki_dir/ca.crt" \
  --cert "$pki_dir/monitoring.crt" \
  --key "$pki_dir/monitoring.key" \
  "https://$ip:2379/metrics")
grep -Eq '^etcd_server_has_leader[[:space:]]+1([.]0+)?$' <<<"$etcd_metrics" || \
  die 'etcd is running without a cluster leader'
wait_patroni || die 'Patroni could not reach the DCS after etcd rotation'

printf 'Recreating Spilo...\n'
"${compose[@]}" up --detach --no-deps --force-recreate spilo
wait_running spilo || die 'Spilo did not start within 30 seconds'
wait_patroni || die 'Patroni did not become healthy within 120 seconds'
curl --fail --silent --show-error \
  --connect-timeout 5 \
  --max-time 10 \
  --cacert "$pki_dir/ca.crt" \
  --output /dev/null \
  "https://$ip:8008/health"

if [[ $ca_changed == true ]]; then
  printf 'Recreating HAProxy...\n'
  "${compose[@]}" up --detach --no-deps --force-recreate haproxy
  wait_running haproxy || die 'HAProxy did not start within 30 seconds'
fi

if docker inspect alloy >/dev/null 2>&1; then
  printf 'Recreating Alloy...\n'
  "${compose[@]}" up --detach --no-deps --force-recreate alloy
  wait_running alloy || die 'Alloy did not start within 30 seconds'
fi

rotation_started=false
trap - ERR
printf 'Rotation for %s completed. Previous files: %s\n' "$node" "$backup_dir"

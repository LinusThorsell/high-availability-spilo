#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

CURRENT_MIN_DAYS=30

usage() {
  cat <<'EOF'
Usage:
  prepare-ca-rotation.sh CURRENT_PKI_DIR NEXT_PKI_DIR OUTPUT_DIR \
    NODE=IP [NODE=IP ...]

Build the three bundles used by the planned CA rotation playbook.
CURRENT_PKI_DIR must match the deployed certificates. NEXT_PKI_DIR must be a
fresh generate-pki.sh output with a different CA. OUTPUT_DIR must not exist.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

certificate_count() {
  grep -c -- '-----BEGIN CERTIFICATE-----' "$1"
}

common_name() {
  local subject
  subject=$(openssl x509 -in "$1" -subject -noout -nameopt RFC2253)
  subject=${subject#subject=}
  if [[ $subject =~ (^|,)CN=([^,]*) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

validate_ca() {
  local certificate=$1 label=$2 min_days=$3
  local seconds=$((min_days * 86400))

  [[ $(certificate_count "$certificate") -eq 1 ]] || die "$label must contain exactly one CA certificate"
  openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || die "$label is not a certificate"
  openssl verify -CAfile "$certificate" "$certificate" >/dev/null 2>&1 || die "$label is not self-consistent"
  openssl x509 -in "$certificate" -checkend "$seconds" -noout >/dev/null || \
    die "$label expires within $min_days days"
  openssl x509 -in "$certificate" -text -noout | grep -Fq 'CA:TRUE' || die "$label is not a CA"
}

validate_admin_pair() {
  local directory=$1 name=$2 expected_cn=$3 min_days=$4
  local certificate="$directory/$name.crt" key="$directory/$name.key"
  local seconds=$((min_days * 86400)) subject_cn

  [[ -f $certificate ]] || die "missing $certificate"
  [[ -f $key ]] || die "missing $key"
  openssl verify -CAfile "$directory/ca.crt" "$certificate" >/dev/null 2>&1 || \
    die "$certificate is not signed by ca.crt"
  openssl x509 -in "$certificate" -checkend "$seconds" -noout >/dev/null || \
    die "$certificate expires within $min_days days"
  openssl pkey -in "$key" -check -noout >/dev/null 2>&1 || die "$key is invalid"
  openssl x509 -in "$certificate" -pubkey -noout >"$scratch_dir/$name.cert.pub"
  openssl pkey -in "$key" -pubout >"$scratch_dir/$name.key.pub"
  cmp -s "$scratch_dir/$name.cert.pub" "$scratch_dir/$name.key.pub" || \
    die "$certificate does not match its key"
  subject_cn=$(common_name "$certificate")
  [[ $subject_cn == "$expected_cn" ]] || die "$certificate Common Name is not $expected_cn"
  openssl x509 -in "$certificate" -purpose -noout | grep -Fxq 'SSL client : Yes' || \
    die "$certificate lacks client authentication usage"
  openssl x509 -in "$certificate" -purpose -noout | grep -Fxq 'SSL server : No' || \
    die "$certificate unexpectedly permits server authentication"
}

install_stage() {
  local target=$1 source=$2 ca_file=$3

  install -d -m 0700 "$target" "$target/admin" "$target/nodes"
  install -m 0644 "$ca_file" "$target/ca.crt"
  install -m 0644 "$ca_file" "$target/admin/ca.crt"
  install -m 0644 "$source/admin/etcd-root.crt" "$target/admin/etcd-root.crt"
  install -m 0600 "$source/admin/etcd-root.key" "$target/admin/etcd-root.key"
  install -m 0644 "$source/admin/patroni-operator.crt" "$target/admin/patroni-operator.crt"
  install -m 0600 "$source/admin/patroni-operator.key" "$target/admin/patroni-operator.key"

  for name in "${node_names[@]}"; do
    source_node="$source/nodes/$name"
    target_node="$target/nodes/$name"
    install -d -m 0700 "$target_node"
    install -m 0644 "$ca_file" "$target_node/ca.crt"
    for file in node.crt node.key patroni.crt patroni.key monitoring.crt monitoring.key; do
      install -m 0644 "$source_node/$file" "$target_node/$file"
    done
  done
}

[[ $# -ge 4 ]] || {
  usage >&2
  exit 2
}

for command in cmp grep install mktemp openssl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_dir=$(cd "$script_dir/.." && pwd -P)
current_dir=${1%/}
next_dir=${2%/}
output_dir=${3%/}
shift 3

[[ -d $current_dir ]] || die "current PKI directory not found: $current_dir"
[[ -d $next_dir ]] || die "next PKI directory not found: $next_dir"
current_dir=$(cd "$current_dir" && pwd -P)
next_dir=$(cd "$next_dir" && pwd -P)
[[ $current_dir != "$next_dir" ]] || die 'current and next PKI directories are the same'
[[ -n $output_dir && $output_dir != / ]] || die 'refusing an unsafe output path'
[[ ! -e $output_dir ]] || die "$output_dir already exists"
[[ -d $(dirname "$output_dir") ]] || die "parent directory does not exist: $(dirname "$output_dir")"

declare -a node_names=() node_ips=()
declare -A seen_names=()
for identity in "$@"; do
  [[ $identity == *=* ]] || die "invalid node identity '$identity'; expected NODE=IP"
  name=${identity%%=*}
  ip=${identity#*=}
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid node name '$name'"
  [[ -z ${seen_names[$name]:-} ]] || die "duplicate node name '$name'"
  seen_names[$name]=1
  node_names+=("$name")
  node_ips+=("$ip")
done

work_dir=$(mktemp -d "${output_dir}.tmp.XXXXXX")
final_dir="$work_dir/output"
scratch_dir="$work_dir/scratch"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
umask 077
install -d -m 0700 "$final_dir" "$scratch_dir"

for directory in "$current_dir" "$next_dir"; do
  [[ -f $directory/ca.crt ]] || die "missing $directory/ca.crt"
  [[ -d $directory/admin ]] || die "missing $directory/admin"
done
[[ -f $next_dir/ca.key ]] || die "missing $next_dir/ca.key; NEXT_PKI_DIR must be a complete new PKI"

validate_ca "$current_dir/ca.crt" 'current ca.crt' "$CURRENT_MIN_DAYS"
validate_ca "$next_dir/ca.crt" 'next ca.crt' 825
openssl pkey -in "$next_dir/ca.key" -check -noout >/dev/null 2>&1 || die 'next ca.key is invalid'
openssl x509 -in "$next_dir/ca.crt" -pubkey -noout >"$scratch_dir/next-ca.cert.pub"
openssl pkey -in "$next_dir/ca.key" -pubout >"$scratch_dir/next-ca.key.pub"
cmp -s "$scratch_dir/next-ca.cert.pub" "$scratch_dir/next-ca.key.pub" || \
  die 'next ca.crt does not match next ca.key'
old_fingerprint=$(openssl x509 -in "$current_dir/ca.crt" -fingerprint -sha256 -noout)
new_fingerprint=$(openssl x509 -in "$next_dir/ca.crt" -fingerprint -sha256 -noout)
[[ $old_fingerprint != "$new_fingerprint" ]] || die 'current and next CAs are identical'

for directory in "$current_dir" "$next_dir"; do
  cmp -s "$directory/ca.crt" "$directory/admin/ca.crt" || \
    die "$directory/admin/ca.crt does not match its root ca.crt"
done
validate_admin_pair "$current_dir/admin" etcd-root root "$CURRENT_MIN_DAYS"
validate_admin_pair "$current_dir/admin" patroni-operator patroni-operator "$CURRENT_MIN_DAYS"
validate_admin_pair "$next_dir/admin" etcd-root root 30
validate_admin_pair "$next_dir/admin" patroni-operator patroni-operator 30

for index in "${!node_names[@]}"; do
  name=${node_names[$index]}
  ip=${node_ips[$index]}
  for directory in "$current_dir" "$next_dir"; do
    [[ -d $directory/nodes/$name ]] || die "missing $directory/nodes/$name"
    cmp -s "$directory/ca.crt" "$directory/nodes/$name/ca.crt" || \
      die "$directory/nodes/$name/ca.crt does not match its root ca.crt"
  done
  "$repo_dir/scripts/validate-node-pki.sh" --min-days "$CURRENT_MIN_DAYS" \
    "$current_dir/nodes/$name" "$name=$ip" >/dev/null
  "$repo_dir/scripts/validate-node-pki.sh" --min-days 30 "$next_dir/nodes/$name" "$name=$ip" >/dev/null
done

combined_ca="$scratch_dir/combined-ca.crt"
{
  awk '1' "$current_dir/ca.crt"
  printf '\n'
  awk '1' "$next_dir/ca.crt"
} >"$combined_ca"
chmod 0644 "$combined_ca"

install_stage "$final_dir/01-trust-both" "$current_dir" "$combined_ca"
install_stage "$final_dir/02-new-leaves" "$next_dir" "$combined_ca"
install_stage "$final_dir/03-new-ca-only" "$next_dir" "$next_dir/ca.crt"

validate_admin_pair "$final_dir/01-trust-both/admin" etcd-root root "$CURRENT_MIN_DAYS"
validate_admin_pair "$final_dir/01-trust-both/admin" patroni-operator patroni-operator "$CURRENT_MIN_DAYS"
for stage in 02-new-leaves 03-new-ca-only; do
  validate_admin_pair "$final_dir/$stage/admin" etcd-root root 30
  validate_admin_pair "$final_dir/$stage/admin" patroni-operator patroni-operator 30
done

{
  printf 'old_ca_sha256=%s\n' "${old_fingerprint#*=}"
  printf 'new_ca_sha256=%s\n' "${new_fingerprint#*=}"
  printf 'nodes='
  printf '%s ' "${node_names[@]}"
  printf '\n'
} >"$final_dir/manifest.txt"
chmod 0644 "$final_dir/manifest.txt"

for index in "${!node_names[@]}"; do
  name=${node_names[$index]}
  ip=${node_ips[$index]}
  "$repo_dir/scripts/validate-node-pki.sh" --min-days "$CURRENT_MIN_DAYS" \
    "$final_dir/01-trust-both/nodes/$name" "$name=$ip" >/dev/null
  "$repo_dir/scripts/validate-node-pki.sh" --min-days 30 \
    "$final_dir/02-new-leaves/nodes/$name" "$name=$ip" >/dev/null
  "$repo_dir/scripts/validate-node-pki.sh" --min-days 30 \
    "$final_dir/03-new-ca-only/nodes/$name" "$name=$ip" >/dev/null
done

mv -- "$final_dir" "$output_dir"
cleanup
trap - EXIT

printf 'CA rotation bundles created at %s\n' "$output_dir"
printf 'Old: %s\nNew: %s\n' "${old_fingerprint#*=}" "${new_fingerprint#*=}"

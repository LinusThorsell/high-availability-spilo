#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

LEAF_DAYS=825

usage() {
  cat <<'EOF'
Usage:
  renew-pki.sh EXISTING_PKI_DIR OUTPUT_DIR NODE=IP [NODE=IP ...]

EXISTING_PKI_DIR must contain ca.crt and ca.key. The script reuses that CA,
creates new leaf keys and certificates, and writes a fresh bundle to OUTPUT_DIR.
OUTPUT_DIR must not exist. Run this on the secured CA workstation.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

valid_ipv4() {
  local address=$1 octet
  local -a octets

  IFS=. read -r -a octets <<<"$address"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

make_key() {
  openssl genpkey -quiet -algorithm RSA \
    -pkeyopt rsa_keygen_bits:3072 \
    -out "$1"
}

sign_certificate() {
  local common_name=$1 key=$2 certificate=$3 usage=$4 san=${5:-}
  local csr extension_file subject serial

  csr=$(mktemp "$scratch_dir/request.XXXXXX.csr")
  extension_file=$(mktemp "$scratch_dir/extensions.XXXXXX.cnf")
  subject='/O=high-availability-spilo'
  [[ -z $common_name ]] || subject+="/CN=$common_name"
  serial="0x$(openssl rand -hex 16)"

  openssl req -new -sha256 -key "$key" -out "$csr" -subj "$subject"

  {
    printf '%s\n' 'basicConstraints=critical,CA:FALSE'
    printf '%s\n' 'keyUsage=critical,digitalSignature,keyEncipherment'
    printf 'extendedKeyUsage=%s\n' "$usage"
    [[ -z $san ]] || printf 'subjectAltName=%s\n' "$san"
    printf '%s\n' 'subjectKeyIdentifier=hash'
    printf '%s\n' 'authorityKeyIdentifier=keyid,issuer'
  } >"$extension_file"

  openssl x509 -req -sha256 -days "$LEAF_DAYS" \
    -in "$csr" \
    -CA "$source_dir/ca.crt" \
    -CAkey "$source_dir/ca.key" \
    -set_serial "$serial" \
    -extfile "$extension_file" \
    -out "$certificate" >/dev/null
}

[[ $# -ge 3 ]] || {
  usage >&2
  exit 2
}

for command in cmp install mktemp openssl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

source_dir=${1%/}
output_dir=${2%/}
shift 2

[[ -d $source_dir ]] || die "PKI directory not found: $source_dir"
source_dir=$(cd "$source_dir" && pwd -P)
[[ -f $source_dir/ca.crt ]] || die "missing $source_dir/ca.crt"
[[ -f $source_dir/ca.key ]] || die "missing $source_dir/ca.key"
[[ -n $output_dir && $output_dir != / ]] || die 'refusing an unsafe output path'
[[ ! -e $output_dir ]] || die "$output_dir already exists"
[[ -d $(dirname "$output_dir") ]] || die "parent directory does not exist: $(dirname "$output_dir")"

declare -a node_names=() node_ips=()
declare -A seen_names=() seen_ips=()
for node in "$@"; do
  [[ $node == *=* ]] || die "invalid node '$node'; expected NODE=IP"
  name=${node%%=*}
  ip=${node#*=}
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid node name '$name'"
  valid_ipv4 "$ip" || die "invalid IPv4 address '$ip'"
  [[ -z ${seen_names[$name]:-} ]] || die "duplicate node name '$name'"
  [[ -z ${seen_ips[$ip]:-} ]] || die "duplicate node address '$ip'"
  seen_names[$name]=1
  seen_ips[$ip]=1
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
install -d -m 0700 "$final_dir" "$final_dir/admin" "$final_dir/nodes" "$scratch_dir"

openssl x509 -in "$source_dir/ca.crt" -noout >/dev/null 2>&1 || die 'invalid CA certificate'
openssl pkey -in "$source_dir/ca.key" -check -noout >/dev/null 2>&1 || die 'invalid CA private key'
openssl x509 -in "$source_dir/ca.crt" -pubkey -noout >"$scratch_dir/cert.pub"
openssl pkey -in "$source_dir/ca.key" -pubout >"$scratch_dir/key.pub"
cmp -s "$scratch_dir/cert.pub" "$scratch_dir/key.pub" || die 'CA certificate and key do not match'
openssl verify -CAfile "$source_dir/ca.crt" "$source_dir/ca.crt" >/dev/null 2>&1 || die 'CA is not self-consistent'
openssl x509 -checkend "$((LEAF_DAYS * 86400))" -noout -in "$source_dir/ca.crt" >/dev/null || \
  die "CA expires before the new $LEAF_DAYS-day leaf certificates; rotate the CA first"

install -m 0644 "$source_dir/ca.crt" "$final_dir/ca.crt"
install -m 0644 "$source_dir/ca.crt" "$final_dir/admin/ca.crt"

printf 'Issuing administrator certificates...\n'
make_key "$final_dir/admin/etcd-root.key"
sign_certificate root \
  "$final_dir/admin/etcd-root.key" \
  "$final_dir/admin/etcd-root.crt" \
  clientAuth

make_key "$final_dir/admin/patroni-operator.key"
sign_certificate patroni-operator \
  "$final_dir/admin/patroni-operator.key" \
  "$final_dir/admin/patroni-operator.crt" \
  clientAuth

for index in "${!node_names[@]}"; do
  name=${node_names[$index]}
  ip=${node_ips[$index]}
  node_dir="$final_dir/nodes/$name"
  install -d -m 0700 "$node_dir"
  install -m 0644 "$source_dir/ca.crt" "$node_dir/ca.crt"

  printf 'Issuing certificates for %s (%s)...\n' "$name" "$ip"
  make_key "$node_dir/node.key"
  sign_certificate "etcd-$name" \
    "$node_dir/node.key" \
    "$node_dir/node.crt" \
    serverAuth,clientAuth \
    "DNS:$name,DNS:localhost,IP:$ip,IP:127.0.0.1"

  make_key "$node_dir/patroni.key"
  # etcd's gRPC gateway rejects client certificates with a Common Name.
  sign_certificate '' \
    "$node_dir/patroni.key" \
    "$node_dir/patroni.crt" \
    clientAuth

  make_key "$node_dir/monitoring.key"
  sign_certificate monitoring \
    "$node_dir/monitoring.key" \
    "$node_dir/monitoring.crt" \
    clientAuth

  chmod 0644 "$node_dir"/*.key
done

chmod 0600 "$final_dir/admin"/*.key
chmod 0644 "$final_dir"/*.crt "$final_dir/admin"/*.crt "$final_dir/nodes"/*/*.crt

for certificate in "$final_dir/admin"/*.crt "$final_dir/nodes"/*/*.crt; do
  [[ ${certificate##*/} == ca.crt ]] && continue
  openssl verify -CAfile "$source_dir/ca.crt" "$certificate" >/dev/null
done

mv -- "$final_dir" "$output_dir"
cleanup
trap - EXIT

printf '\nRenewal bundle created at %s\n' "$output_dir"
printf 'It contains no CA private key. Validate and rotate one node at a time.\n'

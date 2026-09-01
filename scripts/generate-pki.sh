#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  generate-pki.sh OUTPUT_DIR NODE=IP [NODE=IP ...]

Example:
  ./scripts/generate-pki.sh /secure/spilo-pki \
    n1=10.0.1.2 n2=10.0.1.3 n3=10.0.1.4

OUTPUT_DIR must not already exist. Keep OUTPUT_DIR/ca.key and the admin
directory off the database nodes; distribute only nodes/NODE/* to each node.
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
  local target=$1
  openssl genpkey -quiet -algorithm RSA \
    -pkeyopt rsa_keygen_bits:3072 \
    -out "$target"
}

sign_certificate() {
  local common_name=$1 key=$2 certificate=$3 usage=$4 san=${5:-}
  local csr extension_file

  csr=$(mktemp "$scratch_dir/request.XXXXXX.csr")
  extension_file=$(mktemp "$scratch_dir/extensions.XXXXXX.cnf")

  openssl req -new -sha256 -key "$key" -out "$csr" \
    -subj "/O=high-availability-spilo/CN=$common_name"

  {
    printf '%s\n' 'basicConstraints=critical,CA:FALSE'
    printf '%s\n' 'keyUsage=critical,digitalSignature,keyEncipherment'
    printf 'extendedKeyUsage=%s\n' "$usage"
    [[ -z $san ]] || printf 'subjectAltName=%s\n' "$san"
    printf '%s\n' 'subjectKeyIdentifier=hash'
    printf '%s\n' 'authorityKeyIdentifier=keyid,issuer'
  } >"$extension_file"

  openssl x509 -req -sha256 -days 825 \
    -in "$csr" \
    -CA "$final_dir/ca.crt" \
    -CAkey "$final_dir/ca.key" \
    -CAserial "$scratch_dir/ca.srl" \
    -CAcreateserial \
    -extfile "$extension_file" \
    -out "$certificate" >/dev/null
}

[[ $# -ge 2 ]] || {
  usage >&2
  exit 2
}

for command in openssl mktemp install; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

output_dir=${1%/}
shift
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
install -d -m 0700 "$final_dir" "$scratch_dir"

printf 'Generating cluster CA...\n'
openssl genpkey -quiet -algorithm RSA \
  -pkeyopt rsa_keygen_bits:4096 \
  -out "$final_dir/ca.key"
openssl req -x509 -new -sha256 -days 3650 \
  -key "$final_dir/ca.key" \
  -subj '/O=high-availability-spilo/CN=high-availability-spilo CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out "$final_dir/ca.crt"

install -d -m 0700 "$final_dir/admin" "$final_dir/nodes"
install -m 0644 "$final_dir/ca.crt" "$final_dir/admin/ca.crt"

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
  install -m 0644 "$final_dir/ca.crt" "$node_dir/ca.crt"

  printf 'Generating certificates for %s (%s)...\n' "$name" "$ip"
  make_key "$node_dir/node.key"
  sign_certificate "etcd-$name" \
    "$node_dir/node.key" \
    "$node_dir/node.crt" \
    serverAuth,clientAuth \
    "DNS:$name,DNS:localhost,IP:$ip,IP:127.0.0.1"

  make_key "$node_dir/patroni.key"
  sign_certificate patroni \
    "$node_dir/patroni.key" \
    "$node_dir/patroni.crt" \
    clientAuth

  make_key "$node_dir/monitoring.key"
  sign_certificate monitoring \
    "$node_dir/monitoring.key" \
    "$node_dir/monitoring.crt" \
    clientAuth

  # Containers use different unprivileged UIDs. The enclosing directory remains
  # owner-only on the host, while Compose mounts only the keys each service needs.
  chmod 0644 "$node_dir"/*.key
done

chmod 0600 "$final_dir/ca.key" "$final_dir/admin"/*.key
chmod 0644 "$final_dir"/*.crt "$final_dir/admin"/*.crt "$final_dir/nodes"/*/*.crt

mv -- "$final_dir" "$output_dir"
cleanup
trap - EXIT

printf '\nPKI created at %s\n' "$output_dir"
printf 'Keep ca.key and admin/ offline. Copy only nodes/NODE/* to that NODE.\n'

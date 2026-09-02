#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage:
  validate-node-pki.sh [--min-days DAYS] NODE_PKI_DIR NODE=IP

Validate a node bundle before installation. The default minimum remaining
lifetime is 30 days.
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

has_purpose() {
  local certificate=$1 purpose=$2 expected=$3
  openssl x509 -in "$certificate" -purpose -noout | grep -Fxq "$purpose : $expected"
}

common_name() {
  local subject
  subject=$(openssl x509 -in "$1" -subject -noout -nameopt RFC2253)
  subject=${subject#subject=}
  if [[ $subject =~ (^|,)CN=([^,]*) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

check_pair() {
  local certificate=$1 key=$2 label=$3

  openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || die "$label is not a certificate"
  openssl pkey -in "$key" -check -noout >/dev/null 2>&1 || die "$label private key is invalid"
  openssl verify -CAfile "$pki_dir/ca.crt" "$certificate" >/dev/null 2>&1 || \
    die "$label is not signed by ca.crt"
  openssl x509 -checkend "$min_seconds" -noout -in "$certificate" >/dev/null || \
    die "$label expires within $min_days days"

  openssl x509 -in "$certificate" -pubkey -noout >"$scratch_dir/$label.cert.pub"
  openssl pkey -in "$key" -pubout >"$scratch_dir/$label.key.pub"
  cmp -s "$scratch_dir/$label.cert.pub" "$scratch_dir/$label.key.pub" || \
    die "$label does not match its private key"
}

min_days=30
if [[ ${1:-} == --min-days ]]; then
  [[ $# -ge 2 ]] || die '--min-days requires a value'
  min_days=$2
  shift 2
fi

[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}
[[ $min_days =~ ^[0-9]+$ ]] || die '--min-days must be a non-negative integer'
((min_days <= 36500)) || die '--min-days is unreasonably large'
min_seconds=$((min_days * 86400))

for command in cmp grep mktemp openssl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

pki_dir=${1%/}
identity=$2
[[ $identity == *=* ]] || die "invalid node identity '$identity'; expected NODE=IP"
node=${identity%%=*}
ip=${identity#*=}
[[ $node =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid node name '$node'"
valid_ipv4 "$ip" || die "invalid IPv4 address '$ip'"
[[ -d $pki_dir ]] || die "node PKI directory not found: $pki_dir"
pki_dir=$(cd "$pki_dir" && pwd -P)

for file in ca.crt node.crt node.key patroni.crt patroni.key monitoring.crt monitoring.key; do
  [[ -f $pki_dir/$file ]] || die "missing $pki_dir/$file"
done

scratch_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "$scratch_dir"
}
trap cleanup EXIT

openssl x509 -in "$pki_dir/ca.crt" -noout >/dev/null 2>&1 || die 'ca.crt is not a certificate'
openssl verify -CAfile "$pki_dir/ca.crt" "$pki_dir/ca.crt" >/dev/null 2>&1 || \
  die 'ca.crt is not self-consistent'
openssl x509 -checkend "$min_seconds" -noout -in "$pki_dir/ca.crt" >/dev/null || \
  die "ca.crt expires within $min_days days"

check_pair "$pki_dir/node.crt" "$pki_dir/node.key" node.crt
check_pair "$pki_dir/patroni.crt" "$pki_dir/patroni.key" patroni.crt
check_pair "$pki_dir/monitoring.crt" "$pki_dir/monitoring.key" monitoring.crt

subject_cn=$(common_name "$pki_dir/node.crt")
[[ $subject_cn == "etcd-$node" ]] || die "node.crt Common Name is not etcd-$node"
for host in "$node" localhost; do
  openssl x509 -in "$pki_dir/node.crt" -checkhost "$host" -noout >/dev/null 2>&1 || \
    die "node.crt is missing DNS SAN $host"
done
for address in "$ip" 127.0.0.1; do
  openssl x509 -in "$pki_dir/node.crt" -checkip "$address" -noout >/dev/null 2>&1 || \
    die "node.crt is missing IP SAN $address"
done
has_purpose "$pki_dir/node.crt" 'SSL client' Yes || die 'node.crt lacks client authentication usage'
has_purpose "$pki_dir/node.crt" 'SSL server' Yes || die 'node.crt lacks server authentication usage'

subject_cn=$(common_name "$pki_dir/patroni.crt")
[[ -z $subject_cn ]] || die 'patroni.crt must not contain a Common Name'
has_purpose "$pki_dir/patroni.crt" 'SSL client' Yes || die 'patroni.crt lacks client authentication usage'
has_purpose "$pki_dir/patroni.crt" 'SSL server' No || die 'patroni.crt unexpectedly permits server authentication'

subject_cn=$(common_name "$pki_dir/monitoring.crt")
[[ $subject_cn == monitoring ]] || die 'monitoring.crt Common Name is not monitoring'
has_purpose "$pki_dir/monitoring.crt" 'SSL client' Yes || die 'monitoring.crt lacks client authentication usage'
has_purpose "$pki_dir/monitoring.crt" 'SSL server' No || die 'monitoring.crt unexpectedly permits server authentication'

for certificate in ca.crt node.crt patroni.crt monitoring.crt; do
  expiry=$(openssl x509 -in "$pki_dir/$certificate" -enddate -noout)
  printf '%-15s %s\n' "$certificate" "${expiry#notAfter=}"
done
printf 'Node bundle for %s is valid.\n' "$node"

#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

ROTATION_MIN_DAYS=30

usage() {
  cat <<'EOF'
Usage:
  rotate-node-ca.sh [--check] [--new-ca-sha256 FINGERPRINT] \
    PHASE STAGED_NODE_PKI_DIR INSTALLED_PKI_DIR NODE=IP

PHASE is trust, leaves, final, or restore. This wrapper verifies the expected CA
and leaf transition before calling scripts/rotate-node-pki.sh.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

certificate_count() {
  grep -c -- '-----BEGIN CERTIFICATE-----' "$1"
}

extract_certificate() {
  local bundle=$1 wanted=$2 output=$3
  awk -v wanted="$wanted" '
    /-----BEGIN CERTIFICATE-----/ { count++ }
    count == wanted { print }
    /-----END CERTIFICATE-----/ && count == wanted { exit }
  ' "$bundle" >"$output"
  [[ -s $output ]] || die "certificate $wanted not found in $bundle"
}

same_leaf_files() {
  local left=$1 right=$2
  for file in node.crt node.key patroni.crt patroni.key monitoring.crt monitoring.key; do
    cmp -s "$left/$file" "$right/$file" || return 1
  done
}

check_only=false
expected_new_fingerprint=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --check)
      check_only=true
      shift
      ;;
    --new-ca-sha256)
      [[ $# -ge 2 ]] || die '--new-ca-sha256 requires a value'
      expected_new_fingerprint=${2//:/}
      expected_new_fingerprint=${expected_new_fingerprint,,}
      shift 2
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

[[ $# -eq 4 ]] || {
  usage >&2
  exit 2
}

for command in awk cmp grep mktemp openssl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

phase=$1
staged_dir=${2%/}
installed_dir=${3%/}
identity=$4
case $phase in
  trust|leaves|final|restore) ;;
  *) die "invalid phase '$phase'; expected trust, leaves, final, or restore" ;;
esac
if [[ $phase != restore ]]; then
  [[ $expected_new_fingerprint =~ ^[0-9a-f]{64}$ ]] || \
    die '--new-ca-sha256 must be the approved 32-byte fingerprint from manifest.txt'
fi
[[ -d $staged_dir ]] || die "staged PKI directory not found: $staged_dir"
[[ -d $installed_dir ]] || die "installed PKI directory not found: $installed_dir"
staged_dir=$(cd "$staged_dir" && pwd -P)
installed_dir=$(cd "$installed_dir" && pwd -P)
[[ $staged_dir != "$installed_dir" ]] || die 'staged and installed directories are the same'

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
repo_dir=$(cd "$script_dir/.." && pwd -P)
if [[ $phase != restore ]]; then
  "$repo_dir/scripts/validate-node-pki.sh" --min-days "$ROTATION_MIN_DAYS" \
    "$installed_dir" "$identity" >/dev/null
fi
if [[ $phase == restore ]]; then
  staged_min_days=0
else
  staged_min_days=$ROTATION_MIN_DAYS
fi
"$repo_dir/scripts/validate-node-pki.sh" --min-days "$staged_min_days" \
  "$staged_dir" "$identity" >/dev/null

scratch_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "$scratch_dir"
}
trap cleanup EXIT

if [[ $phase != restore ]]; then
  installed_count=$(certificate_count "$installed_dir/ca.crt")
  staged_count=$(certificate_count "$staged_dir/ca.crt")
fi

case $phase in
  trust)
    [[ $installed_count -eq 1 && $staged_count -eq 2 ]] || \
      die 'trust phase requires one installed root and a two-root staged bundle'
    extract_certificate "$staged_dir/ca.crt" 1 "$scratch_dir/staged-old.crt"
    extract_certificate "$staged_dir/ca.crt" 2 "$scratch_dir/staged-new.crt"
    cmp -s "$installed_dir/ca.crt" "$scratch_dir/staged-old.crt" || \
      die 'the first staged root is not the installed root'
    ! cmp -s "$scratch_dir/staged-old.crt" "$scratch_dir/staged-new.crt" || \
      die 'the staged roots are identical'
    new_ca_file="$scratch_dir/staged-new.crt"
    same_leaf_files "$installed_dir" "$staged_dir" || \
      die 'trust phase must not change leaf certificates or keys'
    ;;
  leaves)
    [[ $installed_count -eq 2 && $staged_count -eq 2 ]] || \
      die 'leaves phase requires two-root installed and staged bundles'
    cmp -s "$installed_dir/ca.crt" "$staged_dir/ca.crt" || \
      die 'leaves phase must not change the trust bundle'
    for file in node.crt patroni.crt monitoring.crt; do
      ! cmp -s "$installed_dir/$file" "$staged_dir/$file" || \
        die "leaves phase did not replace $file"
    done
    extract_certificate "$staged_dir/ca.crt" 2 "$scratch_dir/staged-new.crt"
    new_ca_file="$scratch_dir/staged-new.crt"
    ;;
  final)
    [[ $installed_count -eq 2 && $staged_count -eq 1 ]] || \
      die 'final phase requires two installed roots and one staged root'
    extract_certificate "$installed_dir/ca.crt" 2 "$scratch_dir/installed-new.crt"
    cmp -s "$scratch_dir/installed-new.crt" "$staged_dir/ca.crt" || \
      die 'final phase is not retaining the new root'
    new_ca_file="$staged_dir/ca.crt"
    same_leaf_files "$installed_dir" "$staged_dir" || \
      die 'final phase must not change leaf certificates or keys'
    ;;
  restore)
    ;;
esac

if [[ $phase != restore ]]; then
  actual_new_fingerprint=$(openssl x509 -in "$new_ca_file" -fingerprint -sha256 -noout)
  actual_new_fingerprint=${actual_new_fingerprint#*=}
  actual_new_fingerprint=${actual_new_fingerprint//:/}
  actual_new_fingerprint=${actual_new_fingerprint,,}
  [[ $actual_new_fingerprint == "$expected_new_fingerprint" ]] || \
    die 'new CA fingerprint does not match the approved fingerprint'
fi

printf '%s transition for %s is valid.\n' "$phase" "${identity%%=*}"
[[ $check_only == false ]] || exit 0

arguments=()
case $phase in
  trust|final)
    arguments+=(--allow-ca-change)
    ;;
  restore)
    arguments+=(--allow-ca-change --restore)
    ;;
esac
exec "$repo_dir/scripts/rotate-node-pki.sh" "${arguments[@]}" \
  "$staged_dir" "$installed_dir" "$identity"

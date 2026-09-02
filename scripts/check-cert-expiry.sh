#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage:
  check-cert-expiry.sh [--warning-days DAYS] [--critical-days DAYS] PATH [...]

Check certificate files or every *.crt below a directory. Defaults: warning at
90 days and critical at 30 days. Exit status is 0, 1, 2, or 3 for OK, warning,
critical, or an invalid input/certificate.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 3
}

warning_days=90
critical_days=30
while [[ ${1:-} == --* ]]; do
  case $1 in
    --warning-days)
      [[ $# -ge 2 ]] || die '--warning-days requires a value'
      warning_days=$2
      shift 2
      ;;
    --critical-days)
      [[ $# -ge 2 ]] || die '--critical-days requires a value'
      critical_days=$2
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

[[ $# -ge 1 ]] || {
  usage >&2
  exit 3
}
[[ $warning_days =~ ^[0-9]+$ ]] || die '--warning-days must be a non-negative integer'
[[ $critical_days =~ ^[0-9]+$ ]] || die '--critical-days must be a non-negative integer'
((warning_days <= 36500 && critical_days <= 36500)) || die 'day thresholds are unreasonably large'
((warning_days >= critical_days)) || die '--warning-days must be at least --critical-days'
for command in find openssl; do
  command -v "$command" >/dev/null 2>&1 || die "$command is required"
done

declare -a certificates=()
for path in "$@"; do
  if [[ -f $path ]]; then
    certificates+=("$path")
  elif [[ -d $path ]]; then
    while IFS= read -r -d '' certificate; do
      certificates+=("$certificate")
    done < <(find "$path" -type f -name '*.crt' -print0)
  else
    printf 'UNKNOWN  %s (not found)\n' "$path" >&2
    exit_code=3
  fi
done

exit_code=${exit_code:-0}
if [[ ${#certificates[@]} -eq 0 ]]; then
  printf 'UNKNOWN  no certificates found\n' >&2
  exit 3
fi

warning_seconds=$((warning_days * 86400))
critical_seconds=$((critical_days * 86400))
for certificate in "${certificates[@]}"; do
  if ! expiry=$(openssl x509 -in "$certificate" -enddate -noout 2>/dev/null); then
    printf 'UNKNOWN  %s (invalid certificate)\n' "$certificate"
    exit_code=3
  elif ! openssl x509 -in "$certificate" -checkend 0 -noout >/dev/null; then
    printf 'CRITICAL %-40s expired %s\n' "$certificate" "${expiry#notAfter=}"
    ((exit_code < 2)) && exit_code=2
  elif ! openssl x509 -in "$certificate" -checkend "$critical_seconds" -noout >/dev/null; then
    printf 'CRITICAL %-40s expires %s\n' "$certificate" "${expiry#notAfter=}"
    ((exit_code < 2)) && exit_code=2
  elif ! openssl x509 -in "$certificate" -checkend "$warning_seconds" -noout >/dev/null; then
    printf 'WARNING  %-40s expires %s\n' "$certificate" "${expiry#notAfter=}"
    ((exit_code < 1)) && exit_code=1
  else
    printf 'OK       %-40s expires %s\n' "$certificate" "${expiry#notAfter=}"
  fi
done

exit "$exit_code"

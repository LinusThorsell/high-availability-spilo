#!/usr/bin/env bash

set -euo pipefail

ETCD_IMAGE='quay.io/coreos/etcd:v3.5.27@sha256:88281a073b5965756b7690539e689fa1d8aa988b184b4f575280f4a81eb85f8c'

usage() {
  cat <<'EOF'
Usage:
  bootstrap-etcd-auth.sh ADMIN_PKI_DIR AUTH_ENV_FILE

ADMIN_PKI_DIR must contain ca.crt, etcd-root.crt, and etcd-root.key.
AUTH_ENV_FILE must define SCOPE, ETCD_ENDPOINTS, ETCD_USERNAME,
ETCD_PASSWORD, and ETCD_ROOT_PASSWORD. Run this once after all three etcd
members are healthy and before starting Spilo.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}

command -v docker >/dev/null 2>&1 || die 'docker is required'

admin_pki_dir=$1
auth_env_file=$2
[[ -d $admin_pki_dir ]] || die "admin PKI directory not found: $admin_pki_dir"
[[ -f $auth_env_file ]] || die "auth environment file not found: $auth_env_file"
admin_pki_dir=$(cd "$admin_pki_dir" && pwd -P)

for file in ca.crt etcd-root.crt etcd-root.key; do
  [[ -f $admin_pki_dir/$file ]] || die "missing $admin_pki_dir/$file"
done

set -a
# This file is an operator-owned input and follows normal shell .env syntax.
# shellcheck disable=SC1090
source "$auth_env_file"
set +a

for variable in SCOPE ETCD_ENDPOINTS ETCD_USERNAME ETCD_PASSWORD ETCD_ROOT_PASSWORD; do
  [[ -n ${!variable:-} ]] || die "$variable is empty or unset in $auth_env_file"
done
[[ $SCOPE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'SCOPE contains unsupported characters'

etcdctl() {
  docker run --rm -i --network host \
    --mount "type=bind,src=$admin_pki_dir/ca.crt,dst=/pki/ca.crt,readonly" \
    --mount "type=bind,src=$admin_pki_dir/etcd-root.crt,dst=/pki/client.crt,readonly" \
    --mount "type=bind,src=$admin_pki_dir/etcd-root.key,dst=/pki/client.key,readonly" \
    --env ETCDCTL_API=3 \
    "$ETCD_IMAGE" \
    /usr/local/bin/etcdctl \
    --endpoints="$ETCD_ENDPOINTS" \
    --cacert=/pki/ca.crt \
    --cert=/pki/client.crt \
    --key=/pki/client.key \
    --command-timeout=10s \
    "$@"
}

contains_line() {
  local lines=$1 expected=$2
  while IFS= read -r line; do
    [[ $line == "$expected" ]] && return 0
  done <<<"$lines"
  return 1
}

printf 'Waiting for the TLS-enabled etcd cluster...\n'
healthy=false
for _ in {1..30}; do
  if etcdctl endpoint health >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 2
done
[[ $healthy == true ]] || die 'etcd did not become healthy within 60 seconds'

users=$(etcdctl user list)
roles=$(etcdctl role list)

if ! contains_line "$users" root; then
  printf 'Creating the etcd root user...\n'
  printf '%s\n' "$ETCD_ROOT_PASSWORD" | etcdctl user add root --interactive=false
fi

if ! contains_line "$roles" root; then
  etcdctl role add root
fi
etcdctl user grant-role root root >/dev/null

if ! contains_line "$roles" patroni; then
  etcdctl role add patroni
fi

if ! contains_line "$users" "$ETCD_USERNAME"; then
  printf 'Creating the scoped Patroni etcd user...\n'
  printf '%s\n' "$ETCD_PASSWORD" | etcdctl user add "$ETCD_USERNAME" --interactive=false
fi

cluster_key="/service/$SCOPE"
etcdctl role grant-permission patroni readwrite "$cluster_key" >/dev/null
etcdctl role grant-permission patroni --prefix=true readwrite "$cluster_key/" >/dev/null
etcdctl user grant-role "$ETCD_USERNAME" patroni >/dev/null

auth_status=$(etcdctl auth status)
if [[ $auth_status != *true* ]]; then
  printf 'Enabling etcd authentication...\n'
  etcdctl auth enable
else
  printf 'etcd authentication is already enabled.\n'
fi

etcdctl endpoint health
printf 'etcd mTLS and RBAC are ready for Patroni scope %s.\n' "$SCOPE"

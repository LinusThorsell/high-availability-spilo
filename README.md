# High-availability PostgreSQL with Spilo

This repository runs a three-node PostgreSQL 17 cluster on three Linux hosts.
Spilo packages PostgreSQL and Patroni, etcd provides the distributed consensus
store, and HAProxy gives applications stable read/write endpoints. WAL-G backs
up to S3-compatible storage, and Grafana Alloy ships local node, PostgreSQL,
Patroni, and etcd metrics to Grafana Cloud. Both integrations can be omitted for
a core-only deployment.

This is a host-networked deployment. It is deliberately explicit about node
addresses, TLS identities, firewall rules, and bootstrap order. It is intended
for operators who are comfortable owning PostgreSQL recovery, etcd quorum, host
firewalls, certificate rotation, and restore testing.

## Architecture

Run the same repository and Compose project on every database host. Only the
node-specific values in `.env` and the node's certificate bundle differ.

```text
                                    +-------------------+
 application -- :15432 (writes) --> | HAProxy on n1/n2/n3 | -- :5432 --> primary
 application -- :15433 (reads)  --> | role-aware routing | -- :5432 --> replicas
                                    +---------+---------+
                                              |
                                  HTTPS HEAD /primary or /replica
                                              |
                                        Patroni :8008

 Spilo/Patroni on every node -- mTLS + RBAC --> etcd clients :2379
             etcd n1 <------ peer mTLS :2380 ------> etcd n2/etcd n3

 WAL-G ---------------------------------------------> S3-compatible storage
 node_exporter :9100 --+
 postgres_exporter :9187 +--> local Alloy ----------> Grafana Cloud
 Patroni :8008 (HTTPS) --+
 etcd :2379 (mTLS) ------+
```

Patroni records node membership and leader state under `/service/$SCOPE` in
etcd. HAProxy does not decide which server should be primary; it asks each
Patroni API and routes to the server whose current role matches the endpoint.
Clients can therefore use any healthy HAProxy node.

### Network policy

| Port | Bind address | Allowed sources | Purpose |
| --- | --- | --- | --- |
| 2379 | node IP and loopback | cluster nodes and operator hosts | etcd client API; mTLS and etcd RBAC required |
| 2380 | node IP | the three cluster nodes | etcd peer traffic; mTLS required |
| 5432 | node IP and loopback | the three cluster nodes | PostgreSQL and replication; applications should use HAProxy |
| 8008 | node IP | cluster nodes and operator hosts | Patroni HTTPS health and control API |
| 9100 | loopback only | local Alloy | node exporter |
| 9187 | loopback only | local Alloy | PostgreSQL exporter |
| 15432 | all host interfaces | application networks | HAProxy write endpoint |
| 15433 | all host interfaces | application networks | HAProxy replica-read endpoint |

Safe Patroni `GET` and `HEAD` requests remain available for health checking.
Unsafe methods require all three controls: a CA-signed client certificate,
Patroni Basic authentication, and an allowed source address. The
`allowlist_include_members` setting also permits registered Patroni members.

`firewall.nft.example` implements the source restrictions for this stack.
Binding a service to a private address is not a firewall; apply equivalent rules
in the cloud firewall or security group as well.

## Run the example cluster

The complete bootstrap and verification walkthrough lives in
[`examples/README.md`](examples/README.md). It covers preparing the three
nodes, generating and distributing the PKI, configuring the Compose stack,
enabling etcd RBAC, starting PostgreSQL, and verifying both HAProxy endpoints.

For a local VM-based demo, the example guide also links to the optional Alpine
cloud-init configuration in [`examples/cloud-init/`](examples/cloud-init/README.md).

## Routine operations

### Planned switchover

Use the Patroni tooling, never etcd key edits or direct PostgreSQL promotion. The
generated Patroni configuration includes the API CA, client certificate, and
Basic credentials, so this command can be run in a Spilo container:

```bash
docker exec --interactive --tty spilo \
  patronictl -c /home/postgres/postgres.yml switchover
```

Confirm the new primary through HAProxy before taking the old primary down.

### Backups

When enabled, WAL-G runs a base backup on `BACKUP_SCHEDULE` and continuously
archives WAL. A green backup job is not proof of recoverability. Monitor failed
uploads, retention, and bucket capacity, and perform scheduled restores into an
isolated cluster using new `SCOPE`, etcd, and data directories. Record the
recovery point and restore duration. WAL-G is disabled when its optional
environment settings are omitted.

### Image updates

Every image in `compose.yml` has both a readable version tag and an immutable
multi-architecture digest. To update one:

1. review the upstream release notes and security advisories;
2. resolve the tag's manifest-list digest with
   `docker buildx imagetools inspect IMAGE:TAG`;
3. update the tag and digest together;
4. validate and test failover and restore behavior in a non-production cluster;
5. roll one database host at a time, confirming etcd quorum and PostgreSQL
   replication before continuing.

Do not replace a digest with `latest` or with a version tag alone.

### Certificate rotation

Leaf certificates last 825 days; the CA lasts 3,650 days. Rotation is
operator-driven because the CA remains offline.

For routine renewal under the existing CA, follow the
[leaf-certificate rotation playbook](playbooks/leaf-certificate-rotation.md).
It covers issuance, validation, one-node-at-a-time rollout, and
[rollback](playbooks/leaf-certificate-rollback.md).

Use the expiry checker from cron or monitoring. It exits `1` at the warning
threshold, `2` at the critical threshold, and `3` for invalid input:

```bash
./scripts/check-cert-expiry.sh --warning-days 90 --critical-days 30 \
  /etc/high-availability-spilo/pki
```

Changing a node name or address requires a newly issued node certificate. CA
rotation uses a three-pass rollover: trust both roots, replace every leaf, then
remove the old root. Follow the [planned CA rotation playbook](playbooks/ca-rotation.md);
start before the CA enters its final 825 days. The scripts validate each
transition and keep per-node rollback bundles. A compromised leaf still needs a
separate response because this stack does not configure certificate revocation.

## Existing plaintext deployments

These bootstrap instructions are for a new cluster. Do not point the hardened
Compose file at a running plaintext etcd cluster and restart all three members.
Peer URLs are part of etcd membership, and an all-at-once protocol change can
destroy quorum. Take an etcd snapshot and a verified PostgreSQL backup—WAL-G
when enabled, or another method when disabled—then use a documented
one-member-at-a-time etcd migration or build a new secured cluster and restore
into it. Treat a production migration as its own change plan with a tested
rollback.

## Configuration references

- [Spilo environment configuration](https://github.com/zalando/spilo/blob/trigger/ENVIRONMENT.rst)
- [Patroni YAML configuration](https://patroni.readthedocs.io/en/latest/yaml_configuration.html)
- [etcd transport security](https://etcd.io/docs/v3.5/op-guide/security/)
- [etcd authentication and RBAC](https://etcd.io/docs/v3.5/op-guide/authentication/)
- [Prometheus node exporter](https://github.com/prometheus/node_exporter)
- [Prometheus PostgreSQL exporter](https://github.com/prometheus-community/postgres_exporter)
- [Grafana Alloy configuration](https://grafana.com/docs/alloy/latest/configure/)

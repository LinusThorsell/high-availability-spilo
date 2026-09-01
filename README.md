# High-availability PostgreSQL with Spilo

This repository runs a three-node PostgreSQL 17 cluster on three Linux hosts.
Spilo packages PostgreSQL and Patroni, etcd provides the distributed consensus
store, and HAProxy gives applications stable read/write endpoints. Grafana Alloy
ships local node, PostgreSQL, Patroni, and etcd metrics to Grafana Cloud.

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

## Before starting

You need:

- three Linux hosts with fixed private IPv4 addresses and reliable time sync;
- Docker Engine with the Compose v2 plugin on every host;
- OpenSSL on the workstation used to create the private PKI;
- an S3 bucket and credentials that can read, write, list, and delete the chosen
  WAL-G prefix;
- Grafana Cloud Prometheus remote-write credentials; and
- an operator workstation that can reach TCP 2379 and 8008 on the database
  hosts.

The examples use these addresses:

| Node | Address |
| --- | --- |
| `n1` | `10.0.1.2` |
| `n2` | `10.0.1.3` |
| `n3` | `10.0.1.4` |

Replace them consistently in `.env`, `haproxy.cfg`, and
`firewall.nft.example`. Certificates contain the node IP as a subject
alternative name, so changing an address also requires issuing a new node
certificate.

## 1. Generate the private PKI

Run this once on a secured operator workstation, not on a database node:

```bash
./scripts/generate-pki.sh /secure/spilo-pki \
  n1=10.0.1.2 n2=10.0.1.3 n3=10.0.1.4
```

The script refuses to overwrite an existing directory. It creates:

```text
/secure/spilo-pki/
├── ca.crt
├── ca.key                         # offline CA key; never copy to a node
├── admin/
│   ├── ca.crt
│   ├── etcd-root.crt/key          # etcd RBAC bootstrap and maintenance
│   └── patroni-operator.crt/key   # Patroni control operations
└── nodes/
    ├── n1/
    ├── n2/
    └── n3/
        ├── ca.crt
        ├── node.crt/key           # etcd peer/server and Patroni HTTPS server
        ├── patroni.crt/key        # Patroni client identity for etcd and patronictl
        └── monitoring.crt/key      # Alloy client identity
```

Back up `ca.key` in an encrypted offline location. The CA and administrator
private keys are not needed for normal service operation and must not remain on
database hosts.

Copy only the matching node directory to each server. For example, on `n1`:

```bash
sudo install -d -m 0700 /etc/high-availability-spilo/pki
sudo install -m 0644 /secure/spilo-pki/nodes/n1/* \
  /etc/high-availability-spilo/pki/
```

The directory is root-only on the host. The key files are readable inside their
containers because Spilo and Alloy use different unprivileged runtime UIDs;
Compose mounts only the specific keys each container needs.

## 2. Configure the nodes

Clone this repository to the same path on each host, then create the local
environment file:

```bash
cp .env.example .env
chmod 600 .env
```

Use independent random values for every password and token. Hex output avoids
`.env` quoting surprises:

```bash
openssl rand -hex 32
```

The following values are shared and must match on every node:

- `SCOPE`, `ETCD_INITIAL_CLUSTER`, `ETCD_INITIAL_CLUSTER_TOKEN`,
  `ETCD3_HOSTS`, `ETCD_USERNAME`, and `ETCD_PASSWORD`;
- all PostgreSQL and Patroni API credentials;
- the WAL-G settings; and
- the Grafana Cloud settings.

Change `NODE_NAME`, `NODE_IP`, `ETCD_NAME`, `LOCAL_DISK`, and `PKI_DIR` for each
node. Keep `ETCD_INITIAL_CLUSTER_STATE=new` for the first bootstrap. The setting
is ignored once an etcd data directory has been initialized; adding or replacing
a member later uses the etcd member-add procedure and `existing` state.

Prepare the persistent directories:

```bash
sudo install -d -m 0750 \
  /var/lib/high-availability-spilo/etcd-data \
  /var/lib/high-availability-spilo/spilo-data \
  /var/lib/high-availability-spilo/alloy-data
```

Do not reuse an `etcd-data` or `spilo-data` directory from a different cluster.
Do not put either directory on ephemeral storage.

## 3. Apply the network restrictions

Edit the three address sets in `firewall.nft.example`. Keep the Patroni operator
set narrow—normally the exact address of a bastion or operator workstation—and
put the same address or CIDR in `PATRONI_API_ALLOWLIST`.

Validate the file before applying it:

```bash
sudo nft --check --file firewall.nft.example
sudo nft --file firewall.nft.example
```

Persist the table using the host distribution's nftables mechanism. The example
has an `accept` policy and filters only this stack's ports, but it should still be
reviewed alongside the host's existing firewall. Cloud firewalls or security
groups should enforce the same source matrix.

## 4. Start etcd and enable RBAC

Start only etcd on all three nodes. The members need to come online together to
form their initial quorum:

```bash
docker compose up --detach etcd
docker compose logs --follow etcd
```

On the operator workstation, create `auth.env` from the example. Its
`ETCD_PASSWORD` must exactly match the node `.env` files. Its root password is an
emergency credential and should be stored in the secret manager with the admin
certificate, not copied to the database nodes.

```bash
cp auth.env.example auth.env
chmod 600 auth.env
./scripts/bootstrap-etcd-auth.sh /secure/spilo-pki/admin auth.env
```

The bootstrap is safe to rerun. It creates the `root` administrator, creates the
`patroni` role and user, grants read/write access only to
`/service/$SCOPE`, and enables etcd authentication. Patroni supplies both its
client certificate and RBAC credentials because its etcd v3 integration uses
the gRPC gateway.

Do not start Spilo before this step. A Patroni client configured with etcd
credentials cannot complete a clean first bootstrap while the etcd auth state is
being changed underneath it.

## 5. Start PostgreSQL and monitoring

After the auth script succeeds, start the full stack on all nodes:

```bash
docker compose up --detach
docker compose ps
```

One Spilo instance initializes PostgreSQL and wins the Patroni leader race. The
other two clone from it. Follow startup on each node:

```bash
docker compose logs --follow spilo haproxy
```

Create the least-privileged metrics role on the primary. Open `psql` in the
primary's Spilo container:

```bash
docker exec --interactive --tty spilo psql -U postgres -d postgres
```

Then run:

```sql
DO $block$
BEGIN
  CREATE ROLE postgres_exporter LOGIN;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$block$;

GRANT pg_monitor TO postgres_exporter;
\password postgres_exporter
```

Enter the same value as `PG_EXPORTER_PASSWORD`, then restart the exporter on
each node:

```bash
docker compose restart postgres_exporter
```

Create separate login roles and databases for applications. Do not use the
PostgreSQL superuser or exporter account in application connection strings.

## 6. Verify the cluster

Check the effective listener addresses on every node:

```bash
sudo ss -lnt | grep -E ':(2379|2380|5432|8008|9100|9187|15432|15433)[[:space:]]'
```

Ports 9100 and 9187 must appear only on `127.0.0.1`. Ports 2379, 2380, 5432,
and 8008 must not bind to a public address.

Check Patroni membership from any Spilo container:

```bash
docker exec spilo patronictl -c /home/postgres/postgres.yml list
```

Check the HTTPS health endpoint from an allowed host:

```bash
curl --fail --cacert /secure/spilo-pki/admin/ca.crt \
  https://10.0.1.2:8008/health
```

For an authenticated Patroni operation, use all three factors. This example is
a read-only cluster query:

```bash
curl --fail \
  --cacert /secure/spilo-pki/admin/ca.crt \
  --cert /secure/spilo-pki/admin/patroni-operator.crt \
  --key /secure/spilo-pki/admin/patroni-operator.key \
  --user 'patroni-admin:THE_PATRONI_API_PASSWORD' \
  https://10.0.1.2:8008/cluster
```

Finally, test both HAProxy paths with a non-superuser application account:

```bash
psql 'host=10.0.1.2 port=15432 dbname=app user=app sslmode=require'
psql 'host=10.0.1.2 port=15433 dbname=app user=app sslmode=require'
```

The first connection must reach the primary. The second must reach a replica and
will be read-only. Verify metrics in Grafana Cloud and check Alloy for delivery
errors with `docker compose logs alloy`.

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

WAL-G runs a base backup daily at 02:00 and continuously archives WAL. A green
backup job is not proof of recoverability. Monitor failed uploads, retention, and
bucket capacity, and perform scheduled restores into an isolated cluster using
new `SCOPE`, etcd, and data directories. Record the recovery point and restore
duration.

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

Issue replacement node and client certificates from the offline CA before the
825-day leaf lifetime expires. Keep the same SANs and client common names. Rotate
one node at a time and confirm etcd peer health, Patroni membership, HAProxy
health, and Alloy scrapes after each restart. CA rotation requires an overlap
period in which clients and servers trust both roots; plan it separately.

## Existing plaintext deployments

These bootstrap instructions are for a new cluster. Do not point the hardened
Compose file at a running plaintext etcd cluster and restart all three members.
Peer URLs are part of etcd membership, and an all-at-once protocol change can
destroy quorum. Take an etcd snapshot and a verified PostgreSQL/WAL-G backup,
then use a documented one-member-at-a-time etcd migration or build a new secured
cluster and restore into it. Treat a production migration as its own change plan
with a tested rollback.

## Configuration references

- [Spilo environment configuration](https://github.com/zalando/spilo/blob/trigger/ENVIRONMENT.rst)
- [Patroni YAML configuration](https://patroni.readthedocs.io/en/latest/yaml_configuration.html)
- [etcd transport security](https://etcd.io/docs/v3.5/op-guide/security/)
- [etcd authentication and RBAC](https://etcd.io/docs/v3.5/op-guide/authentication/)
- [Prometheus node exporter](https://github.com/prometheus/node_exporter)
- [Prometheus PostgreSQL exporter](https://github.com/prometheus-community/postgres_exporter)
- [Grafana Alloy configuration](https://grafana.com/docs/alloy/latest/configure/)

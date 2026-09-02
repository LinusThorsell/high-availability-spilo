# Planned CA rotation

Start with at least 30 days plus the expected rollout duration remaining on the
current CA and every current certificate. Preparation enforces that margin for
the whole PKI; the node helper rechecks its bundles at each stage. Do not use
this procedure after expiry.

## Before starting

- Confirm all three etcd members and Patroni nodes are healthy.
- Take an etcd snapshot and a verified PostgreSQL backup.
- Keep the current deployed PKI bundle and both CA private keys offline.
- Schedule the work as three complete rolling passes. Never mix or skip passes.
- If anything has less than the required headroom, renew the old leaves first or
  reschedule under a tested incident plan.

The stages are:

| Stage | Trusted roots | Leaf certificates |
| --- | --- | --- |
| `01-trust-both` | old and new | old |
| `02-new-leaves` | old and new | new |
| `03-new-ca-only` | new | new |

## 1. Create and prepare the new PKI

On the secured CA workstation, create a new PKI with the same node identities:

```bash
./scripts/generate-pki.sh /secure/spilo-pki-ca2 \
  n1=10.0.1.2 n2=10.0.1.3 n3=10.0.1.4

./scripts/prepare-ca-rotation.sh \
  /secure/spilo-pki-current \
  /secure/spilo-pki-ca2 \
  /secure/spilo-ca-rotation \
  n1=10.0.1.2 n2=10.0.1.3 n3=10.0.1.4
```

`spilo-pki-current` must contain the certificates and keys deployed now. The
preparation script verifies both PKIs and creates the three stage directories.
It never copies either CA private key.

Record the old and new SHA-256 fingerprints printed by the script. Store the new
CA key offline before continuing. Set the approved new fingerprint, without
spaces, on the operator shell:

```bash
NEW_CA_SHA256=AA:BB:CC:REPLACE_WITH_THE_RECORDED_FINGERPRINT
```

## 2. Trust both CAs

Create a private staging directory and copy only that node's files:

```bash
ssh n1 'install -d -m 0700 /tmp/spilo-ca-01'
scp /secure/spilo-ca-rotation/01-trust-both/nodes/n1/* n1:/tmp/spilo-ca-01/
```

Then run:

```bash
sudo ./scripts/rotate-node-ca.sh --new-ca-sha256 "$NEW_CA_SHA256" trust \
  /tmp/spilo-ca-01 \
  /etc/high-availability-spilo/pki \
  n1=10.0.1.2
```

Rotate replicas first and the current primary last, using a planned switchover
when needed. Confirm Patroni membership and etcd quorum after each node. Do not
begin the next stage until every node trusts both roots.

Use `01-trust-both/admin` for operator commands during this stage.

## 3. Install new leaf certificates

Create another mode `0700` staging directory for
`02-new-leaves/nodes/NODE`, then repeat the rolling pass:

```bash
ssh n1 'install -d -m 0700 /tmp/spilo-ca-02'
scp /secure/spilo-ca-rotation/02-new-leaves/nodes/n1/* n1:/tmp/spilo-ca-02/
```

From the node's repository checkout:

```bash
sudo ./scripts/rotate-node-ca.sh --new-ca-sha256 "$NEW_CA_SHA256" leaves \
  /tmp/spilo-ca-02 \
  /etc/high-availability-spilo/pki \
  n1=10.0.1.2
```

After all three nodes finish, use `02-new-leaves/admin` for operator commands.
Confirm HAProxy routing, Patroni membership, etcd quorum, and Alloy scrapes.

## 4. Remove the old CA

Only continue when every server and client certificate uses the new CA. Stage
`03-new-ca-only/nodes/NODE` in another mode `0700` directory for the final pass:

```bash
ssh n1 'install -d -m 0700 /tmp/spilo-ca-03'
scp /secure/spilo-ca-rotation/03-new-ca-only/nodes/n1/* n1:/tmp/spilo-ca-03/
```

From the node's repository checkout:

```bash
sudo ./scripts/rotate-node-ca.sh --new-ca-sha256 "$NEW_CA_SHA256" final \
  /tmp/spilo-ca-03 \
  /etc/high-availability-spilo/pki \
  n1=10.0.1.2
```

Rotate replicas first and the primary last, then switch operator tooling to
`03-new-ca-only/admin`. Verify the cluster again and compare the installed CA
fingerprint with `manifest.txt`.

Remove staging copies from the nodes. Retain backups through the next maintenance
window. Archive or destroy the old CA key according to the incident-retention
policy; it is no longer trusted by the cluster.

If any node fails a stage, stop and use the [rollback playbook](ca-rotation-rollback.md).

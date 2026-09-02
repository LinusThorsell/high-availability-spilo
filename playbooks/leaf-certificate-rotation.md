# Planned leaf-certificate rotation

Use this playbook for node, Patroni, monitoring, and administrator certificates
when the CA itself is unchanged. Start while the current certificates are valid.

## Before starting

- Confirm etcd quorum and Patroni membership.
- Take an etcd snapshot and a verified PostgreSQL backup.
- Keep the deployed PKI bundle and offline CA key available.
- Rotate replicas first and the current primary last.
- Start with enough validity for the rollout and rollback window; 90 days is the
  recommended warning point and 30 days is the latest planned start.

## 1. Issue replacements

Run on the secured CA workstation with the same node names and addresses:

```bash
./scripts/renew-pki.sh \
  /secure/spilo-pki \
  /secure/spilo-pki-2026-09 \
  n1=10.0.1.2 n2=10.0.1.3 n3=10.0.1.4
```

The output contains new leaf keys and certificates but no CA private key. The
script refuses renewal if the CA cannot cover another 825-day leaf lifetime; use
the [CA rotation playbook](ca-rotation.md) in that case.

Validate each node bundle before copying it:

```bash
./scripts/validate-node-pki.sh \
  /secure/spilo-pki-2026-09/nodes/n1 \
  n1=10.0.1.2
```

## 2. Stage and rotate each node

Create a private staging directory before copying any keys:

```bash
ssh n1 'install -d -m 0700 /tmp/n1-renewal'
scp /secure/spilo-pki-2026-09/nodes/n1/* n1:/tmp/n1-renewal/
```

The rotation helper rejects staging directories accessible by group or others.
From that node's repository checkout, run:

```bash
sudo ./scripts/rotate-node-pki.sh \
  /tmp/n1-renewal \
  /etc/high-availability-spilo/pki \
  n1=10.0.1.2
```

The helper validates the bundle, keeps a timestamped backup, recreates etcd and
Spilo, recreates Alloy when present, then checks etcd and Patroni. Confirm HAProxy
routing and replication before continuing to the next node. Use a planned
switchover before rotating the primary when needed.

## 3. Finish

Store the new `admin` bundle with the operator credentials and use it for future
maintenance. Check every certificate:

```bash
./scripts/check-cert-expiry.sh \
  /secure/spilo-pki-2026-09/admin \
  /etc/high-availability-spilo/pki
```

Remove node staging copies after all three nodes are healthy. Keep the offline
renewal bundle and per-node backups through the next maintenance window. Old
certificates remain valid until expiry because this stack does not use a CRL.

If a node fails, stop and use the [leaf rollback playbook](leaf-certificate-rollback.md).

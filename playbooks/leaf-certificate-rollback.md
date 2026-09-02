# Leaf-certificate rollback

Do not continue to another node while the current node is unhealthy. The
rotation helper reports a timestamped backup; restore it with:

```bash
sudo ./scripts/rotate-node-pki.sh --restore \
  /etc/high-availability-spilo/pki.backup-TIMESTAMP \
  /etc/high-availability-spilo/pki \
  n1=10.0.1.2
```

The restore recreates etcd and Spilo, plus Alloy when enabled. Confirm etcd
quorum, Patroni membership, HAProxy routing, and replication before retrying.

Rollback is not useful after the old certificate has expired. Treat an expired
production certificate as an incident and avoid manual PostgreSQL promotion
while Patroni cannot reach etcd.

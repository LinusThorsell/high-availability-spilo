# CA rotation rollback

Do not advance to the next stage while a node is unhealthy. Each successful
stage is deliberately compatible with the stage immediately before it.

The rotation command reports a timestamped backup. Restore it on the failed
node with:

```bash
sudo ./scripts/rotate-node-ca.sh restore \
  /etc/high-availability-spilo/pki.backup-TIMESTAMP \
  /etc/high-availability-spilo/pki \
  n1=10.0.1.2
```

The restore recreates etcd, Spilo, HAProxy when the CA bundle changed, and Alloy
when enabled. Confirm etcd quorum and Patroni membership before retrying.

If the current CA or leaf certificates have already expired, this rolling
procedure cannot establish the overlap it depends on. Treat that as an outage:
stop the rollout, prevent manual PostgreSQL promotion, preserve the data and etcd
directories, and recover under a separate tested incident plan.

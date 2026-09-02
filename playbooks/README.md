# Operations playbooks

- [Planned leaf-certificate rotation](leaf-certificate-rotation.md)
- [Leaf-certificate rollback](leaf-certificate-rollback.md)
- [Planned CA rotation](ca-rotation.md)
- [CA rotation rollback](ca-rotation-rollback.md)

These are operator-run shell workflows, not Ansible playbooks. Their helpers
live in [`scripts/`](../scripts/). Test them against a disposable cluster before
production use.

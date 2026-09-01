# Alpine cloud-init example

This example prepares one Alpine VM with SSH, Docker Compose, nftables, and the
host directories needed by this repository.

## 1. Download Alpine

Download the official **Generic, x86_64, BIOS, cloud-init, virtual machine**
QCOW2 image from the [Alpine cloud image page](https://alpinelinux.org/cloud/).

For Alpine 3.24.1, download
[generic_alpine-3.24.1-x86_64-bios-cloudinit-r0.qcow2](https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/cloud/generic_alpine-3.24.1-x86_64-bios-cloudinit-r0.qcow2).

Use the UEFI variant instead if the VM is configured for UEFI.

## 2. Customize the configuration

Copy the example files once per node:

```bash
cp examples/cloud-init/user-data.yml /tmp/n1-user-data.yml
cp examples/cloud-init/meta-data.yml /tmp/n1-meta-data.yml
```

In both files, change `n1` to the node name. In `user-data.yml`, replace:

```text
ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY
```

with the contents of your SSH public key, normally `~/.ssh/id_ed25519.pub`.
Never put the private key in this file.

The finished YAML entry must contain the public key exactly once, for example:

```yaml
ssh_authorized_keys:
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@workstation
```

Before creating the VM, make sure no placeholder remains:

```bash
grep REPLACE_WITH_YOUR_PUBLIC_KEY /tmp/n1-user-data.yml
```

The command should print nothing.

Keep the template's `users: [default]` setting. The Alpine image configures its
default `alpine` account appropriately for key-based SSH; setting
`lock_passwd: true` on that account can make PAM reject public-key logins.
`ssh_pwauth: false` already disables SSH password authentication.

## 3. Create the VM

Create a writable copy of the downloaded image for each VM and enlarge it:

```bash
cp generic_alpine-3.24.1-x86_64-bios-cloudinit-r0.qcow2 n1.qcow2
qemu-img resize n1.qcow2 30G
```

Create and start the VM with libvirt:

```bash
virt-install --connect qemu:///system \
  --name n1 \
  --memory 4096 \
  --vcpus 2 \
  --disk path=/absolute/path/to/n1.qcow2,bus=virtio \
  --network network=default,model=virtio \
  --osinfo alpinelinux3.23 \
  --import \
  --cloud-init user-data=/tmp/n1-user-data.yml,meta-data=/tmp/n1-meta-data.yml \
  --graphics spice \
  --noautoconsole
```

The system connection is the one normally shown by virt-manager. If your user
does not have permission to use it, run the command with `sudo`. Keep using the
same connection for later `virsh` commands; the per-user `qemu:///session`
connection has a separate set of VMs and networks.

If libvirt reports that `/var/lib/libvirt/boot` does not exist, create the
directory it has configured for temporary boot media, then rerun `virt-install`:

```bash
sudo install -d -m 0755 /var/lib/libvirt/boot
```

Use an absolute path for the disk. If `virt-install --osinfo list` contains a
newer Alpine identifier, use that instead of `alpinelinux3.23`.

The VM appears in virt-manager immediately and cloud-init runs during its first
boot. `--noautoconsole` leaves it running in the background and returns control
to your terminal.

## 4. Connect

Find the address assigned by libvirt:

```bash
virsh --connect qemu:///system net-dhcp-leases default
```

Again, prepend `sudo` if the system connection requires it.

Then connect as the `alpine` user:

```bash
ssh -i ~/.ssh/id_ed25519 alpine@192.168.122.X
```

Check that initialization completed:

```bash
cloud-init status --wait
docker compose version
findmnt -no PROPAGATION /
```

The mount-propagation command should print `shared`.

Repeat the process for `n2` and `n3`. The Spilo configuration requires stable
addresses, so assign static DHCP leases in libvirt before generating the PKI and
the repository `.env` files.

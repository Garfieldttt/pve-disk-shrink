# pve-disk-shrink

A dialog based tool that shrinks a Proxmox VE virtual machine disk completely offline
from the host. It replaces the manual GParted procedure: no live ISO, no clicking, no
partition editor inside the guest. The whole shrink runs on the PVE node against the
stopped VM, which makes it deterministic and repeatable.

It auto discovers the disk, the storage backend and the partition layout, computes the
smallest safe size from the actual data in use, and refuses to make a disk smaller than
the data plus a headroom you choose.

## What it does

For a stopped VM and a disk you select, it runs the full sequence:

1. Force a filesystem check (`e2fsck -f`). If the filesystem has unrecoverable errors it
   stops before changing anything.
2. Shrink the filesystem (`resize2fs` for ext2/3/4, or `lvreduce --resizefs` for guest
   LVM).
3. Shrink the last data partition with `sgdisk`, preserving its start sector, type,
   name and PARTUUID so `root=` and `/etc/fstab` keep working. A trailing swap partition
   is recreated right after it and re initialised with its original UUID.
4. Shrink the backing block device (`zfs set volsize` for a ZFS zvol, or
   `qemu-img resize --shrink` for a qcow2 image or raw LV).
5. Move the GPT backup header to the new end of the device (`sgdisk -e`) and verify the
   table (`sgdisk -v`).
6. Sync the size back into the VM config (`qm rescan`).

Disks that have a filesystem or an LVM physical volume directly on the device, with no
partition table, are handled too. In that case the partition and GPT steps are skipped.

## Requirements

Run it as root on a Proxmox VE node. It uses tools that ship with PVE:
`qm`, `pvesm`, `sgdisk`, `e2fsck`, `resize2fs`, `qemu-nbd`, `qemu-img`, `blkid`,
`lsblk`, `partx`, `zfs`, `dialog`, `numfmt`. Guest LVM needs `lvm2`. Shrinking a disk
that lives on an LVM storage backend needs `kpartx`.

## Supported

Storage backends:

* ZFS zvol
* qcow2 image (directory storage)
* raw LV on an LVM storage backend

Guest layouts:

* plain ext2/3/4 as the last partition
* ext4 as the last data partition with a trailing swap partition
* guest LVM (root logical volume on an LVM physical volume)
* whole disk ext filesystem or LVM PV with no partition table

Not supported:

* XFS. XFS cannot be shrunk, so the tool refuses instead of risking the data.
* MBR or other non GPT partition tables (whole disk with no table is fine).

## Usage

```
pve-disk-shrink.sh              interactive, pick VM, disk and target size
pve-disk-shrink.sh --dry-run    show the full plan and computed sizes, change nothing
pve-disk-shrink.sh --debug      verbose trace into the logfile
```

Interactive flow:

1. Pick the VM.
2. Pick the disk. A VM often has more than one disk. efidisk, tpmstate, cloudinit and
   CD drives are never listed, so they cannot be selected by mistake. The boot disk is
   marked `[boot]`.
3. If the VM is running you are asked to stop it.
4. If the VM has snapshots you are warned that all of them will be deleted permanently,
   and asked to confirm. Snapshots block a shrink and cannot be kept.
5. If the VM has `protection` set, you are offered to disable it for the shrink. It is
   re-enabled automatically at the end, including on cancel or error.
6. Choose the target size: data plus 10, 20, 30, 40 or 50 percent, or enter a size by
   hand. The data floor is measured with `resize2fs -P`, so a value below it is rejected.
7. Review the summary and confirm. Nothing is written before this confirmation.

During the shrink a progress bar shows each step with a live elapsed second counter, so
it is always visible that the tool is working and not hung.

## Safety model

* The VM must be stopped. The disk is worked on offline.
* You choose the disk explicitly. efidisk, tpmstate, cloudinit and CD drives are filtered
  out and can never be picked.
* The target can never be smaller than the data in use plus your chosen headroom, and can
  never be larger than or equal to the current size.
* A forced `e2fsck` runs first. A filesystem with unrecoverable errors stops the run
  before any change.
* The original partition layout is written to the log before any write, so it can be read
  back and recreated by hand if needed. The tool creates no backup files.
* The GPT is verified with `sgdisk -v` after the shrink. A failed check stops the run and
  tells you not to start the VM.
* Every destructive step needs an explicit confirmation, and a cleanup routine always
  detaches nbd devices, partition mappings and activated volume groups on exit.
* `--dry-run` shows exactly what would happen without touching anything.

This tool does not create a backup. Make sure a current backup of the VM exists before
you use it.

## First boot after a shrink

The first boot after a shrink can be slower than usual and may print RCU or soft lockup
warnings on the console while ext4 finishes its lazy inode table work in the background.
This is expected and clears on its own.

## Recovery

The tool creates no backup files. Before any change it writes the original partition
layout (`sgdisk -p`) to the log, so the previous layout can always be read back and
recreated by hand if needed.

If a run stops with a GPT verification error, do not start the VM. Read the original
layout from the log and rebuild the backup header with `sgdisk -e <device>`, then verify
with `sgdisk -v <device>`.

If a VM ever drops to an initramfs shell with a message that the root filesystem needs a
manual check, run the check by hand and boot on:

```
fsck -y /dev/sdaN
exit
```

## Logs

All actions, including the original partition layout, are logged to
`/var/log/pve-disk-shrink/pve-disk-shrink.log`.

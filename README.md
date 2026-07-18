# pve-disk-shrink

A dialog based tool that shrinks a Proxmox VE virtual machine disk completely offline
from the host. It replaces the manual GParted procedure: no live ISO, no clicking, no
partition editor inside the guest. The whole shrink runs on the PVE node against the
stopped VM, which makes it deterministic and repeatable.

It auto discovers the disk, the storage backend and the partition layout, computes the
smallest safe size from the actual data in use, and refuses to make a disk smaller than
the data plus a headroom you choose.

## What it does

For a stopped VM, a disk and a partition you select, it runs the full sequence:

1. Check the filesystem (`e2fsck` for ext, `ntfsresize --info` for NTFS). Errors are only
   repaired after you confirm; a dirty NTFS is refused.
2. Shrink the filesystem (`resize2fs` for ext2/3/4, `ntfsresize` for NTFS, or
   `lvreduce --resizefs` for guest LVM).
3. Shrink the chosen partition with `sgdisk`, preserving its start sector, type, name and
   GUIDs so `root=` / `/etc/fstab` and the Windows boot chain keep working.
4. Move every partition that sits after it down into the freed space, keeping their order
   and identity. Data partitions are relocated block for block; swap is recreated with its
   original UUID.
5. Shrink the backing block device (`zfs set volsize` for a ZFS zvol, or
   `qemu-img resize --shrink` for a qcow2 image or raw LV).
6. Move the GPT backup header to the new end of the device (`sgdisk -e`) and verify the
   table (`sgdisk -v`).
7. Sync the size back into the VM config (`qm rescan`).

Disks that have a filesystem or an LVM physical volume directly on the device, with no
partition table, are handled too. In that case the partition and GPT steps are skipped.

## Requirements

Run it as root on a Proxmox VE node. It uses tools that ship with PVE:
`qm`, `pvesm`, `sgdisk`, `e2fsck`, `resize2fs`, `qemu-nbd`, `qemu-img`, `blkid`,
`lsblk`, `partx`, `zfs`, `dialog`, `numfmt`. Guest LVM needs `lvm2`. NTFS needs `ntfs-3g`
(the tool offers to install it). Shrinking a disk that lives on an LVM storage backend
needs `kpartx`.

## Supported

Storage backends:

* ZFS zvol
* qcow2 image (directory storage)
* raw LV on an LVM storage backend

Filesystems:

* ext2/3/4
* NTFS (needs the ntfs-3g package; the tool offers to install it)
* guest LVM (the largest ext logical volume on an LVM physical volume)

Layouts:

* any GPT layout: you pick which partition to shrink, and any partitions after it are
  moved down into the freed space while keeping their order, numbering and identity
  (GUIDs). This covers Windows (C: with a Recovery partition after it) and Debian with
  extra partitions after root, not just a trailing swap.
* whole disk ext filesystem or LVM PV with no partition table

Not supported:

* XFS. XFS cannot be shrunk, so the tool refuses instead of risking the data.
* BitLocker-encrypted partitions. An encrypted volume cannot be shrunk offline, so the tool
  detects BitLocker and shows a hint with two options: (A) shrink it in Windows (Disk
  Management is BitLocker-aware), then re-run this tool to reclaim the freed space at the
  device level, or (B) turn BitLocker off in Windows (`manage-bde -off`), after which the
  volume is plain NTFS and this tool can shrink it directly. Applies to any encrypted
  volume, not only C:.
* MBR or other non GPT partition tables (whole disk with no table is fine).

Windows note: NTFS must be cleanly shut down. If the volume is hibernated or Fast Startup
is on, the tool refuses. Boot Windows, disable Fast Startup, shut down fully, then retry.

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
3. Pick the partition to shrink. Every partition is listed with its size and filesystem;
   only shrinkable ones (ext, NTFS, LVM) can be chosen. If there is only one shrinkable
   partition this step is skipped. Partitions after the chosen one are moved down.
4. If the VM is running you are asked to stop it.
5. If the VM has snapshots you are warned that all of them will be deleted permanently,
   and asked to confirm. Snapshots block a shrink and cannot be kept.
6. If the VM has `protection` set, you are offered to disable it for the shrink. It is
   re-enabled automatically at the end, including on cancel or error.
7. Choose the target size: data plus 10, 20, 30, 40 or 50 percent, or enter a size by
   hand. The data floor is the filesystem minimum, so a value below it is rejected.
8. Review the summary and confirm. Nothing is written before this confirmation.

During the shrink a progress bar shows each step with a live elapsed second counter, so
it is always visible that the tool is working and not hung.

## Safety model

* The VM must be stopped. The disk is worked on offline.
* You choose the disk explicitly. efidisk, tpmstate, cloudinit and CD drives are filtered
  out and can never be picked.
* The target can never be smaller than the data in use plus your chosen headroom, and can
  never be larger than or equal to the current size.
* The filesystem is checked first (`e2fsck` for ext, `ntfsresize --info` for NTFS). Errors
  are only repaired after you confirm, and a hibernated or dirty NTFS is refused.
* BitLocker-encrypted partitions are detected and never touched; a hint explains how to
  shrink them (in Windows, or after turning BitLocker off).
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

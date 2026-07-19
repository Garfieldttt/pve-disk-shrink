# pve-disk-shrink

A dialog based tool that shrinks a Proxmox VE virtual machine disk or LXC container volume
completely offline from the host. It replaces the manual GParted procedure: no live ISO, no
clicking, no partition editor inside the guest. The whole shrink runs on the PVE node against
the stopped guest, which makes it deterministic and repeatable.

It auto discovers the volume, the storage backend and the layout, computes the smallest safe
size from the actual data in use, and refuses to make a volume smaller than the data plus a
headroom you choose.

## What it does

You pick a VM or a container, the disk or volume, and how much to reclaim. The tool then runs
the offline sequence that fits the layout:

- Check the filesystem first (`e2fsck` for ext, `ntfsresize --info` for NTFS). Errors are only
  repaired after you confirm; a dirty or hibernated NTFS is refused.
- Shrink the filesystem where needed (`resize2fs` for ext2/3/4, `ntfsresize` for NTFS).
- For a partitioned disk, shrink the chosen partition with `sgdisk`, preserving its start
  sector, type, name, unique GUID and GPT attribute flags, so `root=` / `/etc/fstab`, the
  Windows boot chain and a Windows Recovery partition keep working. Partitions that sit after
  it are moved down into the freed space, keeping their order and identity; swap is recreated
  with its original UUID.
- Shrink the backing device: `zfs set volsize` (zvol), `qemu-img resize --shrink` (qcow2 or
  raw image), or `lvreduce` (LVM). For a ZFS subvol container the dataset refquota is lowered
  and no filesystem is touched.
- For a partitioned disk, move the GPT backup header to the new end (`sgdisk -e`) and verify
  the table (`sgdisk -v`).
- Sync the new size back into the guest config (`qm rescan` for a VM, the container config for
  a CT).

Volumes that hold a filesystem or an LVM physical volume directly on the device, with no
partition table, are handled too; the partition and GPT steps are then skipped. This is the
normal case for containers.

## Supported

Guests: QEMU VMs (`qm`) and LXC containers (`pct`), listed together.

VM storage backends: ZFS zvol, qcow2 image, raw LV.

Container storage backends: dir/raw image, LVM-thin, ZFS subvol.

Filesystems: ext2/3/4 and NTFS shrink in place. A ZFS subvol is shrunk by its refquota, so its
content is never touched.

Layouts:

- Any GPT layout: you pick which partition to shrink, and any partitions after it are moved
  down into the freed space while keeping their order, numbering and identity. This covers
  Windows (C: with a Recovery partition after it) and Linux with extra partitions after root.
- Reclaim only the free space after the last partition, without touching any filesystem,
  partition or LVM. This is offered as the safe default whenever such free space exists.
- Whole disk or container volume with a filesystem directly on it, no partition table.

Guest LVM (an LVM physical volume inside a VM disk) has three modes:

- Reclaim only the free space after the LVM partition, LVM untouched.
- Compact: reclaim the volume group's free space with `pvmove` and `pvresize` without shrinking
  any filesystem. Because no filesystem is touched this works with XFS and with mixed volume
  groups, and handles volume groups that hold several logical volumes.
- Shrink a filesystem to go below the used size, when a shrinkable ext logical volume exists.

## Not supported or handled specially

- XFS cannot be shrunk. A plain XFS partition is refused. XFS inside an LVM volume group can
  still be reduced by the group's free space using the compact mode above, since the XFS
  filesystem itself is never touched.
- BitLocker-encrypted partitions cannot be shrunk offline. The tool detects BitLocker and never
  touches the volume; a hint explains the two options: (A) shrink it in Windows (Disk
  Management is BitLocker-aware), then re-run this tool to reclaim the freed space at the device
  level, or (B) turn BitLocker off in Windows (`manage-bde -off`), after which the volume is
  plain NTFS and this tool can shrink it directly. Applies to any encrypted volume, not only C:.
- MBR (msdos) partition tables are detected and refused with an actionable message (convert to
  GPT, or use GParted). Nothing is touched. A whole disk with no partition table is fine.
- NTFS must be cleanly shut down. If the volume is hibernated or Fast Startup is on, the tool
  refuses. Boot Windows, disable Fast Startup, shut down fully, then retry.

## Requirements

Run it as root on a Proxmox VE node. It uses tools that ship with PVE: `qm`, `pct`, `pvesm`,
`sgdisk`, `e2fsck`, `resize2fs`, `qemu-nbd`, `qemu-img`, `blkid`, `lsblk`, `partx`, `zfs`,
`dialog`, `numfmt`. LVM needs `lvm2`. NTFS needs `ntfs-3g` and a raw-LV backed disk needs
`kpartx`; the tool offers to install these when needed.

## Usage

```
pve-disk-shrink.sh              interactive: pick the guest, the volume and the target size
pve-disk-shrink.sh --dry-run    show the full plan and computed sizes, change nothing
pve-disk-shrink.sh --debug      verbose trace into the logfile
```

Interactive flow:

1. Pick the VM or container.
2. Pick the disk or volume. VM efidisk, tpmstate, cloudinit and CD drives are never listed. For
   a VM the boot disk is marked `[boot]`.
3. For a partitioned VM disk, pick the partition to shrink; partitions after it are moved down.
   This step is skipped for a whole-disk filesystem or a container volume.
4. If the guest is running you are asked to stop it.
5. If it has snapshots you are warned that all of them will be deleted permanently, and asked to
   confirm. Snapshots block a shrink and cannot be kept.
6. If it has `protection` set, you are offered to disable it for the shrink. It is re-enabled
   automatically at the end, including on cancel or error.
7. Choose how to shrink. Depending on the layout this is a target size (data plus 10, 20, 30, 40
   or 50 percent, or a manual size) and, for LVM or when free space follows the last partition,
   a choice between reclaiming only that free space, compacting, or shrinking a filesystem.
8. Review the summary and confirm. Nothing is written before this confirmation.

During the shrink a progress bar shows each step with a live elapsed second counter, so it is
always visible that the tool is working and not hung.

## Safety model

- The guest must be stopped. The volume is worked on offline.
- You choose the volume explicitly. VM efidisk, tpmstate, cloudinit and CD drives are filtered
  out and can never be picked.
- The target can never be smaller than the data in use plus your chosen headroom, and can never
  be larger than or equal to the current size.
- Every value parsed from `sgdisk`, `resize2fs`, `lvm` and friends is read in the C locale, so a
  localized host cannot mis-parse a size.
- BitLocker-encrypted volumes are detected and never touched.
- The original partition layout is written to the log before any write. The tool creates no
  backup files.
- For a partitioned disk the GPT is verified with `sgdisk -v` after the shrink. A failed check
  stops the run and tells you not to start the guest.
- Every destructive step needs an explicit confirmation, and a cleanup routine always detaches
  nbd devices, partition mappings and activated volume groups on exit.
- `--dry-run` shows exactly what would happen without touching anything.

This tool does not create a backup. Make sure a current backup of the guest exists before you
use it.

## First boot after a shrink

The first boot after a shrink can be slower than usual and may print RCU or soft lockup warnings
on the console while ext4 finishes its lazy inode table work in the background. This is expected
and clears on its own.

## Recovery

The tool creates no backup files. Before any change it writes the original partition layout
(`sgdisk -p`) to the log, so the previous layout can always be read back and recreated by hand.

If a run stops with a GPT verification error, do not start the guest. Read the original layout
from the log and rebuild the backup header with `sgdisk -e <device>`, then verify with
`sgdisk -v <device>`.

If a guest ever drops to an initramfs or emergency shell asking for a manual filesystem check,
run it by hand and boot on:

```
fsck -y /dev/<device>
exit
```

## Logs

All actions, including the original partition layout, are logged to
`/var/log/pve-disk-shrink/pve-disk-shrink.log`.

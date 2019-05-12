# lvm-restic-backup

This bash script backups logical volumes via [restic](https://restic.net/). 

## How to backup

### Backup one LV

```
./lvm-restic-backup.sh --repo example.env --backup ubuntu-disk --block-level
```

### Backup multiple LVs

```
./lvm-restic-backup.sh --repo example.env --backup list.txt --block-level
```

## How to restore

### Restore one LV

```
./lvm-restic-backup.sh --repo example.env --restore ubuntu-disk --vg VG0
```

### Restore multiple LVs

```
./lvm-restic-backup.sh --repo example.env --restore list.txt --vg VG0
```
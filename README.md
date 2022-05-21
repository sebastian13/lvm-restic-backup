# LVM restic & rescript backup

This bash script backups logical volumes via [restic](https://restic.net/). To simplify repo handling, this script takes repo details from [rescript](https://gitlab.com/sulfuror/rescript.sh) config.

## Requirements
- [restic](https://restic.net/)
- [rescript](https://gitlab.com/sulfuror/rescript.sh)
- [pigz](https://zlib.net/pigz/)

## Optional Req. for Zabbix Monitoring
- zabbix-sender
- pip3
- python3: humanfriendly
- Zabbix [Rescript Restic Backup Template](https://github.com/sebastian13/zabbix-template-rescript)

## How to use

```bash
lvm-rescript [repo_name] [command] [lv_name|path-to-list]
```

### Commands
- `block-level-backup` creates a lvm-snapshot & pipes the volume using dd to restic
- `block-level-gz-backup` creates a lvm-snapshot & pipes the volume using dd and pigz to restic
- `file-level-backup` creates a lvm-snapshot & creates a restic backup using the mounted snapshot
- `block-level-gz-restore` restores dd and pigz logical volume(s)

## How to install

```bash
curl -o /usr/bin/lvm-rescript https://raw.githubusercontent.com/sebastian13/lvm-restic-backup/master/lvm-restic-backup.sh
chmod +x /usr/bin/lvm-rescript
```

For Zabbix LVM Discovery also download the [script](https://github.com/sebastian13/zabbix-template-rescript):

```bash
curl -o /etc/zabbix/scripts/rescript-lvm-discovery.pl https://raw.githubusercontent.com/sebastian13/zabbix-templates/master/rescript-restic-backup/scripts/rescript-lvm-discovery.pl
chmod +x /etc/zabbix/scripts/rescript-lvm-discovery.pl
```

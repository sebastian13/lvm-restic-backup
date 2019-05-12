#!/bin/bash

# -------------------------------------------------------
#   How To Use
# -------------------------------------------------------

function help {
	echo
	echo "LVM RESTIC BACKUP"
	echo "------------------------"
	echo
	echo "Parameters:"
	echo "  --init                             Initialize the Restic Repo"
	echo "  --repo [path-to-env-file]          Repos Information"
	echo "  --backup [path-to-list|lv-name]    Run the backup task"
	echo "  --block-level                      Backup the LV as RAW Image"
	echo "  --file-level                       Backup the files inside the LV"
	echo "  --help                             Display this help message"
	echo
	echo "Example:"
	echo "  ./lvm-restic-backup.sh --repo /root/env.txt --backup ubuntu-disk --block-level"
	echo
	echo "LVM RESTIC RESTORE"
	echo "------------------------"
	echo
	echo "Parameters:"
	echo "  --restore [path-to-list|lv-name]   Restore a logical volume"
	echo "  --vg [vg-name]                     Define the destination volume group"
	echo "  --help                             Display this help message"
	echo
	echo "Example:"
	echo "  ./lvm-restic-backup.sh --repo example.env --restore example-lv --vg VG0"
	echo
}

# Exit if any statement returns a non-true value
set -e

# initialise variables
CURRDIR="$(dirname "$(readlink -f "$0")")"
RESTIC_ENVIRONMENT="/etc/restic/repos/default.repo"
RESTIC_INIT=false
RESTIC_EXCLUDE="/etc/restic/exclude.txt"
LVM_SNAPSHOT_BUFFER="10G"
BLOCK_LEVEL_BACKUP=false
FILE_LEVEL_BACKUP=false
WORKDIR="/"

# Change to WORKDIR
# Restic will save this path
cd $WORKDIR

# Create Log Directory
mkdir -p /var/log/backup

# -------------------------------------------------------
#   Check package availability
# -------------------------------------------------------

command -v restic >/dev/null 2>&1 || { echo "[Error] Please install restic"; exit 1; }
command -v pip >/dev/null 2>&1 || { echo "[Error] Please install python-pip"; exit 1; }
python -c 'import humanfriendly' >/dev/null 2>&1 || { echo "[Error] Please run 'pip install humanfriendly'"; exit 1; } 


# -------------------------------------------------------
#   Loop to load arguments
# -------------------------------------------------------

# if no argument, display help
if [ $# -eq 0 ]
then
	help
	exit
fi

OPTS=$(getopt \
	--option '' \
	--long init,block-level,file-level,help,repo:,buffer:,backup:,restore:,vg: \
	-n 'parse-options' \
	-- "$@")

eval set -- "$OPTS"

while [[ $# -gt 0 ]]
do
  case "$1" in
    --repo )         RESTIC_ENVIRONMENT="$2"; shift; shift; ;;
	--init )         RESTIC_INIT=true; shift; ;;
	--buffer )       shift; LVM_SNAPSHOT_BUFFER="$1"; shift; ;;
	--backup )       shift; LVS_TO_BACKUP="$1"; shift; ;;
	--block-level )  BLOCK_LEVEL_BACKUP=true; shift; ;;
	--file-level )   FILE_LEVEL_BACKUP=true; shift; ;;
	--restore )      shift; LVS_TO_RESTORE="$1"; shift; ;;
	--vg )           shift; VG="$1"; shift; ;;
	--help )         HELP=true; shift; ;;
	-- )             shift; break ;;
    * )              shift; ;;
  esac
done

# Display help
if [ "$HELP" = true ]
then
	help
	exit
fi

# -------------------------------------------------------
#   Load restic environment variables
# -------------------------------------------------------

if [ ! -f "$RESTIC_ENVIRONMENT" ]
then
    echo "[Error] Your Restic Repo file is missing! Create a file named default.repo"
    echo "        in /etc/restic/repos or specify the path using the --repo option!"
    exit 1
fi

set -a
source $RESTIC_ENVIRONMENT
set +a

# -------------------------------------------------------
#   Wait for any other restic backup to finish
# -------------------------------------------------------

while (pgrep -x restic)
do
    echo "[INFO] Waiting for the listed restic processes to finish"
    sleep 60
done

# -------------------------------------------------------
#   Initialize restic repository or
#   check if the repository is already initialized
# -------------------------------------------------------

if [ "$RESTIC_INIT" = true ]
then
	restic init
	exit
else
	echo "[INFO] Looking for your restic repository. Please be patient."
	restic snapshots > /dev/null 2>&1 || { echo "[Error]"; restic snapshots; exit 1; }
fi

# -------------------------------------------------------
#   Check if variables have been provided
# -------------------------------------------------------

if [ ! "$LVS_TO_BACKUP" ] && [ ! "$LVS_TO_RESTORE" ]
then
    echo "[Error] Either --backup or --restore must be provided!"
    exit 1
fi

if [ "$LVS_TO_BACKUP" ] && [ "$BLOCK_LEVEL_BACKUP" = false ] && [ "$FILE_LEVEL_BACKUP" = false ]
then
    echo "[Error] Tell me, if the backup should be --block-level or/and --file-level!"
    exit 1
fi

# -------------------------------------------------------
#   The backup tasks
# -------------------------------------------------------

function failed {
	echo
	echo " ___              ___  __  "
	echo "|__   /\  | |    |__  |  \ "
	echo "|    /--\ | |___ |___ |__/ "
	echo                          
	exit 1
}

function all-done {
	echo "                   __   __        ___ "
	echo " /\  |    |       |  \ /  \ |\ | |__  "
	echo "/--\ |___ |___    |__/ \__/ | \| |___ "
	echo       
	exit 0                            
}

# Block Level Backup piped to restic
function block-level-backup {
	dd if=${SNAPSHOT_PATH} bs=4M status=none | \
		pigz --fast --rsyncable | \
		restic backup \
		--verbose \
		--tag LV \
		--tag block-level-backup \
		--tag pigz \
		--tag ${BACKUP_LV_SIZE}g_size \
		--stdin \
		--stdin-filename ${BACKUP_LV}.img.gz | \
		tee -a /var/log/backup/lvm-restic-backup.log | \
		tee /var/log/restic/latest-backup.log

	# Store Bytes Added to the Repo
	LOG_ADDED=$( cat /var/log/restic/latest-backup.log | \
				 grep 'Added to the repo' | awk '{print $5,$6}' | \
				 python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))' )
    zabbix_sender --config /etc/zabbix/zabbix_agentd.conf --key "restic.added.[${BACKUP_LV}]" --value "$LOG_ADDED"

    # Store Snapshot ID
    LOG_SNAPSHOT=$( grep 'snapshot' /var/log/restic/latest-backup.log | awk '{print $2}')
    zabbix_sender --config /etc/zabbix/zabbix_agentd.conf --key "restic.snapshot.[${BACKUP_LV}]" --value "$LOG_SNAPSHOT"

    # Store Execution Time in Seconds
    LOG_DURATION=$( grep 'processed' /var/log/restic/latest-backup.log | \
					awk '{print $NF}' | \
					awk -F':' '{print (NF>2 ? $(NF-2)*3600 : 0) + (NF>1 ? $(NF-1)*60 : 0) + $(NF)}' )
	zabbix_sender --config /etc/zabbix/zabbix_agentd.conf --key "restic.duration.[${BACKUP_LV}]" --value "$LOG_DURATION"    

}

# File Level Backup using restic
function file-level-backup {
	SNAPSHOT_MOUNTPOINT="/mnt/${SNAPSHOT_NAME}"

	# Create the snapshot mount directory
	if [ ! -d ${SNAPSHOT_MOUNTPOINT} ] ; then
	mkdir ${SNAPSHOT_MOUNTPOINT}
	fi

	# Protect the snapshot mount-point
	chmod go-rwx ${SNAPSHOT_MOUNTPOINT}

	# Mount the snapshot read-only
	mount -o ro ${SNAPSHOT_PATH} ${SNAPSHOT_MOUNTPOINT}

	# Check free Space on volume
	DF=$(df -hlP ${SNAPSHOT_MOUNTPOINT} | awk 'int($5)>80{print "Volume "$1" has only "$4" free space left."}')

	restic \
		--verbose \
		--tag LV \
		--tag file-level-backup \
		--tag ${BACKUP_LV_SIZE}g_size \
		backup ${SNAPSHOT_MOUNTPOINT} \
		--exclude-file="${RESTIC_EXCLUDE}"

    # Unmount the Snapshot & Delete the mount-point
	umount ${SNAPSHOT_MOUNTPOINT}
	rmdir ${SNAPSHOT_MOUNTPOINT}
}

function clean-snapshots {
	echo "Looking for old snapshots of ${SNAPSHOT_PATH}"
	# Remove snapshot called *_snapshot
	if (lvs -o lv_path | grep -e "\s${SNAPSHOT_PATH}\s"); then
		echo "[WARNING] ${SNAPSHOT_NAME} already exists."
		echo "          I will remove it in 5 seconds!"
		sleep 5
		lvremove -f ${SNAPSHOT_PATH}
	else
		echo "... Good. Nothing to clean up."
	fi
}

function backup {
	echo "[INFO] Starting backup $BACKUP_LV. Press CTRL-C to abort."
	sleep 5

	# Get the Path + Size of the LV to Backup
	BACKUP_LV_PATH=$(lvs --noheading -o lv_path | grep -P "${BACKUP_LV}( |$)" | tr -d '  ')
	BACKUP_LV_SIZE=$(lvs ${BACKUP_LV_PATH} -o LV_SIZE --noheadings --units g --nosuffix)
	SNAPSHOT_NAME="${BACKUP_LV}_snapshot"
	SNAPSHOT_PATH="${BACKUP_LV_PATH}_snapshot"

	# Check if LV does exist
	if [ ! ${BACKUP_LV_PATH} ]
	then
	    echo "[Error] Cannot find path for ${BACKUP_LV}"
	    failed
	    exit 1
	fi

	# Check for old snapshots
	clean-snapshots

	# Create the snapshot
	lvcreate --quiet -L${LVM_SNAPSHOT_BUFFER} -s -n ${SNAPSHOT_NAME} ${BACKUP_LV_PATH} > /dev/null

	if [ "$BLOCK_LEVEL_BACKUP" = true ]; then block-level-backup; fi
	if [ "$FILE_LEVEL_BACKUP" = true ]; then file-level-backup; fi

	lvremove -f ${SNAPSHOT_PATH} > /dev/null
}

# -------------------------------------------------------
#   The restore task
# -------------------------------------------------------

function restore {
	echo
	echo "*** RESTORE ***"

	# Check provided volume group
	if [ ! ${VG} ]
	then
	    echo "[Error] Volume Group must be specified"
	    failed
	    exit 1
	fi

	restore_size=$(restic ls --json --path /${RESTORE_LV}.img.gz latest / | jq '.tags' | grep -o '[0-9]*,[0-9]*g')
	restore_size_int=$( echo ${restore_size//,/.} | python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))')
	
	echo "[INFO] LV Name: ${RESTORE_LV}"
	echo "[INFO] LV Size: ${restore_size}"

	RESTORE_LV_PATH=$(lvs --noheading -o lv_path | grep -P "${RESTORE_LV}( |$)" | tr -d '  ')
	RESTORE_LV_SIZE=$(lvs ${RESTORE_LV_PATH} -o LV_SIZE --noheadings --units g --nosuffix)

	if [ "${RESTORE_LV_PATH}" ] # Is there any LV with the same name?
	then
		# https://stackoverflow.com/questions/1885525/how-do-i-prompt-a-user-for-confirmation-in-bash-script
		echo
		echo "There is already an LV with the same name in ${RESTORE_LV_PATH}"
		echo "The size of the existing LV is ${RESTORE_LV_SIZE},"
		echo "the size of the LV to restore is ${restore_size}"
		read -p "Do you want to use the existing LV? (y/n)" -n 1 -r
		echo    # (optional) move to a new line
		if [[ $REPLY =~ ^[Yy]$ ]]
		then
		    echo "ok"
		else
			echo "Please rename/remove the LV ${RESTORE_LV} manually!"
			failed
			exit
		fi
	else
		echo "[INFO] Creating LV ${RESTORE_LV}, ${restore_size} on ${VG}"
		sleep 2
		lvcreate -n ${RESTORE_LV} -L ${restore_size} ${VG}
	fi

	RESTORE_LV_PATH=$(lvs --noheading -o lv_path | grep -P "${RESTORE_LV}( |$)" | tr -d '  ')
	echo "[INFO] Starting Restore of ${RESTORE_LV}"
	sleep 2
	restic dump --path /${RESTORE_LV}.img.gz latest ${RESTORE_LV}.img.gz | \
		unpigz | pv -s ${restore_size_int} | \
		dd of=${RESTORE_LV_PATH} bs=4M

	echo "[INFO] Done."
	all-done
}

if [ "${LVS_TO_RESTORE}" ]
then
	if [ -f "${LVS_TO_RESTORE}" ] 
	then
		# Read the file provided and backup each LV
		grep -v '^#' ${LVS_TO_RESTORE} | while read -r line
		do
			RESTORE_LV=$line
			restore
		done
		all-done
	else
		# Backup LV provided
		RESTORE_LV=${LVS_TO_RESTORE}
		restore
		all-done
	fi
fi

# -------------------------------------------------------
#   Get Logical Volume(s) to backup and
#	run backup task
# -------------------------------------------------------

if [ "${LVS_TO_BACKUP}" ] 
then
	if [ -f "${LVS_TO_BACKUP}" ] 
	then
		echo "[INFO] Verifying that all listed LV exist"
		grep -v '^#' ${LVS_TO_BACKUP} | while read -r line
		do
			lvs --noheading -o lv_path | grep -P "$line( |$)" || (echo "Cannot find LV $line" && failed)
		done

		# Read the file provided and backup each LV
		grep -v '^#' ${LVS_TO_BACKUP} | while read -r line
		do
			BACKUP_LV=$line
			backup
		done
		all-done
	else
		# Backup LV provided
		BACKUP_LV=${LVS_TO_BACKUP}
		backup
		all-done
	fi
fi



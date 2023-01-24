#!/bin/bash

# -------------------------------------------------------
#   How To Use
# -------------------------------------------------------

# Exit if any statement returns a non-true value
set -e
set -o pipefail

# Define various output colors
cecho () {
  local _color=$1; shift
  # If running via cron, don't use colors.
  if tty -s
  then
  	echo -e "$(tput setaf $_color)$@$(tput sgr0)"
  else
  	echo $1
  fi
}
black=0; red=1; green=2; yellow=3; blue=4; pink=5; cyan=6; white=7;

help () {
	echo
	cecho $blue "LVM RESCRIPT & RESTIC BACKUP"
	cecho $blue "----------------------------"
	cecho $blue "Author:  Sebastian Plocek"
	cecho $blue "URL:     https://github.com/sebastian13/lvm-restic-backup"
	echo
	cecho $blue  "Usage:"
	cecho $blue  "  lvm-rescript [repo_name] [command] [lv_name|path-to-list]"
	echo
	cecho $blue  "Commands:"
	cecho $blue  "  block-level-backup          Creates a lvm-snapshot & pipes the volume using dd to restic"
	cecho $blue  "  block-level-gz-backup       Creates a lvm-snapshot & pipes the volume using dd and pigz to restic"
	cecho $blue  "  file-level-backup           Creates a lvm-snapshot & creates a restic backup using the mounted snapshot"
	cecho $blue  "  restore                     Restores logical volume(s)"
	echo
	cecho $blue  "Logical Volume:"
	cecho $blue  "  Provide the LV name without VG."
	cecho $blue  "  Provide the path to a list of LV names. LVs listed as #comment won't be backed up."
	echo
}

# initialise variables
CURRDIR="$(dirname "$(readlink -f "$0")")"
RESTIC_EXCLUDE="/etc/restic/exclude.txt"
LVM_SNAPSHOT_BUFFER="10G"
WORKDIR="/"

# Change to WORKDIR
# Restic will save this path
cd $WORKDIR

# Create Log Directory
LOGDIR="/var/log/lvm-restic"
mkdir -p $LOGDIR
RLOG="${LOGDIR}/lvm-rescript-running.log"

# -------------------------------------------------------
#   Check package availability
# -------------------------------------------------------

command -v restic >/dev/null 2>&1 || { echo "[Error] Please install restic"; exit 1; }
command -v rescript >/dev/null 2>&1 || { echo "[Error] Please install rescript"; exit 1; }

# -------------------------------------------------------
#   Loop to load arguments
# -------------------------------------------------------

# if no argument, display help
if [ $# -eq 0 ]
then
	help
	exit
fi

case "$1" in
	help)
		help
		exit
		;;
esac

# -------------------------------------------------------
#   Load Repository Details
# -------------------------------------------------------
repo="$1"
rescript_dir="$HOME/.rescript"
config_dir="$rescript_dir/config"
config_file="$config_dir/$repo.conf"

# Check if repo config exists
if [[ ! -e "$config_dir/$1.conf" && ! -e "$config_dir/$1.conf.gpg" ]] ; then
	echo "There is no repo or command for [$1]. Indicate a valid"
	echo "repo name or command to proceed. Run [lvm-rescript help] for usage."
	exit
fi

# Check if the repository exists
echo "[INFO] Looking for your restic repository. Please be patient."
rescript ${repo} snapshots > /dev/null 2>&1 || { echo "[Error]"; rescript ${repo} snapshots; exit 1; }

source "$config_file"
export RESTIC_REPOSITORY="$RESTIC_REPO"
export B2_ACCOUNT_ID="$B2_ID"
export B2_ACCOUNT_KEY="$B2_KEY"
export AWS_ACCESS_KEY_ID="$AWS_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_KEY"
export AZURE_ACCOUNT_NAME="$AZURE_NAME"
export AZURE_ACCOUNT_KEY="$AZURE_KEY"
export GOOGLE_PROJECT_ID="$GOOGLE_ID"
export GOOGLE_APPLICATION_CREDENTIALS="$GOOGLE_CREDENTIALS"
if [[ "$RESCRIPT_PASS" ]] ; then
  export RESTIC_PASSWORD="$RESCRIPT_PASS"
else
  export RESTIC_PASSWORD="$RESTIC_PASSWORD"
fi


# -------------------------------------------------------
#   Wait for any other restic backup to finish
# -------------------------------------------------------

while (pgrep -x 'restic backup')
do
    echo "[INFO] Waiting for the listed restic processes to finish"
    sleep 60
done


# -------------------------------------------------------
#   The backup tasks
# -------------------------------------------------------

failed () {
	echo
	echo " ___              ___  __  "
	echo "|__   /\  | |    |__  |  \ "
	echo "|    /--\ | |___ |___ |__/ "
	echo                          
	exit 1
}

all-done () {
	echo "                   __   __        ___ "
	echo " /\  |    |       |  \ /  \ |\ | |__  "
	echo "/--\ |___ |___    |__/ \__/ | \| |___ "
	echo       
	exit 0                            
}

# -------------------------------------------------------
#   Cleaning Functions
# -------------------------------------------------------

clean-snapshot () {
	# Look for old snapshots of ${SNAPSHOT_PATH}
	if (lvs -o lv_path --noheadings -S "lv_attr=~[^s.*]" | grep -wo "${SNAPSHOT_PATH}")
	then
		cecho $red "[WARNING] ${SNAPSHOT_NAME} already exists."
		cecho $red "          I will remove it in 5 seconds!"
		sleep 5
		lvremove -f ${SNAPSHOT_PATH}
	fi
}

clean-all-snapshots () {
	# Look for old snapshots
	ACTIVE_SNAPSHOTS=$(lvs -o lv_path --noheadings --select "lv_name=~[_snapshot$],lv_attr=~[^s.*]" | tr -d '  ')
	if [ -n "$ACTIVE_SNAPSHOTS" ]
	then
		cecho $red "Removing the following active snapshots:"
		cecho $red "${ACTIVE_SNAPSHOTS}"
		echo
		sleep 10
		for i in ${ACTIVE_SNAPSHOTS}
		do
			lvremove -f $i
		done
		echo
	else
		cecho $green "There are no active snapshots named *_snapshot on this system."
		echo
	fi
}

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT
ctrl_c () {
		echo
		cecho $red "======================================================="
		cecho $red "Trapped CTRL-C"
		cecho $red "Signal interrupt received, cleaning up"
		echo
		if [ ! -d ${SNAPSHOT_MOUNTPOINT} ]
		then
        	umount ${SNAPSHOT_MOUNTPOINT}
			rmdir ${SNAPSHOT_MOUNTPOINT}
		fi
        clean-all-snapshots
        exit 130
}

# -------------------------------------------------------
#   Backup Functions
# -------------------------------------------------------

# Block Level Backup piped to restic
block-level-backup () {
	printf "\n======\n`date`\nBACKUP_LV: ${BACKUP_LV}\n\n" | tee -a ${LOGDIR}/lvm-restic-block-level-backup.log

	dd if=${SNAPSHOT_PATH} bs=4M status=none | \
		restic backup \
		--verbose \
		--tag LV \
		--tag block-level-backup \
		--tag ${BACKUP_LV_SIZE}g_size \
		--tag ${BACKUP_LV} \
		--stdin \
		--stdin-filename ${BACKUP_LV}.img | \
		tee -a ${LOGDIR}/lvm-restic-block-level-backup.log | \
		tee ${RLOG}
	echo
}

block-level-gz-backup () {
	command -v pigz >/dev/null 2>&1 || { echo "[Error] Please install pigz"; exit 1; }

	printf "\n======\n`date`\nBACKUP_LV: ${BACKUP_LV}\n\n" | tee -a ${LOGDIR}/lvm-restic-block-level-gz-backup.log

	dd if=${SNAPSHOT_PATH} bs=4M status=none | \
		pigz --fast --rsyncable | \
		restic backup \
		--verbose \
		--tag LV \
		--tag block-level-backup \
		--tag pigz \
		--tag ${BACKUP_LV} \
		--tag ${BACKUP_LV_SIZE}g_size \
		--stdin \
		--stdin-filename ${BACKUP_LV}.img.gz | \
		tee -a ${LOGDIR}/lvm-restic-block-level-gz-backup.log | \
		tee ${RLOG}
	echo
}

# File Level Backup using restic
file-level-backup () {
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

	printf "\n======\n`date`\nBACKUP_LV: ${BACKUP_LV}\n\n" | tee -a ${LOGDIR}/lvm-restic-file-level-backup.log

	restic \
		--verbose \
		--tag LV \
		--tag file-level-backup \
		--tag ${BACKUP_LV} \
		--tag ${BACKUP_LV_SIZE}g_size \
		backup ${SNAPSHOT_MOUNTPOINT} \
		--exclude-file="${RESTIC_EXCLUDE}" | \
		tee -a ${LOGDIR}/lvm-restic-file-level-backup.log | \
		tee ${RLOG}

    # Unmount the Snapshot & Delete the mount-point
	umount ${SNAPSHOT_MOUNTPOINT}
	rmdir ${SNAPSHOT_MOUNTPOINT}
}

snap-and-back () {
	echo
	cecho $blue "======================================================="
	cecho $blue "Starting backup of LV $BACKUP_LV"
	echo
	sleep 5

	# Get the Path + Size of the LV to Backup
	BACKUP_LV_PATH=$(lvs --noheading -o lv_path | grep -P "/${BACKUP_LV}( |$)" | tr -d '  ')
	BACKUP_LV_SIZE=$(lvs ${BACKUP_LV_PATH} -o LV_SIZE --noheadings --units g --nosuffix | sed 's/,/./g')
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
	clean-snapshot

	# Create the snapshot
	lvcreate --quiet -L${LVM_SNAPSHOT_BUFFER} -s -n ${SNAPSHOT_NAME} ${BACKUP_LV_PATH} > /dev/null

	eval $cmd

	lvremove -f ${SNAPSHOT_PATH} > /dev/null

	log-backup
}

backup () {
	zabbix-requirements
	zabbix-discovery

	if [ "${LV_TO_BACKUP}" ] 
	then
		if [ -f "${LV_TO_BACKUP}" ] 
		then
			echo "[INFO] Verify that all listed LVs exist"
			echo "# Temporary backup list `date`" > /tmp/backuplist.tmp
			grep -v '^#' ${LV_TO_BACKUP} | while read -r line
			do
				if (lvs --noheading -o lv_path | grep -P "/$line( |$)"); then
					echo "$line" >> /tmp/backuplist.tmp
				else
					echo
					cecho $red "[ERROR] Could not find $line !                      <<<<<<<<"
					cecho $red "        $line cannot be included in this backup !   <<<<<<<<"
					echo
				fi
			done

			# Rewrite Backup List to exclude missing LVs
			LV_TO_BACKUP="/tmp/backuplist.tmp"

			# Read the file provided and backup each LV
			grep -v '^#' ${LV_TO_BACKUP} | while read -r line
			do
				BACKUP_LV=$line
				snap-and-back
			done
		else
			# Backup LV provided
			BACKUP_LV=${LV_TO_BACKUP}
			snap-and-back
		fi
	else
		echo "LV(s) to backup missing. Please specify [lv-name] or [path-to-list]."
		echo "Run [lvm-rescript help] for usage."
		exit 1
	fi
}

# -------------------------------------------------------
#   The restore task
# -------------------------------------------------------

block-level-restore () {
	command -v pv >/dev/null 2>&1 || { echo "[Error] Please install pv"; exit 1; }
	command -v awk >/dev/null 2>&1 || { echo "[Error] Please install awk"; exit 1; }
	command -v jq >/dev/null 2>&1 || { echo "[Error] Please install jq"; exit 1; }
	command -v pip3 >/dev/null 2>&1 || { echo "[Error] Please install python3-pip"; exit 1; }
	if ! `python3 -c 'import humanfriendly' >/dev/null 2>&1`
	then
		cecho $red "Could not import python3 humanfriendly!"
		cecho $red "Please run 'pip3 install humanfriendly'."
	fi

	cecho $pink "Getting all snapshots of ${restore_lv_name}"
	restic snapshots --tag block-level-backup,${restore_lv_name}

	snapshots_json=$(restic snapshots --json --path \/${restore_lv_name}.img)
	arr=( $(echo $snapshots_json | jq -r '.[].short_id') )

	COLUMNS=12
	cecho $pink "Which snapshot should be restored?"
	select short_id in ${arr[@]}
	do
	    [ $short_id ] && break
	done
	unset COLUMNS

	cecho $pink "ID $short_id selected. Reading properties."
	restore_lv_info=$(restic snapshots --json $short_id)
	restore_lv_size=$(echo $restore_lv_info | jq '.[0].tags' | grep -o '[0-9]*\.[0-9]*._size' | sed 's/_size$//')
	restore_lv_size_int=$( echo $restore_lv_size | python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))')

	echo "[INFO] LV Name: ${restore_lv_name}"
	echo "[INFO] LV Size: ${restore_lv_size}, ${restore_lv_size_int}"

	# Check if a similar lv is present
	if [ $(lvs --noheading -o lv_path ${vg} | grep "${restore_lv_name}") ]
	then
		cecho $red "There is already an LV with the name ${restore_lv_name} on ${vg}."
		cecho $red "Please rename or remove the LV manually!"
		failed
		exit
	fi

	# Create the new LV
	echo "Creating LV ${restore_lv_name}, ${restore_lv_size} on ${vg}"
	sleep 2
	lvcreate -n ${restore_lv_name} -L ${restore_lv_size} ${vg} ${pv}

	restore_lv_path=$(lvs --noheading -o lv_path | grep -P "/${restore_lv_name}( |$)" | tr -d '  ')
	echo "[INFO] LV PATH: $restore_lv_path"

	echo
	cecho $green "===================="
	cecho $green "STARTING THE RESTORE"
	echo
	sleep 5
	restic dump $short_id ${restore_lv_name}.img | \
		pv -s ${restore_lv_size_int} | \
		dd of=${restore_lv_path} bs=4M
}

block-level-gz-restore () {
	command -v unpigz >/dev/null 2>&1 || { echo "[Error] Please install pigz"; exit 1; }
	command -v pv >/dev/null 2>&1 || { echo "[Error] Please install pv"; exit 1; }
	command -v awk >/dev/null 2>&1 || { echo "[Error] Please install awk"; exit 1; }
	command -v jq >/dev/null 2>&1 || { echo "[Error] Please install jq"; exit 1; }
	command -v pip3 >/dev/null 2>&1 || { echo "[Error] Please install python3-pip"; exit 1; }
	if ! `python3 -c 'import humanfriendly' >/dev/null 2>&1`
	then
		cecho $red "Could not import python3 humanfriendly!"
		cecho $red "Please run 'pip3 install humanfriendly'."
	fi

	cecho $pink "Getting all snapshots of ${restore_lv_name}"
	restic snapshots --tag block-level-gz-backup,${restore_lv_name}

	snapshots_json=$(restic snapshots --json --path \/${restore_lv_name}.img.gz)
	arr=( $(echo $snapshots_json | jq -r '.[].short_id') )

	COLUMNS=12
	cecho $pink "Which snapshot should be restored?"
	select short_id in ${arr[@]}
	do
	    [ $short_id ] && break
	done
	unset COLUMNS

	cecho $pink "ID $short_id selected. Reading properties."
	restore_lv_info=$(restic snapshots --json $short_id)
	restore_lv_size=$(echo $restore_lv_info | jq '.[0].tags' | grep -o '[0-9]*\.[0-9]*._size' | sed 's/_size$//')
	restore_lv_size_int=$( echo $restore_lv_size | python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))')

	echo "[INFO] LV Name: ${restore_lv_name}"
	echo "[INFO] LV Size: ${restore_lv_size}, ${restore_lv_size_int}"

	# Check if a similar lv is present
	if [ $(lvs --noheading -o lv_path ${vg} | grep "${restore_lv_name}") ]
	then
		cecho $red "There is already an LV with the name ${restore_lv_name} on ${vg}."
		cecho $red "Please rename or remove the LV manually!"
		failed
		exit
	fi

	# Create the new LV
	echo "Creating LV ${restore_lv_name}, ${restore_lv_size} on ${vg}"
	sleep 2
	lvcreate -n ${restore_lv_name} -L ${restore_lv_size} ${vg} ${pv}

	restore_lv_path=$(lvs --noheading -o lv_path | grep -P "/${restore_lv_name}( |$)" | tr -d '  ')
	echo "[INFO] LV PATH: $restore_lv_path"

	echo
	cecho $green "===================="
	cecho $green "STARTING THE RESTORE"
	echo
	sleep 5
	restic dump $short_id ${restore_lv_name}.img.gz | \
		unpigz | pv -s ${restore_lv_size_int} | \
		dd of=${restore_lv_path} bs=4M
}

file-level-restore () {
	command -v pv >/dev/null 2>&1 || { echo "[Error] Please install pv"; exit 1; }
	command -v awk >/dev/null 2>&1 || { echo "[Error] Please install awk"; exit 1; }
	command -v jq >/dev/null 2>&1 || { echo "[Error] Please install jq"; exit 1; }
	command -v pip3 >/dev/null 2>&1 || { echo "[Error] Please install python3-pip"; exit 1; }
	if ! `python3 -c 'import humanfriendly' >/dev/null 2>&1`
	then
		cecho $red "Could not import python3 humanfriendly!"
		cecho $red "Please run 'pip3 install humanfriendly'."
	fi

	cecho $pink "Getting all snapshots of ${restore_lv_name}"
	restic snapshots --tag file-level-backup,${restore_lv_name}

	snapshots_json=$(restic snapshots --json --tag file-level-backup,${restore_lv_name})
	arr=( $(echo $snapshots_json | jq -r '.[].short_id') )

	COLUMNS=12
	cecho $pink "Which snapshot should be restored?"
	select short_id in ${arr[@]}
	do
	    [ $short_id ] && break
	done
	unset COLUMNS

	echo "ID $short_id selected. Reading properties."
	restore_lv_info=$(restic snapshots --json $short_id)
	restore_lv_org_size=$(echo $restore_lv_info | jq '.[0].tags' | grep -o '[0-9]*\.[0-9]*._size' | sed 's/_size$//')
	restore_lv_org_size_int=$( echo $restore_lv_org_size | python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))')
	restore_lv_total_size_int=$(restic stats --json $short_id | jq '.total_size')
	restore_lv_total_size=$( echo $restore_lv_total_size_int  | numfmt --to=iec)

	echo "[INFO] LV Name: ${restore_lv_name}"
	echo "[INFO] LV's original size: ${restore_lv_org_size}, ${restore_lv_org_size_int}"
	echo "[INFO] LV's total required size: ${restore_lv_total_size}, ${restore_lv_total_size_int}"

  cecho $pink "What size do you want the new LV?"
	read -p "[${restore_lv_org_size}]" restore_lv_size
	restore_lv_size=${restore_lv_size:-${restore_lv_org_size}}
	echo "[INFO] LV Size: $restore_lv_size"

	# Check if a similar lv is present
	if [ $(lvs --noheading -o lv_path ${vg} | grep "${restore_lv_name}") ]
	then
		cecho $red "There is already an LV with the name ${restore_lv_name} on ${vg}."
		cecho $red "Please rename or remove the LV manually!"
		failed
		exit 1
	fi

	# Create the new LV
	echo "Creating LV ${restore_lv_name}, ${restore_lv_size} on ${vg}"
	sleep 2
	lvcreate -n ${restore_lv_name} -L ${restore_lv_size} ${vg} ${pv}

	restore_lv_path=$(lvs --noheading -o lv_path | grep -P "/${restore_lv_name}( |$)" | tr -d '  ')
	restore_lv_mountpoint="/mnt/${restore_lv_name}_snapshot"
	echo "[INFO] LV PATH: $restore_lv_path"
	echo "[INFO] LV MOUNTPOINT: $restore_lv_mountpoint"

	# Format Disk
	mkfs.ext4 $restore_lv_path

	# Create the snapshot mount directory
	if [ ! -d ${restore_lv_mountpoint} ]
	then
		mkdir ${restore_lv_mountpoint}
	else
		cecho $red "The mountpoint ${restore_lv_mountpoint} exists."
		cecho $red "Please check and remove it manually!"
		exit 1
	fi

	# Protect the mount-point
	chmod go-rwx ${restore_lv_mountpoint}

	# Mount the volume
	mount ${restore_lv_path} ${restore_lv_mountpoint}

	echo
	cecho $green "===================="
	cecho $green "STARTING THE RESTORE"
	echo
	sleep 5
  restic restore $short_id --include ${restore_lv_mountpoint} --target / | \
  	tee -a ${LOGDIR}/lvm-restic-file-level-restore.log

  # Unmount the volume & delete the mount-point
	umount ${restore_lv_mountpoint}
	rmdir ${restore_lv_mountpoint}
}

restore () {
	# Check if restore was started in a screen session
	if [ -z ${STY+x} ]
	then
		echo
		cecho $red "This is NOT a screen session."
		cecho $red "It is highly recommended to run the restore in a screen session!"
		command -v screen >/dev/null 2>&1 || { cecho $red "Consider installing and using screen"; }
		echo
		sleep 10
	else
		cecho $pink "This is a screen session named '$STY'"
	fi

	echo
	cecho $pink "============================="
	cecho $pink "STARTING RESTORE PREPARATIONS"

	if [ "${LV_TO_RESTORE}" ]
	then
		echo
		cecho $pink "Please select the Volume Group, where the Logical Volume(s) should be restored to:"
		select vg in $(vgs --noheading -o vg_name | tr -d '  ')
		do
			[ $vg ] && break
		done
		echo

		if [ $(pvs --noheading -o pv_name,vg_name | grep $vg | wc -l) -gt 0 ]
		then
			cecho $pink "$vg has more than one physical volume associated."
			cecho $pink "Please select the pv you want to restore to"
			echo
			echo "  PV         VG  Fmt  Attr PSize    PFree"
			pvs --noheading | grep $vg
			echo
			select pv in $(pvs --noheading -o pv_name,vg_name | grep $vg | awk '{print $1}')
			do
				[ $pv ] && break
			done
		else
			pv=""
		fi

		if [ -f "${LV_TO_RESTORE}" ] 
		then
			# Read the file provided and backup each LV
			grep -v '^#' ${LV_TO_RESTORE} | while read -r line
			do
				restore_lv_name=$line
				eval $cmd
			done
		else
			# Backup LV provided
			restore_lv_name=${LV_TO_RESTORE}
			eval $cmd
		fi
	else
		echo "LV(s) to restore missing. Please specify [lv-name] or [path-to-list]."
		echo "Run [lvm-rescript help] for usage."
		exit 1
	fi
}

zabbix-requirements () {
	skip_zabbix=false
	if ! `systemctl is-active --quiet zabbix-agent`
	then
		echo
		cecho $red "Zabbix-Agent is not running. Will skip zabbix logging."
		skip_zabbix=true
	fi
	if ! `command -v pip3 >/dev/null 2>&1`
	then
		cecho $red "Please install python3-pip."
		skip_zabbix=true
	fi
	if ! `python3 -c 'import humanfriendly' >/dev/null 2>&1`
	then
		cecho $red "Could not import python3 humanfriendly!"
		cecho $red "Please run 'pip3 install humanfriendly'."
		skip_zabbix=true
	fi
	if [ ! -f "/etc/zabbix/scripts/rescript-lvm-discovery.pl" ]
	then
		echo
		cecho $red "Zabbix Script rescript-lvm-discovery.pl missing. For instructions visit:"
		cecho $red "https://github.com/sebastian13/zabbix-templates/tree/master/rescript-restic-backup"
		skip_zabbix=true
	fi
	echo
}

zabbix-discovery () {
	if [ $skip_zabbix = false ]
	then
		cecho $yellow "[Running Zabbix Discovery]"
		export REPO="$repo"
		export LV_TO_BACKUP="$LV_TO_BACKUP"
		LVM_DISC=$(/etc/zabbix/scripts/rescript-lvm-discovery.pl)
		echo "$LVM_DISC" | python3 -m json.tool
		echo
		zabbix_sender --config /etc/zabbix/zabbix_agentd.conf --key "rescript.lv.discovery" --value "$LVM_DISC" \
			|| { echo "[Error] Sending to Zabbix failed. Will skip logging for now."; skip_zabbix=true; }
		echo
	else
		cecho $red "[Skipping Zabbix Discovery]"
	fi
}

log-backup () {
	if [ $skip_zabbix = false ]
	then
		set +e

		arr=()
		TIME=$(stat -c '%015Y' $RLOG)

		# Extract Added Bytes
		RLOG_ADDED=$(cat $RLOG | grep 'Added to the repo' | awk '{print $5,$6}' | \
			python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))' )
		arr+=("- restic.backup.added.[$BACKUP_LV.$REPO] $TIME $RLOG_ADDED")
		echo "Bytes Added:      $RLOG_ADDED"

		# Exctract Snapshot ID
		RLOG_SNAPSHOTID=$(cat $RLOG | grep '^snapshot .* saved$' | awk '{print $2}')
		arr+=("- restic.backup.snapshotid.[$BACKUP_LV.$REPO] $TIME $RLOG_SNAPSHOTID")
		echo "Snapshot ID:      $RLOG_SNAPSHOTID"

		# Extract Processed Time
		RLOG_PROCESSED_TIME=$(cat $RLOG | grep '^processed.*files' | \
				    awk '{print $NF}' | \
				    awk -F':' '{print (NF>2 ? $(NF-2)*3600 : 0) + (NF>1 ? $(NF-1)*60 : 0) + $(NF)}' )
		arr+=("- restic.backup.processedtime.[$BACKUP_LV.$REPO] $TIME $RLOG_PROCESSED_TIME")
		echo "Time Processed:   $RLOG_PROCESSED_TIME"

		# Extract Processed Bytes
		RLOG_PROCESSED_BYTES=$(cat $RLOG | grep '^processed.*files' | \
				     awk '{print $4,$5}' | \
				     python3 -c 'import sys; import humanfriendly; print (humanfriendly.parse_size(sys.stdin.read(), binary=True))'  )
		arr+=("- restic.backup.processedbytes.[$BACKUP_LV.$REPO] $TIME $RLOG_PROCESSED_BYTES")
		echo "Bytes Processed:  $RLOG_PROCESSED_TIME"  

		cecho $yellow "[Sending everything to Zabbix]"
		# for ix in ${!arr[*]}; do printf "%s\n" "${arr[$ix]}"; done
		# echo
		send-to-zabbix () {
			for ix in ${!arr[*]}; do printf "%s\n" "${arr[$ix]}"; done | zabbix_sender --config /etc/zabbix/zabbix_agentd.conf --with-timestamps --input-file -
		}

		# Send Data
		# It might be the case that the Zabbix Server has not fully processed the discovery of new items yet.
		# If sending raises an error, the script starts a second try after one minute.
		send-to-zabbix || { cecho $red "[ERROR] Sending or processing of some items failed. Will wait one minute before trying again..."; sleep 60; send-to-zabbix; }
		echo

		set -e
	else
		cecho $red "[Skipping Sending Data to Zabbix]"
	fi
}

# -------------------------------------------------------
#   Run Selected Commands
# -------------------------------------------------------
cmd="$2"
case "$cmd" in
	"")
		echo "Please specify a command."
		echo "Run [lvm-rescript help] for usage."
		exit 1
		;;
	block-level-backup|block-level-gz-backup|file-level-backup)
		LV_TO_BACKUP=$3
		backup
		;;
	block-level-restore|block-level-gz-restore|file-level-restore)
		LV_TO_RESTORE=$3
		restore
		;;
	*)
		echo "Unknown Command: ${cmd}."
		echo "Run [lvm-rescript help] for usage."
		exit 1
		;;
esac

# Remove temp. logfile
rm -f $RLOG

# Remove all remaining snapshots
clean-all-snapshots
all-done

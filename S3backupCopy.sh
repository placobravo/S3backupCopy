#!/usr/bin/env bash
# TODO
# Cleanup Function
# Various checks if folder paths or name exist (like bucket, repo, etc...)
# Fancier menu with rhytm entries
# Missing menu entries
# Rotate logs
# Add option to rename repository
# Difference between active jobs, enabled jobs and running jobs
# Add option to manually start a job and then enable it later 
# 	(or maybe add an option to start the job immediately after being run)
# Check how to declare variables locally on functions
# Check if the added job already exists

############################# FUNCTIONS #############################
typer() {
    # Function used to make printing of text a little fancier,
    # as it being typed in real time
    
    local speed=0.018
    
    while getopts "s:" flag; do
        case $flag in
        s)
            speed="${OPTARG}"
            ;;
        esac
    done
    
    shift $(($OPTIND - 1))
    local string=$1
    # We use parameter expansions and print each letter of string, but
    # we feed two consecutive letters at the same time if we have a '\'
    # symbol, because in that case we want echo/printf to interpret the
    # two symbols togheter
    for ((i = 0; i < ${#string}; i++)); do
        if [ "${string:$i:1}" = '\' ]; then
            printf "${string:$i:1}${string:$((i + 1)):1}"
            ((i++))
        else
            printf "${string:$i:1}"
        fi
        sleep "$speed"
    done
    unset OPTIND flag
}

checks() {
    # Check if user is root, exit otherwise
    if [ "$(whoami)" != "root" ]; then
        typer "\nYou need to be root to execute this script.\n" && exit 126
    fi

    # Check if rclone is installed
    if ! which rclone >/dev/null 2>&1; then
        typer "\nRclone is needed to execute this script.\n"
	exit 1
    fi
}

# Function to always double check if the user typed the correct input
get_variable() {
    while true; do
        printf "$1"
        read temp
        declare -g "$2=$temp"
        typer "$3 = \"${temp}\". Accept? [y/N]: "
        read choice
        [ "$choice" = "y" ] && return 0
    done
}

# This function is used to create/modify the rclone.conf file with the correct repository
create_repo() {
    while true; do
        get_variable "\nInsert a custom repository name: " REPO_NAME "Repository name"
        grep -w "$REPO_NAME" /root/.config/rclone/rclone.conf >/dev/null 2>&1 || break
        sleep 1
        typer "\nThis repo already exists, please insert a different one, or quit if you want to add jobs to it.\n\n"
    done
    get_variable "\nInsert the S3 server (https://example.com): " S3_SERVER "S3 Server"
    get_variable "\nInsert the access key token: " ACCESS_KEY "Access key token"
    get_variable "\nInsert the secret key token: " SECRET_KEY "Secret key"
    mkdir -p /root/.config/rclone/
    cat << EOF >> /root/.config/rclone/rclone.conf

[$REPO_NAME]
type = s3
provider = Other
access_key_id = $ACCESS_KEY
secret_access_key = $SECRET_KEY
endpoint = $S3_SERVER
acl = bucket-owner-full-control
force_path_style = true
EOF
    typer "\nThe repository was succesfully added!\n"
}

# This is the function which creates the script for the backup and the corresponding systemd units
create_job() {
    AVAIL_REPOS=$(grep -E '^\[[^]]+\]$' /root/.config/rclone/rclone.conf 2>/dev/null | sed 's/^\[\(.*\)\]$/\1/')
    if [ -z "$AVAIL_REPOS" ]; then
        typer "\nYou have no repositories, first add one, then you can add jobs to it.\n"
	return 0
    fi
    typer "\nFirst, you need to choose a repository for your job. These are the available ones: \n${AVAIL_REPOS}\n"
    while true; do
        get_variable "\nWhich do you want to use?: " CURRENT_REPO "Repository"
	[[ $'\n'"$AVAIL_REPOS"$'\n' =~ $'\n'"$CURRENT_REPO"$'\n' ]] && break
        typer "The specified repository does not exist.\n"
    done

    # TODO LET THE USER CHOOSE/SEE THE CURRENT BUCKETS
    get_variable "\nInsert the bucket name:" BUCKET_NAME "Bucket"
    get_variable "\nInsert the full path of the folder you want to backup: " FULLPATH_FOLDER "Folder path"
    # TODO CHECK IF FOLDER EXISTS AND ASK FOR CONFIRMATION
        # TODO Should also check if pheraps there is already a job for that folder
    JOB="$(basename "$FULLPATH_FOLDER")"

    # Replace spaces with hypens in case they are present
    JOB="${JOB// /-}"
    
    DESTINATION="${CURRENT_REPO}:${BUCKET_NAME}/${JOB}"
    
    # Create log directory if not already present
    mkdir -p /var/log/s3backupCopy

    # Log file
    LOG_FILE="/var/log/s3backupCopy/${JOB}.log"
    
    # Create scripts directory if not already present
    mkdir -p /opt/s3backupCopy

    # Generate the actual copy script
    cat << EOF > "/opt/s3backupCopy/${JOB}.sh"
#!/usr/bin/env bash
START_TIME="\$(timedatectl | grep "Local time" | awk -F': ' '{print \$2}')"

rclone sync --progress --log-file "${LOG_FILE}" --log-level INFO --progress-terminal-title "$FULLPATH_FOLDER" "$DESTINATION"
rclone check --size-only "${FULLPATH_FOLDER}" "${DESTINATION}"

EXIT_STATUS=\$?
LAST_TIME="\$(timedatectl | grep "Local time" | awk -F': ' '{print \$2}')"

if [ \$EXIT_STATUS -eq 0 ]; then
    STATUS="Success"
    TRANSFERS="\$(cat ${LOG_FILE} | awk '/INFO/{last=NR} {lines[NR]=\$0} END{for(i=last+1;i<=NR;i++) print lines[i]}')"
else
    TRANSFERS=""
    STATUS="Failed"
fi

TOTAL_DATA="\$(du -hs "${FULLPATH_FOLDER}" | awk '{print \$1}')"
 
REPORT="\$(printf "Subject: [\${STATUS}] S3BackupCopy ${JOB}\n\n\
Job started at \${START_TIME}\n\n\
Job ended with \${STATUS} at \${LAST_TIME}\n\n\
Total source folder size: \${TOTAL_DATA}\n\n\
\${TRANSFERS}")"

# echo "\$REPORT"
EOF
    chmod +x "/opt/s3backupCopy/${JOB}.sh"

    # Create systemd service for the job
    cat << EOF > "/etc/systemd/system/s3backupCopy_${JOB}.service"
[Unit]
Description=Backup copy job for $FULLPATH_FOLDER

[Service]
Type=simple
ExecStart="/opt/s3backupCopy/${JOB}.sh"
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    # Ask user about scheduling
    typer "\nWhen do you want to execute this job?"
    typer "\nThis is the syntax:"
    typer "\nDayOfWeek Year-Month-Day Hour:Minute:Second"
    typer "\nLeave blank to not specify.\nUse '*' for all the time.\n\n"

    while true; do
        typer "Specify a scheduling time:\n"
	read SCHEDULING
	NEXT_RUN=$(systemd-analyze calendar --iterations 5 "${SCHEDULING}" 2>/dev/null)
	if [ $? -eq 0 ]; then
	   typer "\nThose would be the next 5 scheduling for the job:\n"
	   printf "${NEXT_RUN}\n"
	   typer "Is this ok? [y/N]: "
	   read choice
	   [ "$choice" = "y" ] && break
	   printf "\n"
        else
	   typer "\nThe scheduling is not correct, please try again.\n"
	fi
    done

    # Create systemd timer for service
    cat << EOF > "/etc/systemd/system/s3backupCopy_${JOB}.timer"
[Unit]
Description=Backup copy job timer for '${JOB}.service'

[Timer]
OnCalendar=${SCHEDULING}
Persistent=false

[Install]
WantedBy=timers.target
EOF
    typer "Do you want to enable this job? [y/N]: "
    read choice
    if [ "$choice" = "y" ]; then
        systemctl enable --now "s3backupCopy_${JOB}.timer" >/dev/null 2>&1
        typer "\nJob ${JOB} was added and enabled succesfully!\n"
    else
	typer "Job ${JOB} was added succesfully but not enabled!\n" 
    fi
}

# Function to list all the jobs, both active and inactive
list_jobs() {
    local INACTIVES
    local ACTIVES
    local active_job
    local inactive_job
    for x in $(ls /etc/systemd/system/s3backupCopy_*.timer 2>/dev/null); do
	[[ "$(systemctl status $(basename $x))" == *"Active: inactive"* ]] && \
	   inactive_job=$(echo $x | sed 's/.*s3backupCopy_//')
            INACTIVES+=("${inactive_job%.*}")
	[[ "$(systemctl status $(basename $x))" == *"Active: active"* ]] && \
	   active_job=$(echo $x | sed 's/.*s3backupCopy_//')
	   ACTIVES+=("${active_job##*/}")
    done
    typer "\nThese are the active jobs:\n"
    for item in ${ACTIVES[@]}; do
        typer "${item}\n"
    done
    typer "\nThese are the inactive jobs:\n"
    for item in ${INACTIVES[@]}; do
        typer "${item}\n"
    done

    typer "\nTo analyze them use 'systemctl status <job_name>.timer' and 'systemctl status <job_name>.timer'\n"
    typer "You can find the logs at '/var/log/s3backupCopy/<job_name>.log'\n"
}

list_repositories() {
    typer "These are the current repositories:\n"
    typer -s 0.005 "$(cat /root/.config/rclone/rclone.conf 2>/dev/null)"
}

remove_job() {
    local job
    local to_delete

    echo -e "\nThose are the current jobs:"
    for x in $(ls /etc/systemd/system/s3backupCopy_*.timer 2>/dev/null); do
	job=$(echo $x | sed 's/.*s3backupCopy_//')
	typer "${job%.*}\n"
    done
    get_variable "\nWhich one do you want to delete?: " toDelete "Job"
    # TODO check if the job exists (needs to be accurate or could risk removing some other files)
    typer "Deleting this job will also remove any log associated with it.\n\
Do you wish to continue? [y/N]: "
    read choice 
    [ $choice = "y" ] || return 1

    # TODO check if the job is currently running
    systemctl stop "/etc/systemd/system/s3backupCopy_${toDelete}.timer" >/dev/null 2>&1
    systemctl disable "/etc/systemd/system/s3backupCopy_${toDelete}.timer" >/dev/null 2>&1
    rm "/etc/systemd/system/s3backupCopy_${toDelete}.timer" 2>/dev/null
    rm "/etc/systemd/system/s3backupCopy_${toDelete}.service" 2>/dev/null
    rm "/opt/s3backupCopy/${toDelete}.sh" 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1
    rm "/var/log/s3backupCopy/${toDelete}.log" 2>/dev/null
}

menu() {
    while true; do
	printf "\n\n\n"
        echo "--------------------------------------"
        echo "-               MENU                 -"
        echo "--------------------------------------"
        echo "1) Add a new repository"
        echo "2) Add jobs to an existing repository"
        echo "3) List current jobs"
        echo "4) List current repositories"
        echo "5) Remove a repository"
        echo "6) Remove a job"
        echo "7) Disable a job"
        echo "8) Reschedule a job"
	echo "9) Quit"
        typer "Choose an option [1-9]: "

        read choice
        case $choice in
            1)
	       create_repo
		;;
	   2)
	       create_job
		;;
	   3)
		list_jobs
		;;
	   4)
		list_repositories
		;;
	   5)
		typer "Not implented yet"
		;;
	   6)
		remove_job
		;;
	   7)
		typer "Not implented yet"
		;;
	   8)
		typer "Not implented yet"
		;;
	   9)
	       return 0
		;;
	   *)
		continue
		;;
        esac
    done
}

############################# SCRIPT #############################
cat << "EOF"
 _____  ___________            _                _____                   
/  ___||____ | ___ \          | |              /  __ \                  
\ `--.     / / |_/ / __ _  ___| | ___   _ _ __ | /  \/ ___  _ __  _   _ 
 `--. \    \ \ ___ \/ _` |/ __| |/ / | | | '_ \| |    / _ \| '_ \| | | |
/\__/ /.___/ / |_/ / (_| | (__|   <| |_| | |_) | \__/\ (_) | |_) | |_| |
\____/ \____/\____/ \__,_|\___|_|\_\\__,_| .__/ \____/\___/| .__/ \__, |
                                         | |               | |     __/ |
                                         |_|               |_|    |___/ 
EOF

# Checks for root and dependencies
checks

# Interactive menu
menu 

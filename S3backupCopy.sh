#!/usr/bin/env bash
# TODO
# Cleanup Function
# Various checks if folder paths or name exist (like bucket, repo, etc...)
# Autocomplete for read
# Rotate logs
# Check if the added job already exists
# Add check for repository to see it exists, otherwise rclone gets stuck forever when trying to sync

############################# FUNCTIONS #############################

# Function used to make printing of text a little fancier,
# as it being typed in real time
typer() {
    
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

# Function to always double check if the user typed the correct input
get_input() {
    local prompt="$2"   # The prompt text
    local varcheck="$3" # Description of the variable to double check
    local value

    # Redirect all text to stderr, except the last prinf which 
    # acts as a return string
    while true; do
        typer "${prompt}" >&2
        read value
        typer "${varcheck} = \"${value}\". Is this correct? [y/n]: " >&2
        read confirm
        case "${confirm}" in
            Y|y ) break ;;
            N|n ) typer "Let's try again.\n" >&2;;
            * ) typer "Please answer y or n.\n" >&2;;
        esac
    done

    # Return the value to caller
    printf '%s' "$value"
}

# This function is used to create/modify the rclone.conf file with a new repository
create_repo() {
    local s3_server
    local access_key
    local secret_key
    local repo_name

    while true; do
        repo_name=$(get_input repo_name "Insert a custom repository name: " "Repository name")
        grep -w "$repo_name" /root/.config/rclone/rclone.conf >/dev/null 2>&1 || break
        sleep 1
        typer "\nThis repo already exists, please insert a different one, or quit if you want to add jobs to it.\n\n"
    done
    s3_server=$(get_input s3_server "Insert the S3 server (https://example.com): " "S3 Server")
    access_key=$(get_input access_key "Insert the access key token: " "Access key token")
    secret_key=$(get_input secret_key "Insert the secret key token: " "Secret key")
    mkdir -p /root/.config/rclone/
    cat << RCLONECONF >> /root/.config/rclone/rclone.conf

[$repo_name]
type = s3
provider = Other
access_key_id = $access_key
secret_access_key = $secret_key
endpoint = $s3_server
acl = bucket-owner-full-control
force_path_style = true
RCLONECONF

    typer "\nThe repository was succesfully added!\n"
}

# This is the function which creates the script for the backup and the corresponding systemd units
create_job() {
    local avail_repos
    local current_repo
    avail_repos=$(grep -E '^\[[^]]+\]$' /root/.config/rclone/rclone.conf 2>/dev/null | sed 's/^\[\(.*\)\]$/\1/')
    if [ -z "${avail_repos}" ]; then
        typer "\nYou have no repositories, first add one, then you can add jobs to it.\n"
	return 0
    fi
    typer "\nFirst, you need to choose a repository for your job. These are the available ones: \n${avail_repos}\n"
    while true; do
        current_repo=$(get_input current_repo "Which do you want to use?: " "Repository")
	[[ $'\n'"${avail_repos}"$'\n' =~ $'\n'"${current_repo}"$'\n' ]] && break
        typer "The specified repository does not exist.\n"
    done

    # TODO LET THE USER CHOOSE/SEE THE CURRENT BUCKETS
    BUCKET_NAME=$(get_input BUCKET_NAME "\nInsert the bucket name:" "Bucket")
    FULLPATH_FOLDER=$(get_input FULLPATH_FOLDER "\nInsert the full path of the folder you want to backup: " "Folder path")
    # TODO CHECK IF FOLDER EXISTS AND ASK FOR CONFIRMATION
        # TODO Should also check if pheraps there is already a job for that folder
    JOB="$(basename "$FULLPATH_FOLDER")"

    # Replace spaces with hypens in case they are present
    JOB="${JOB// /-}"
    
    DESTINATION="${current_repo}:${BUCKET_NAME}/${JOB}"
    
    # Create log directory if not already present
    mkdir -p /var/log/s3backupCopy

    # Log file
    LOG_FILE="/var/log/s3backupCopy/${JOB}.log"
    
    # Create scripts directory if not already present
    mkdir -p /opt/s3backupCopy

    # Generate the actual copy script
    cat << COPYSCRIPT > "/opt/s3backupCopy/${JOB}.sh"
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
COPYSCRIPT
    chmod +x "/opt/s3backupCopy/${JOB}.sh"

    # Create systemd service for the job
    cat << SYSTEMDSERVICE > "/etc/systemd/system/s3backupCopy_${JOB}.service"
[Unit]
Description=Backup copy job for $FULLPATH_FOLDER

[Service]
Type=simple
ExecStart="/opt/s3backupCopy/${JOB}.sh"
Restart=no

[Install]
WantedBy=multi-user.target
SYSTEMDSERVICE
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
    cat << SYSTEMDTIMER > "/etc/systemd/system/s3backupCopy_${JOB}.timer"
[Unit]
Description=Backup copy job timer for '${JOB}.service'

[Timer]
OnCalendar=${SCHEDULING}
Persistent=false

[Install]
WantedBy=timers.target
SYSTEMDTIMER

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
    local running_list
    local running_job
    local actives
    local active_job
    local inactives
    local inactive_job

    running_list=$(systemctl list-units --state=running --no-pager --no-legend | grep s3backupCopy | grep loaded | awk '{print $1}' | grep service)
    typer "\nThese are the running jobs:\n"
    for x in ${running_list}; do
        running_job=$(echo "$x" | sed 's/.*s3backupCopy_//')
        typer "${running_job%.*}\n"
    done

    for x in $(ls /etc/systemd/system/s3backupCopy_*.timer 2>/dev/null); do
        if [[ "$(systemctl status $(basename $x))" == *"Active: active"* ]]; then
    	    active_job=$(echo $x | sed 's/.*s3backupCopy_//')
    	    actives+=("${active_job%.*}")
    	elif [[ "$(systemctl status $(basename $x))" == *"Active: inactive"* ]]; then
    	    inactive_job=$(echo $x | sed 's/.*s3backupCopy_//')
            inactives+=("${inactive_job%.*}")
        fi
    done
    typer "\nThese are the active jobs:\n"
    for item in ${actives[@]}; do
        typer "${item}\n"
    done
    typer "\nThese are the inactive jobs:\n"
    for item in ${inactives[@]}; do
        typer "${item}\n"
    done

    typer "\nTo analyze them use 'systemctl status <job_name>.timer' and 'systemctl status <job_name>.service'\n"
    typer "You can find the logs at '/var/log/s3backupCopy/<job_name>.log'\n"
}

list_repositories() {
    typer "These are the current repositories:\n"
    typer -s 0.005 "$(cat /root/.config/rclone/rclone.conf 2>/dev/null)"
}

remove_job() {
    echo -e "\nThose are the current jobs:"
    for x in $(ls /etc/systemd/system/s3backupCopy_*.timer 2>/dev/null); do
	    job=$(echo $x | sed 's/.*s3backupCopy_//')
	    typer "${job%.*}\n"
    done

    toDelete=$(get_variable toDelete "\nWhich one do you want to delete?: " "Job")
    if ! systemctl cat s3backupCopy_${toDelete} >/dev/null 2>&1; then
        typer "The specified job \"${toDelete}\" does not exist.\n"
        return 1
    fi

    typer "Deleting this job will also remove any log associated with it.\n\
Do you wish to continue? [y/N]: "
    read choice 
    [ $choice = "y" ] || return 1

    if systemctl is-active --quiet s3backupCopy_${toDelete}.service; then
        typer "Job \"${toDelete}\" is currently running. Wait for it to finish or stop it manually.\n"
        return 1
    fi

    systemctl stop "s3backupCopy_${toDelete}.timer" >/dev/null 2>&1
    systemctl disable "s3backupCopy_${toDelete}.timer" >/dev/null 2>&1
    rm "/etc/systemd/system/s3backupCopy_${toDelete}.timer" 2>/dev/null
    rm "/etc/systemd/system/s3backupCopy_${toDelete}.service" 2>/dev/null
    rm "/opt/s3backupCopy/${toDelete}.sh" 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1
    rm "/var/log/s3backupCopy/${toDelete}.log" 2>/dev/null
    typer "Job \"${toDelete}\" removed correctly!\n"

    unset job
    unset toDelete
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
if [ "$(whoami)" != "root" ]; then
    typer "\nYou need to be root to execute this script.\n" && exit 126
fi

# Check if rclone is installed
if ! which rclone >/dev/null 2>&1; then
    typer "\nRclone is needed to execute this script.\n"
exit 1
fi


# Interactive menu
while true; do
    cat << DYNMENU

--------------------------------------
-               MENU                 -
--------------------------------------
1) Add a new repository
2) Create new job
3) List current jobs
4) List current repositories
5) Remove a job
6) Quit
DYNMENU
    typer "Choose an option [1-6]: "
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
             remove_job
             ;;
            6)
             exit
             ;;
            *)
             continue
             ;;
        esac
done

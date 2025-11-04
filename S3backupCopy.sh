#!/usr/bin/env bash
# TODO
# Cleanup Function
# split add_job function
# Rotate logs

############################# FUNCTIONS #############################
# Variables that start with underscore "_" sign are present only inside heredocs

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

    # Redirect all text to stderr, except the last printf which 
    # acts as a return string
    while true; do
        typer "${prompt}" >&2
        read -e value
        typer "${varcheck} = \"${value}\". Is this correct? [y/N]: " >&2
        read confirm
        case "${confirm}" in
            Y|y ) break ;;
            * ) typer "Let's try again.\n" >&2;;
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
    local avail_repos_array
    local current_repo
    local bucket_name
    local fullpath_folder
    local toadd_job
    local destination
    local log_file
    local next_run
    local buckets
    local buckets_array
    local job
    local job_array
    local custom_job

    avail_repos=$(grep -E '^\[[^]]+\]$' /root/.config/rclone/rclone.conf 2>/dev/null | sed 's/^\[\(.*\)\]$/\1/')
    if [ -z "${avail_repos}" ]; then
        typer "\nYou have no repositories, first add one, then you can add jobs to it.\n"
	    return 1
    else
        for repo in "${avail_repos}"; do
            avail_repos_array+=($repo)
        done
    fi

    typer "\nFirst, you need to choose a repository for your job. These are the available ones:\n"
    select current_repo in "${avail_repos_array[@]}"; do
        if [[ -n "${current_repo}" ]]; then
            typer "Repository: \"${current_repo}\"\n"
            break
        else
           typer "Invalid choice.\n"
        fi
    done

    typer "Fetching available buckets...\n"
    buckets="$(rclone lsd ${current_repo}: 2>/dev/null)"
    if [ $? -ne 0 ]; then
        typer "There is an error with this repo, please try again.\n"
        return 1
    fi
    for x in "${buckets}"; do
        buckets_array+=( $(echo "${x}" | awk '{print $5}') )
    done
    typer "Select a bucket:\n"
    select bucket_name in "${buckets_array[@]}"; do
        if [[ -n "${bucket_name}" ]]; then
            typer "Bucket: \"${bucket_name}\"\n"
            break
        else
           typer "Invalid choice.\n"
        fi
    done

    while true; do
        fullpath_folder=$(get_input fullpath_folder "\nInsert the full path of the folder you want to backup: " "Folder path")
        # Check that folder is an absolute path and it exists
        if ls "${fullpath_folder}" >/dev/null 2>&1 && [[ "${fullpath_folder}" == /* ]]; then
            break
        fi
        typer "The current folder does not exist or it is not an absolute path. Try again.\n"
    done

    # Remove the last "/" if present
    fullpath_folder="${fullpath_folder%/}"

    # Check if a job with the given fullpath_folder already exists
    for item in $(ls /opt/s3backupCopy/); do
        if grep -E "\"${fullpath_folder}/?\"" "/opt/s3backupCopy/${item}" >/dev/null 2>&1; then
            typer "There is already a job with this folder. Skipping...\n"
            return 1
        fi
    done

    # Replace spaces with hyphens in case they are present
    toadd_job="${fullpath_folder// /-}"

    # Replaces "/" with "_"
    toadd_job="${toadd_job//\//_}"

    # Remove the first "_" for easier readability
    toadd_job="${toadd_job/_/}"

    # Create array for later check
    for x in $(ls /etc/systemd/system/s3backupCopy_*.timer 2>/dev/null); do
	    job=$(echo $x | sed 's/.*s3backupCopy_//')
        job_array+=("${job%.*}")
    done
    while true; do
        typer "Do you want to give this job a custom name? (default name: \"${toadd_job}\"): [y/n]: "
        read confirm
        case "${confirm}" in
            Y|y ) 
                custom_job=$(get_input custom_job "Insert job custom name (forbidden chars: \" \\ / - _ space \"): " "Job Custom name")
                # Check for forbidden characters
                if [[ "${custom_job}" =~ [\ \\_/\-] ]]; then
                    typer "Error: Input cannot contain \" \\ / - _ space \"\n\n"
                    continue
                fi
                # Check if job with toadd_job name already exists
                if [[ ! " ${job_array[*]} " == *" ${custom_job} "* ]]; then
                    toadd_job="${custom_job}"
                    typer "\nJob name is: \"${toadd_job}\"\n"
                    break
                fi
                typer "There is already a job with name: \"${custom_job}\".\n\n" ;;
            N|n ) 
                typer "\nJob name is: \"${toadd_job}\"\n\n"
                break ;;
            * ) 
                typer "Please answer y or n.\n" >&2 ;;
        esac
    done

    destination="${current_repo}:${bucket_name}/${toadd_job}"
    
    # Create log directory if not already present
    mkdir -p /var/log/s3backupCopy

    # Log file
    log_file="/var/log/s3backupCopy/${toadd_job}.log"
    
    # Create scripts directory if not already present
    mkdir -p /opt/s3backupCopy

    # Generate the actual copy script
    cat << COPYSCRIPT > "/opt/s3backupCopy/${toadd_job}.sh"
#!/usr/bin/env bash
rclone lsd "${current_repo}":"${bucket_name}" >/dev/null 2>&1
if [ \$? -ne 0 ]; then
    _report="\$(printf "Subject: [Failed] S3BackupCopy ${toadd_job}\n\nThere was an error trying to reach the repository or the bucket.")"
    _error="1"
else
    _start_time="\$(timedatectl | grep "Local time" | awk -F': ' '{print \$2}')"
    
    rclone sync --progress --log-file "${log_file}" --log-level INFO --progress-terminal-title "$fullpath_folder" "$destination"
    rclone check --size-only "${fullpath_folder}" "${destination}"
    
    _exit_status=\$?
    _last_time="\$(timedatectl | grep "Local time" | awk -F': ' '{print \$2}')"
    _total_data="\$(du -hs "${fullpath_folder}" | awk '{print \$1}')"
    
    if [ \${_exit_status} -eq 0 ]; then
        _transfers="\$(cat ${log_file} | awk '/INFO/{last=NR} {lines[NR]=\$0} END{for(i=last+1;i<=NR;i++) print lines[i]}' | head -n 1 | awk '{print \$1,\$2,\$3,\$4,\$5,\$6,\$7}')"
        _elapsed="\$(cat ${log_file} | awk '/INFO/{last=NR} {lines[NR]=\$0} END{for(i=last+1;i<=NR;i++) print lines[i]}' | tail -n 2)"
        _misc="\$(cat ${log_file} | awk '/INFO/{last=NR} {lines[NR]=\$0} END{for(i=last+1;i<=NR;i++) print lines[i]}' | tail -n +2 | head -n -2)"
        _report="\$(echo -e "Subject: [Success] S3BACKUPCOPY ${toadd_job}\n\nJob ended with status: Success\n\n\${_start_time}    JOB START TIME\n\${_last_time}    JOB END TIME\n\n\${_transfers} in \${_elapsed}\n\nTotal source folder size: \${_total_data}\n\${_misc}")"
        _error="0"
    
    else
        _report="\$(echo -e "Subject: [Failed] S3BACKUPCOPY ${toadd_job}\n\nJob ended with status: Failed\n\n\${_start_time}    JOB START TIME\n\${_last_time}    JOB END TIME\n\nTotal source folder size: \${_total_data}\nCheck the logs to see the error.")"
        _error="1"
    fi
fi

# echo "\${_report}" 
exit \${_error}
COPYSCRIPT
    chmod +x "/opt/s3backupCopy/${toadd_job}.sh"

    # Create systemd service for the job
    cat << SYSTEMDSERVICE > "/etc/systemd/system/s3backupCopy_${toadd_job}.service"
[Unit]
Description=Backup copy job for $fullpath_folder

[Service]
Type=simple
ExecStart="/opt/s3backupCopy/${toadd_job}.sh"
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
	    read scheduling
	    next_run=$(systemd-analyze calendar --iterations 5 "${scheduling}" 2>/dev/null)
	    if [ $? -eq 0 ]; then
	       typer "\nThose would be the next 5 scheduling for the job:\n"
	       printf "${next_run}\n"
	       typer "Is this ok? [y/N]: "
	       read choice
	       [ "$choice" = "y" ] && break
	       printf "\n"
        else
	       typer "\nThe scheduling is not correct, please try again.\n"
	    fi
    done

    # Create systemd timer for service
    cat << SYSTEMDTIMER > "/etc/systemd/system/s3backupCopy_${toadd_job}.timer"
[Unit]
Description=Backup copy job timer for 's3backupCopy_${toadd_job}.service'

[Timer]
OnCalendar=${scheduling}
Persistent=false

[Install]
WantedBy=timers.target
SYSTEMDTIMER

    typer "Do you want to enable this job? [y/N]: "
    read choice
    if [ "$choice" = "y" ]; then
        systemctl enable --now "s3backupCopy_${toadd_job}.timer" >/dev/null 2>&1
        typer "\nJob \"${toadd_job}\" was added and enabled succesfully!\n"
    else
	    typer "Job \"${toadd_job}\" was added succesfully but not enabled!\n" 
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
    local job
    local job_array
    local to_delete

    for x in $(ls /etc/systemd/system/s3backupCopy_*.timer 2>/dev/null); do
	    job=$(echo $x | sed 's/.*s3backupCopy_//')
        job_array+=("${job%.*}")
    done
    if [ ${#job_array[@]} -eq 0 ]; then
        typer "There are no jobs.\n"
        return 0
    fi

    typer "\nThose are the current jobs:\nWhich one do you want to delete?\n"
    select to_delete in "${job_array[@]}"; do
        if [[ -n "${to_delete}" ]]; then
            typer "Job to delete: \"${to_delete}\"\n"
            break
        else
           typer "Invalid choice.\n"
        fi
    done

    typer "Deleting this job will also remove any log associated with it.\nDo you wish to continue? [y/N]: "
    read choice 
    [ $choice = "y" ] || return 1

    if systemctl is-active --quiet s3backupCopy_${to_delete}.service; then
        typer "Job \"${to_delete}\" is currently running. Wait for it to finish or stop it manually.\n"
        return 1
    fi

    systemctl stop "s3backupCopy_${to_delete}.timer" >/dev/null 2>&1
    systemctl disable "s3backupCopy_${to_delete}.timer" >/dev/null 2>&1
    rm "/etc/systemd/system/s3backupCopy_${to_delete}.timer" 2>/dev/null
    rm "/etc/systemd/system/s3backupCopy_${to_delete}.service" 2>/dev/null
    rm "/opt/s3backupCopy/${to_delete}.sh" 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1
    rm "/var/log/s3backupCopy/${to_delete}.log" 2>/dev/null
    typer "Job \"${to_delete}\" removed correctly!\n"
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
             typer "Bye!\n"
             exit
             ;;
            *)
             continue
             ;;
        esac
done

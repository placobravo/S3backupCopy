# S3backupCopy

## What this is
S3backupCopy is bash script used to make copies of local folders on a remote S3 repository.
It takes advantage of rclone and systemd units+timers to schedule the backups.
Essentially it is an interactive menu which generates the actual *copy_script* and the
corresponding systemd units.

## What this is NOT
S3backupCopy is not a fully fledged backup app, it has some basic functions which only help
the management tasks, but it is not supposed to be a complete backup product.
Administration of the backups require some general knowledge about linux and systemd.
If you are looking for something more complete, tools like Restic are probably what you
are looking for.

## Usage
Make the script executable and run ```sudo /path/to/S3backupCopy.sh```.
The script should be used everytime you want to add a job, remove an existing one or add a new repository. All of these actions can be done manually but this can be prone to error, so it is recommended to use the script.

### Functions
- ***Create repo***: add an s3 compatible repository. Requires an *access_key_id*, a *secret_access_key* and an *s3_server*. It could theoretically work with other types of storage but this is not implemented in the script, and should probably be tested. Compatible services can be found on the [rclone website](https://rclone.org/#providers).
- ***Create job***: create a new backup job from a local folder to the targeted repository.
You can give a custom name to the job and schedule the time. Time uses systemd timer syntax. 
This creates the *copy_script* in ```/opt/s3backupCopy```, the corresponding systemd service unit and the systemd timer unit with the given scheduling. 
- ***List_jobs***: list the running jobs, the enabled jobs, the active jobs and the inactive jobs.
Running jobs are currently syncing data and waiting to finish.
Active jobs will run periodically based on the given scheduling. Keep in mind that they may or may not be enabled.
Inactive jobs are present in the system but they are disabled and will not run.
Enabled jobs will become active automatically at system boot.
Disabled jobs will not become active automatically at system boot.

|     _Job_    |                  **Active**                 |                   **Inactive**                  |
|:------------:|:-------------------------------------------:|:-----------------------------------------------:|
|  **Enabled** | Scheduled and will start at system boot     | Scheduled but will not start at system boot     |
| **Disabled** | Not scheduled but will start at system boot | Not scheduled and will not start at system boot |

- ***List_repositories***: simply list the configured repositories present in ```/root/.config/rclone.conf```.
- ***Remove_job***: remove a job and its associated logs. If the job is running this option will not work.
- ***Deactivate all jobs***: deactivate all the currently active jobs. If a job is running it will be skipped, and it will be checked again after 2 minutes. This will repeat until all jobs are made inactive.

### Notifications
By default the *copy_script* does not output any text once it finishes. It simply exits with 0 or 1 depending on success or failure of the rclone command. That said, a default report is made and can be used to send notifications, for example sending an email using a client like *msmtp*. 
The report is inside the variable ```$_report```.

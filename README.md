# Automated VirtualBox VM Backups

## Backup_VirtualBox_VMs.pl

A Perl program that automates crash-consistent backups of VirtualBox virtual machines using `VBoxManage` live snapshots and `rsync`.

### Features

*   **Near-zero downtime backups:** Uses live snapshots for running VMs, allowing for backups without interrupting active services.
*   **Efficient mirroring with `rsync`:** Optimized for both local and slow storage by using incremental mirroring (`--inplace`) to transfer only changed data, and the `--delete` option to ensure a precise replica.
*   **Intelligent VM handling:** The script automatically adapts its strategy based on the VM's state:
    *   **For running VMs:** Creates and manages a live snapshot to safely copy the disk files.
    *   **For powered-off VMs:** Proceeds directly to the `rsync` operation, as the files are already in a consistent state.
*   **Robust and safe operation:** Includes error handling for all critical `VBoxManage` and `rsync` commands, preventing the script from proceeding if an essential step fails.
*   **Quiet and summary-focused output:** The snapshot commands are silent, and the `rsync` output is filtered to show only a final summary, keeping the console clean.
*   **Flexible filtering:** Allows for skipping or limiting backups to specific VMs using command-line options.

### Usage Examples

```sh
# Backup all VMs to the --budir directory, but first show the plan and verify with the user
./Backup_VirtualBox_VMs.pl --verify --budir /vol/backups/VirtualBoxVMs

# Backup two specific VMs
./Backup_VirtualBox_VMs.pl --budir /vol/backups/VirtualBoxVMs --only "Win10 Dev" --only "Ubuntu Server"

# Backup all VMs except two specific ones, and verify with the user before proceeding
./Backup_VirtualBox_VMs.pl --verify --budir /vol/backups/VirtualBoxVMs --skip "Win7" --skip "Fedora39"
```

## Rclone_VirtualBox_VMs.sh

A bash program that uses rclone to sync backups to cloud drives.

### Features

* The program breaks *.vdi files into smaller chunks (500MB by default) for more efficient cloud syncing.
* The program uses rlcone's md5sum command and "dd | md5sum" to compare local *.vdi files to their equivalent cloud parts.
* If a sync is needed, the program uses split to create VDI file chunks before running rclone sync.
* The program writes and syncs a README file with instuctions for reconstituting VDI files from the parts.

# Collaboration
These programs were written by Lester Hightower, in collaboration with a large language model trained by Google. 

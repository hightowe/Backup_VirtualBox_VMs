#!/bin/bash

# ==============================================================================
# SCRIPT: VirtualBox VDI Sequential Backup and Rclone Uploader
#
# DESCRIPTION:
# This script converts large VDI files within VirtualBox VM directories into
# smaller, deterministic chunks using the standard 'split' command,
# synchronizes those directories to a pCloud remote using rclone, and cleans
# up the local chunks afterwards. This minimizes temporary local disk space
# usage during the backup process.
#
# A file named 'README_VDI_RECONSTITUTION.txt' containing restoration
# instructions is temporarily created in each VM directory and synced to
# the cloud backup destination for future reference.
#
# PREREQUISITES:
# 1. 'split', 'cat' and 'rclone' must be installed (standard on Linux).
#    Note: rclone v1.72.1 was used during development of this program.
# 2. The requisite rclone remote must be configured.
#
# NOTE: The 'split' command ensures deterministic output (hashes remain
# identical regardless of when the script runs or source timestamp changes),
# which is vital for efficient cloud synchronization/deduplication.
#
# RECONSTITUTION (How to restore the VDI files):
# To restore a VDI file from the cloud backup (after downloading all parts):
# 1. Ensure all the numbered split parts (e.g., 'MyVM.vdi.part.001', '.002', etc.)
#    are present in the same directory on your local machine.
# 2. Use the 'cat' command to concatenate the files in correct order back
#    into the original VDI file name:
#    $ cat MyVM.vdi.part.* > MyVM.vdi
# 3. This will reassemble the single, original 'MyVM.vdi' file.
# 4. You can then attach the reconstituted VDI file to your VirtualBox VM setup.
#
# Written in December of 2025 by Lester Hightower, in collaboration with a
# large language model trained by Google.
# ==============================================================================

#DRY_RUN="--dry-run" # If set, will --dry-run rclone commands.
SOURCE_BASE_DIR="/vol/2_ntfs/backups/VirtualBoxVMs"
RCLONE_REMOTE_BASE="pcloud:/backups/VirtualBoxVMs"
#RCLONE_TRACK_RENAMES="--track-renames" # Uncomment if renames occurred.
RCLONE_MULTI_THREAD_STREAMS="1" # 4=default. For faster upstreams, might help
RCLONE_VERBOSITY="-v"      # The more v's the more verbose
RCLONE_CHECKERS_LIMIT=16   # Files compared concurrently (Default: 8)
RCLONE_TRANSFERS_LIMIT=1   # Files transferred concurrently (Default: 4)
RCLONE_BWLIMIT="30M"       # The rclone --bwlimit
CHUNKS_SUFFIX_LEN=4        # Numeric padding length (e.g., 4 = 0000)
CHUNK_SIZE_MB=500          # The size of the *.vdi.part.NNNN files.
CHUNK_SIZE="${CHUNK_SIZE_MB}M"
README_FILENAME="README_VDI_RECONSTITUTION.txt"

# Directories to skip, named as they appear under SOURCE_BASE_DIR
SKIP_DIRS=()

# Define the content of the README file with reconstitution instructions
read -r -d '' README_CONTENT << EOM
==========================================================================
VDI ARCHIVE RECONSTITUTION INSTRUCTIONS
==========================================================================
These files are simple chunks of the original VirtualBox VDI disk image,
created using the standard Linux 'split' command.

To restore the original VDI file:

1. Ensure all the numbered split parts (e.g., 'MyVM.vdi.part.0000')
   are present in the same directory on your local machine.

2. Use the 'cat' command to concatenate the files in correct order:
   $ cat MyVM.vdi.part.* > MyVM.vdi

3. This will reassemble the single, original 'MyVM.vdi' file.

4. You can then attach the reconstituted VDI file to your VirtualBox VM.
==========================================================================
EOM

# To try to catch and log the script being killed
script_killed() {
  local signal_name="$1"
  echo "--- Script killed by $signal_name at $(date) ---"
}
trap script_killed SIGHUP
trap script_killed SIGINT
trap script_killed SIGTERM

echo "Starting VirtualBox VDI Backup with MD5 Block Pre-testing"
echo "Source Base Directory: $SOURCE_BASE_DIR"

readarray -d '' VM_DIRS < <(find "$SOURCE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

for vm_dir in "${VM_DIRS[@]}"; do
    DIR_NAME=$(basename "$vm_dir")

    SKIP=false
    for skip_dir in "${SKIP_DIRS[@]}"; do
        [[ "$DIR_NAME" == "$skip_dir" ]] && SKIP=true && break
    done

    if [ "$SKIP" == true ]; then
        echo -e "\n--- SKIPPING Directory: $DIR_NAME ---"
        continue
    fi

    echo -e "\n--- Processing VM Directory: $vm_dir ---"
    RELATIVE_PATH=$(realpath --relative-to="$SOURCE_BASE_DIR" "$vm_dir")
    RCLONE_DESTINATION="$RCLONE_REMOTE_BASE/$RELATIVE_PATH"

    # Default rclone flags for this VM
    # Start with --delete-excluded and remove it to protect remote parts
    RCLONE_DELETE_FLAG="--delete-excluded"
    RCLONE_FILTER_ARGS=("--filter" "- *.vdi") # Don't send the *.vdi files

    # Capture the *.vdi files in the current VM directory
    readarray -d '' VDI_FILES < <(find "$vm_dir" -maxdepth 1 -name "*.vdi" -print0)

    for vdi_file in "${VDI_FILES[@]}"; do
        VDI_NAME=$(basename "$vdi_file")
        echo "  Comparing md5sums of remote parts to $VDI_NAME"

        # Fetch remote MD5s into an associative array
        declare -A REMOTE_MD5S=()  # Declare and set to empty each loop pass
        while read -r md5 path; do
            part_name=$(basename "$path")
            REMOTE_MD5S["$part_name"]="$md5"
        done < <(rclone md5sum "$RCLONE_DESTINATION" --include "${VDI_NAME}.part.*" 2>/dev/null)

        # Calculate required blocks
        FILE_SIZE=$(stat -c%s "$vdi_file")
        BYTES_PER_CHUNK=$((CHUNK_SIZE_MB * 1024 * 1024))
        TOTAL_BLOCKS=$(( (FILE_SIZE + BYTES_PER_CHUNK - 1) / BYTES_PER_CHUNK ))

        NEEDS_SYNC=false
        if [ ${#REMOTE_MD5S[@]} -ne $TOTAL_BLOCKS ]; then
            echo "    Block count mismatch (Local: $TOTAL_BLOCKS, Remote: ${#REMOTE_MD5S[@]}). Sync required."
            NEEDS_SYNC=true
        else
            for (( i=0; i<$TOTAL_BLOCKS; i++ )); do
                # Use CHUNKS_SUFFIX_LEN to pad the index (e.g., %04d)
                PART_LABEL=$(printf "%0${CHUNKS_SUFFIX_LEN}d" $i)
                PART_NAME="${VDI_NAME}.part.${PART_LABEL}"

                # Calculate local MD5 for the specific block using dd
                LOCAL_MD5=$(dd if="$vdi_file" bs=1M skip=$((i * CHUNK_SIZE_MB)) count=$CHUNK_SIZE_MB 2>/dev/null | md5sum | awk '{print $1}')

                if [[ "$LOCAL_MD5" != "${REMOTE_MD5S[$PART_NAME]}" ]]; then
                    echo -e "\n    Block $PART_LABEL differs. Sync required."
                    NEEDS_SYNC=true
                    break
                fi
                #echo -ne "    Verified md5sum for block $PART_LABEL/$((TOTAL_BLOCKS-1))\r"
            done
        fi

        if [ "$NEEDS_SYNC" = true ]; then
            echo "    Remote and local mismatch. Generating new split parts..."
            output_prefix="${vdi_file}.part."
            split -b "$CHUNK_SIZE" -d --suffix-length="$CHUNKS_SUFFIX_LEN" --verbose "$vdi_file" "$output_prefix"
            find "$vm_dir" -name "$(basename "$vdi_file").part.*" -exec touch -r "$vdi_file" {} \;
        else
            echo "    Remote and local match. Disabling --delete-excluded to protect remote parts."
            # To protect remote parts that aren't local, we MUST exclude them and turn off --delete-excluded
            RCLONE_FILTER_ARGS+=("--filter" "- ${VDI_NAME}.part.*")
            RCLONE_DELETE_FLAG=""
        fi
    done

    # Create README and Sync non-VDI files (or new parts)
    echo "$README_CONTENT" > "$vm_dir/$README_FILENAME"
    echo "  Rcloning $vm_dir to $RCLONE_DESTINATION"

    /bin/time rclone $DRY_RUN sync "$vm_dir" "$RCLONE_DESTINATION" \
         $RCLONE_VERBOSITY $RCLONE_TRACK_RENAMES \
         "${RCLONE_FILTER_ARGS[@]}" $RCLONE_DELETE_FLAG \
         --delete-after \
         --checkers "$RCLONE_CHECKERS_LIMIT" \
         --transfers "$RCLONE_TRANSFERS_LIMIT" \
         --bwlimit "$RCLONE_BWLIMIT" \
         --multi-thread-streams="$RCLONE_MULTI_THREAD_STREAMS" \
         --check-first \
         --progress \
         --inplace \
         --stats-one-line-date \
         --stats 2m

    # Cleanup local temporary files
    echo "  Cleaning up local temporary files..."
    find "$vm_dir" -name "*.vdi.part.*" -delete
    rm -f "$vm_dir/$README_FILENAME"

    echo "Finished processing directory: $vm_dir"
    echo "--------------------------------------------------"
done

echo -e "\nBackup process finished."

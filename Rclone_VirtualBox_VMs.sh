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

#COMPARE_ONLY=1  # Only compare VDI file parts, don't run rclone at all
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
# Directories to only do, named as they appear under SOURCE_BASE_DIR
#ONLY_DIRS=()

# Define the content of the README file with reconstitution instructions
read -r -d '' README_CONTENT << EOM
==========================================================================
VDI ARCHIVE RECONSTITUTION INSTRUCTIONS
==========================================================================
The *.vdi.part.NNNN files are simple chunks of the original VirtualBox VDI
disk image, created using the standard Linux 'split' command.

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
  exit 1
}
trap 'script_killed SIGHUP' SIGHUP
trap 'script_killed SIGINT' SIGINT
trap 'script_killed SIGTERM' SIGTERM

echo "Starting VirtualBox VDI Backup with MD5 Block Pre-testing"
echo "Source Base Directory: $SOURCE_BASE_DIR"

echo -e "\n=== Running Pre-flight Check for Remote Storage & MD5 Hashes ==="
if ! rclone lsd "$RCLONE_REMOTE_BASE" >/dev/null 2>&1; then
    echo -e "\n======================================================================"
    echo " FATAL ERROR: Cannot access RCLONE_REMOTE_BASE ($RCLONE_REMOTE_BASE)."
    echo " Please check network connection, rclone remote configuration, or path."
    echo "======================================================================\n"
    exit 1
fi

readarray -d '' VM_DIRS < <(find "$SOURCE_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -print0)

declare -A ALL_REMOTE_MD5S=()
PREFLIGHT_FAILED=false

for vm_dir in "${VM_DIRS[@]}"; do
    DIR_NAME=$(basename "$vm_dir")

    SKIP=false
    for skip_dir in "${SKIP_DIRS[@]}"; do
        [[ "$DIR_NAME" == "$skip_dir" ]] && SKIP=true && break
    done
    # If we haven't skipped yet, and the ONLY_DIRS whitelist exists, check it
    if ! $SKIP && [[ -n "${ONLY_DIRS+x}" ]] && (( ${#ONLY_DIRS[@]} > 0 )); then
        SKIP=true
        for only_dir in "${ONLY_DIRS[@]}"; do
            if [[ "$DIR_NAME" == "$only_dir" ]]; then
                SKIP=false
                break
            fi
        done
    fi

    if [ "$SKIP" == true ]; then
        echo "  [Pre-flight] Skipping directory: $DIR_NAME"
        continue
    fi

    RELATIVE_PATH=$(realpath --relative-to="$SOURCE_BASE_DIR" "$vm_dir")
    RCLONE_DESTINATION="$RCLONE_REMOTE_BASE/$RELATIVE_PATH"

    readarray -d '' VDI_FILES < <(find "$vm_dir" -maxdepth 2 -name "*.vdi" -print0)

    for vdi_file in "${VDI_FILES[@]}"; do
        VDI_NAME=$(basename "$vdi_file")
        VDI_DIR=$(dirname "$vdi_file")
        VDI_REL_DIR=$(realpath --relative-to="$SOURCE_BASE_DIR" "$VDI_DIR")
        VDI_RCLONE_DEST="$RCLONE_REMOTE_BASE/$VDI_REL_DIR"

        # Escape curly braces for rclone include filter pattern (e.g. VirtualBox Snapshot GUIDs)
        ESCAPED_VDI_NAME=$(echo "$VDI_NAME" | sed 's/{/\\{/g; s/}/\\}/g')

        echo "  [Pre-flight] Fetching remote MD5 checksums for $DIR_NAME / $VDI_NAME"

        max_retries=3
        attempt=1
        md5_output=""
        rclone_exit=0

        while [ $attempt -le $max_retries ]; do
            md5_output=$(rclone md5sum "$VDI_RCLONE_DEST" --include "${ESCAPED_VDI_NAME}.part.*" 2>&1)
            rclone_exit=$?

            if [ $rclone_exit -eq 0 ] || [ $rclone_exit -eq 3 ]; then
                break
            fi

            echo "    WARNING: 'rclone md5sum' failed for $VDI_NAME (Attempt $attempt/$max_retries, Exit Code: $rclone_exit)."
            [ $attempt -lt $max_retries ] && sleep 5
            ((attempt++))
        done

        if [ $rclone_exit -eq 3 ]; then
            echo "    Notice: Remote directory does not exist yet for $VDI_NAME (initial backup required)."
        elif [ $rclone_exit -ne 0 ]; then
            echo -e "\n======================================================================"
            echo " FATAL PRE-FLIGHT ERROR: Failed to retrieve MD5 sums for $VDI_NAME"
            echo " Command: rclone md5sum \"$VDI_RCLONE_DEST\" --include \"${ESCAPED_VDI_NAME}.part.*\""
            echo " Exit Code: $rclone_exit"
            echo " Output:"
            echo "$md5_output"
            echo "======================================================================\n"
            PREFLIGHT_FAILED=true
        else
            count=0
            while read -r md5 path; do
                [ -z "$md5" ] && continue
                part_name=$(basename "$path")
                ALL_REMOTE_MD5S["${vdi_file}:${part_name}"]="$md5"
                ((count++))
            done <<< "$md5_output"
            echo "    Success: Cached $count remote part hashes."
        fi
    done
done

if [ "$PREFLIGHT_FAILED" = true ]; then
    echo -e "\n======================================================================"
    echo " ABORTING: Pre-flight check failed for one or more VM directories."
    echo "======================================================================\n"
    exit 1
fi
echo -e "=== Pre-flight Check Passed Successfully ===\n"

POSTFLIGHT_FAILED=false
FAILED_VMS=()

for vm_dir in "${VM_DIRS[@]}"; do
    DIR_NAME=$(basename "$vm_dir")

    SKIP=false
    for skip_dir in "${SKIP_DIRS[@]}"; do
        [[ "$DIR_NAME" == "$skip_dir" ]] && SKIP=true && break
    done

   # If we haven't skipped yet, and the ONLY_DIRS whitelist exists, check it
    if ! $SKIP && [[ -n "${ONLY_DIRS+x}" ]] && (( ${#ONLY_DIRS[@]} > 0 )); then
        SKIP=true # Assume we skip unless it's in the whitelist
        for only_dir in "${ONLY_DIRS[@]}"; do
            if [[ "$DIR_NAME" == "$only_dir" ]]; then
                SKIP=false
                break
            fi
        done
    fi

    if [ "$SKIP" == true ]; then
        echo -e "\n--- SKIPPING Directory: $DIR_NAME ---"
        continue
    fi

    echo -e "\n--- Processing VM Directory: $vm_dir ---"
    RELATIVE_PATH=$(realpath --relative-to="$SOURCE_BASE_DIR" "$vm_dir")
    RCLONE_DESTINATION="$RCLONE_REMOTE_BASE/$RELATIVE_PATH"

    # Associative array to track expected remote files and their MD5 checksums for this VM
    declare -A EXPECTED_REMOTE_MD5S=()

    # Default rclone flags for this VM
    # Start with --delete-excluded and remove it to protect remote parts
    RCLONE_DELETE_FLAG="--delete-excluded"
    RCLONE_FILTER_ARGS=("--filter" "- *.vdi") # Don't send the *.vdi files

    # Capture the *.vdi files in the current VM directory.
    # Using "-maxdepth 2" allows going into the Snapshots/ folder.
    readarray -d '' VDI_FILES < <(find "$vm_dir" -maxdepth 2 -name "*.vdi" -print0)

    for vdi_file in "${VDI_FILES[@]}"; do
        VDI_NAME=$(basename "$vdi_file")
        ESCAPED_VDI_NAME=$(echo "$VDI_NAME" | sed 's/{/\\{/g; s/}/\\}/g')
        echo "  Comparing md5sums of remote parts to $VDI_NAME"

        declare -A REMOTE_MD5S=()
        for key in "${!ALL_REMOTE_MD5S[@]}"; do
            if [[ "$key" == "${vdi_file}:"* ]]; then
                part_name="${key#${vdi_file}:}"
                REMOTE_MD5S["$part_name"]="${ALL_REMOTE_MD5S[$key]}"
            fi
        done

        # Calculate required blocks
        FILE_SIZE=$(stat -c%s "$vdi_file")
        BYTES_PER_CHUNK=$((CHUNK_SIZE_MB * 1024 * 1024))
        TOTAL_BLOCKS=$(( (FILE_SIZE + BYTES_PER_CHUNK - 1) / BYTES_PER_CHUNK ))

        DIFFERS_CNT=0
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

                vdi_dir=$(dirname "$vdi_file")
                vdi_rel_dir=$(realpath --relative-to="$SOURCE_BASE_DIR" "$vdi_dir")
                part_rel_path="${vdi_rel_dir}/${PART_NAME}"
                EXPECTED_REMOTE_MD5S["$part_rel_path"]="$LOCAL_MD5"

                if [[ "$LOCAL_MD5" != "${REMOTE_MD5S[$PART_NAME]}" ]]; then
                    echo -e "    Block $PART_LABEL differs. Sync required."
                    #echo "LOCAL_MD5=$LOCAL_MD5 REMOTE_MD5S=${REMOTE_MD5S[$PART_NAME]}"
                    NEEDS_SYNC=true
                    (( DIFFERS_CNT += 1 )) # Increment the DIFFERS_CNT
                    [ "$COMPARE_ONLY" ] || break
                fi
                #echo -ne "    Verified md5sum for block $PART_LABEL/$((TOTAL_BLOCKS-1))\r"
            done
        fi

        if [ "$COMPARE_ONLY" ]; then
          echo "Skipping splitting of ${vdi_file} due to COMPARE_ONLY setting."
          echo "  ** $DIFFERS_CNT of $TOTAL_BLOCKS blocks differ"
          continue
        fi

        if [ "$NEEDS_SYNC" = true ]; then
            echo "    Remote and local mismatch. Generating new split parts..."
            output_prefix="${vdi_file}.part."
            split -b "$CHUNK_SIZE" -d --suffix-length="$CHUNKS_SUFFIX_LEN" --verbose "$vdi_file" "$output_prefix"
            find "$vm_dir" -name "$(basename "$vdi_file").part.*" -exec touch -r "$vdi_file" {} \;
        else
            echo "    Remote and local match. Disabling --delete-excluded to protect remote parts."
            # To protect remote parts that aren't local, we MUST exclude them and turn off --delete-excluded
            RCLONE_FILTER_ARGS+=("--filter" "- ${ESCAPED_VDI_NAME}.part.*")
            RCLONE_DELETE_FLAG=""
        fi
    done

    if [ "$COMPARE_ONLY" ]; then
      echo "Skipping rclone of ${vdi_file} due to COMPARE_ONLY setting."
      NEEDS_SYNC=false
      continue
    fi

    # Create README and Sync non-VDI files (or new parts)
    echo "$README_CONTENT" > "$vm_dir/$README_FILENAME"
    echo "  Rcloning $vm_dir to $RCLONE_DESTINATION"

    # The --checksum flag was missing from an earlier version of this
    # program and that mistake meant that every 500MB slice would sync.
    # Though likely not needed, the --ignore-size option was also added
    # for good measure. It should have zero impact in almost all cases,
    # but will protect against a cloud service that might report file
    # sizes of identical files slightly differently than the local system.
    /bin/time rclone $DRY_RUN sync "$vm_dir" "$RCLONE_DESTINATION" \
         $RCLONE_VERBOSITY $RCLONE_TRACK_RENAMES \
         "${RCLONE_FILTER_ARGS[@]}" $RCLONE_DELETE_FLAG \
         --checksum --ignore-size \
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
    SYNC_EXIT=$?
    if [ $SYNC_EXIT -ne 0 ]; then
        echo "  ERROR: 'rclone sync' failed for $DIR_NAME with exit code $SYNC_EXIT."
    fi

    # Record expected remote files & MD5s for non-VDI files and newly generated VDI parts
    readarray -d '' ALL_LOCAL_FILES < <(find "$vm_dir" -type f ! -name "*.vdi" -print0)
    for loc_file in "${ALL_LOCAL_FILES[@]}"; do
        rel_path=$(realpath --relative-to="$SOURCE_BASE_DIR" "$loc_file")
        # If NEEDS_SYNC was true for a VDI, update the expected MD5 with the newly split part hash
        if [[ -z "${EXPECTED_REMOTE_MD5S[$rel_path]}" ]] || [[ "$loc_file" == *.vdi.part.* ]]; then
            loc_md5=$(md5sum "$loc_file" | awk '{print $1}')
            EXPECTED_REMOTE_MD5S["$rel_path"]="$loc_md5"
        fi
    done

    # Run Post-flight Verification Check for this VM directory
    echo "  [Post-flight] Verifying remote MD5 checksums for $DIR_NAME..."
    max_retries=3
    attempt=1
    postflight_output=""
    rclone_exit=0

    while [ $attempt -le $max_retries ]; do
        postflight_output=$(rclone md5sum "$RCLONE_DESTINATION" 2>&1)
        rclone_exit=$?

        if [ $rclone_exit -eq 0 ] || [ $rclone_exit -eq 3 ]; then
            break
        fi

        echo "    WARNING: 'rclone md5sum' failed during post-flight for $DIR_NAME (Attempt $attempt/$max_retries, Exit Code: $rclone_exit)."
        [ $attempt -lt $max_retries ] && sleep 5
        ((attempt++))
    done

    declare -A ACTUAL_REMOTE_MD5S=()
    if [ $rclone_exit -eq 0 ]; then
        while read -r md5 path; do
            [ -z "$md5" ] && continue
            rel_file="${RELATIVE_PATH}/${path}"
            rel_file=$(echo "$rel_file" | sed 's|/\./|/|g; s|^\./||')
            ACTUAL_REMOTE_MD5S["$rel_file"]="$md5"
        done <<< "$postflight_output"
    fi

    VM_POSTFLIGHT_ERRORS=0

    if [ $rclone_exit -ne 0 ]; then
        echo "    ERROR [Post-flight]: Failed to retrieve remote MD5 checksums for $DIR_NAME (Exit Code: $rclone_exit)."
        ((VM_POSTFLIGHT_ERRORS++))
    else
        # Check expected files against actual remote files
        for expected_rel in "${!EXPECTED_REMOTE_MD5S[@]}"; do
            expected_md5="${EXPECTED_REMOTE_MD5S[$expected_rel]}"
            if [[ -z "${ACTUAL_REMOTE_MD5S[$expected_rel]+x}" ]]; then
                echo "    ERROR [Post-flight]: Missing expected remote file: $expected_rel"
                ((VM_POSTFLIGHT_ERRORS++))
            elif [[ "${ACTUAL_REMOTE_MD5S[$expected_rel]}" != "$expected_md5" ]]; then
                echo "    ERROR [Post-flight]: MD5 mismatch for $expected_rel (Expected: $expected_md5, Remote: ${ACTUAL_REMOTE_MD5S[$expected_rel]})"
                ((VM_POSTFLIGHT_ERRORS++))
            fi
        done

        # Check for unexpected files on remote
        for actual_rel in "${!ACTUAL_REMOTE_MD5S[@]}"; do
            if [[ -z "${EXPECTED_REMOTE_MD5S[$actual_rel]+x}" ]]; then
                echo "    ERROR [Post-flight]: Unexpected file found on remote: $actual_rel (MD5: ${ACTUAL_REMOTE_MD5S[$actual_rel]})"
                ((VM_POSTFLIGHT_ERRORS++))
            fi
        done
    fi

    if [ $VM_POSTFLIGHT_ERRORS -gt 0 ]; then
        echo "  [Post-flight] FAILED for $DIR_NAME ($VM_POSTFLIGHT_ERRORS error(s) detected)."
        POSTFLIGHT_FAILED=true
        FAILED_VMS+=("$DIR_NAME")
    else
        echo "  [Post-flight] Success: Verified remote MD5 checksums for $DIR_NAME."
    fi

    # Cleanup local temporary files
    echo "  Cleaning up local temporary files..."
    find "$vm_dir" -name "*.vdi.part.*" -delete
    rm -f "$vm_dir/$README_FILENAME"

    echo "Finished processing directory: $vm_dir"
    echo "--------------------------------------------------"
done

if [ "$POSTFLIGHT_FAILED" = true ]; then
    echo -e "\n======================================================================"
    echo " FATAL ERROR: Post-flight verification failed for the following VM(s):"
    for failed_vm in "${FAILED_VMS[@]}"; do
        echo "   - $failed_vm"
    done
    echo "======================================================================\n"
    exit 1
else
    echo -e "\n=== All Post-flight Verification Checks Passed Successfully ==="
fi

echo -e "\nBackup process finished."

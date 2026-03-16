#!/bin/bash

###########################################################
# A program to list all snapshots for each Virtual Box VM
###########################################################

VBoxManage list --sorted vms | while IFS= read -r line; do
  # Extract the VM name by removing the UUID and surrounding quotes
  vm_name=$(echo "$line" | sed -e 's/^"//' -e 's/" {.*}//')
  echo "--- Snapshots for VM: $vm_name ---"
  VBoxManage snapshot "$vm_name" list --details
  echo
done

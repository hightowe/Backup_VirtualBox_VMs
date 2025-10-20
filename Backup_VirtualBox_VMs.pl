#!/usr/bin/perl

#############################################################################
# A Perl program that automates crash-consistent backups of VirtualBox
# virtual machines using VBoxManage live snapshots and rsync.
#
# The backup strategy is adapted according to the state of each VM:
#  - For running VMs: It leverages VBoxManage to create a live snapshot,
#    allowing rsync to safely copy the VM's disk files without interruption,
#    and the snapshot is automatically deleted post-backup to merge changes.
#  - For powered-off VMs: It proceeds directly to rsync, as the files are
#    already in a consistent state.
#
# Backup operations are executed robustly, with error handling and silent
# command execution and with rsync configured to perform efficient
# incremental mirroring with the --delete and --inplace options, ensuring the
# backup destination remains an exact, space-efficient replica of the source.
#
# Written 10/14/2025 by Lester Hightower, in collaboration with a large
# language model trained by Google.
#############################################################################

use strict;                                   # core
use warnings;                                 # core
use Getopt::Long;                             # core
use File::Path qw(make_path);                 # core
use File::Basename qw(dirname basename);      # core
use Time::Piece;                              # core
use Term::ReadKey;                            # core
use English;                                  # core, for $REAL_USER_ID
use Data::Dumper;                             # core
Getopt::Long::Configure(qw(no_auto_abbrev));

our $opts = MyGetOpts(); # Will only return with options we think we can use

# Standard ISC (Vixie) cron on Linux does not set the USER environment
# variable and VBoxManage (dumbly) requires both USER and LOGNAME to be set
# and to match, else it reports a warning on STDOUT, which is even dumber.
# A workaround is to prepend 'env USER=$LOGNAME' to cron jobs that run this
# program, but I decided to add this code to eliminate that need.
my $uid = $REAL_USER_ID;         # Get the effective user ID
my ($username) = getpwuid($uid); # Lookup the username
if (! defined($username)) {
  die "Could not determine the username for UID $uid.\n";
}
# Set USER and LOGNAME if they are empty and bail is they mismatch
foreach my $var (qw(USER LOGNAME)) {
  $ENV{$var} = $username if (! (defined($ENV{$var}) && length($ENV{$var})));
  if ($username ne $ENV{$var}) {
    die "Env var $var=$ENV{$var} which does not match getpwuid()=$username\n";
  }
}

# Query the list of VMs and capture the output and exit status
my $vms_output = qx{VBoxManage list --sorted vms};
if ($? != 0) {
    # If the command failed, die and stop the script
    die "Error: 'VBoxManage list vms' failed with exit code " . ($? >> 8) . ". Please check your VirtualBox installation.\n";
}

# Show the full list of VMs
my @vms = split(/\n/, $vms_output);
print "All VMs:\n * ".join("\n * ", @vms) . "\n\n";
exit if ($opts->{listvms});

# Fill @vm_names with the names of the VMs to backup, respecting --skip and --only
my @vm_names = ();
VMname: foreach my $line (@vms) {
  # The output format is "VM_Name" {UUID}
  # This regex captures the VM name, handling spaces correctly
  next VMname unless $line =~ m/^"([^"]+)"/;
  my $vm_name = $1;
  if (defined($opts->{skip})) {
    push(@vm_names, $vm_name) if (!scalar(grep(/^$vm_name$/, @{$opts->{skip}})));
  } elsif (defined($opts->{only})) {
    push(@vm_names, $vm_name) if (scalar(grep(/^$vm_name$/, @{$opts->{only}})));
  } else {
    push(@vm_names, $vm_name);
  }
}

if (scalar(@vm_names) < 1) {
  die "No VMs to backup... (Nothing to do?)\n";
}

# Ensure that the --budir directory exists and is writable
my $BACKUP_DIR = $opts->{budir};  # A global convenience variable
unless (-d $BACKUP_DIR and -w $BACKUP_DIR) {
  die "Backup directory '$BACKUP_DIR' is missing or not writable. Aborting.\n";
}

# Show the list of VMs that we intend to backup
print "Backing up this list of VMs to $BACKUP_DIR.\n";
print " * ".join("\n * ", @vm_names) . "\n";

# If we were asked to --verify, do that if we can
if ($opts->{verify}) {
  die "Non-interactive STDIN!\n" if (! -t STDIN); # Need an interactive terminal
  print "Do you want to continue? [y/N] ";
  ReadMode 4;
  my $key = ReadKey 0; # Read a single character immediately
  ReadMode 0;
  print "\n";
  exit if (uc($key) ne 'Y');
} else {
  print "\n";
}

# Process the backup for each VM
VM: foreach my $vm_name (@vm_names) {
    print "Processing VM: '$vm_name'...\n";

    # Query VM info to determine its state
    my $vminfo = qx{VBoxManage showvminfo \"$vm_name\" --machinereadable};
    if ($? != 0) {
        warn "  Could not get VM info for '$vm_name' (exit code " . ($? >> 8) . "). Skipping.\n";
        next VM;
    }
    my ($vm_state) = $vminfo =~ /VMState="([^"]+)"/; # Determines if we snapshot
    my ($cfg_file) = $vminfo =~ /CfgFile="([^"]+)"/ or do {
        warn "  Could not find config file for '$vm_name' in output. Skipping.\n";
        next VM;
    };
    my $vm_dir = dirname($cfg_file);

    print "  '$vm_name' at '$vm_dir' is in state: $vm_state\n";

    # Conditional snapshot logic based on VM state
    my $snapshot_name = undef; # No snapshop will be taken unless the VM is running
    if ($vm_state eq 'running') {
        print "  VM is running. Taking a live snapshot...\n";
        my $now = localtime;
        $snapshot_name = "Backup_Snapshot_" . $now->strftime('%Y%m%d_%H%M%S');

        # Check if a snapshot with the same name already exists
        my $snapshot_exists = qx{VBoxManage snapshot \"$vm_name\" list --machinereadable | grep \"Name=\\\"$snapshot_name\\\"\"};
        if ($? == 0 && $snapshot_exists) {
            print "  Snapshot '$snapshot_name' already exists. Skipping snapshot creation.\n";
        } else {
            system("VBoxManage snapshot \"$vm_name\" take \"$snapshot_name\" --live");
            if ($? != 0) {
                warn "  Failed to take live snapshot for '$vm_name' (exit code " . ($? >> 8) . "). Skipping to next VM.\n";
                next VM;
            }
        }
    } else {
        # For non-running VMs (powered off, saved, etc.), no snapshot is needed
        print "  VM is in state '$vm_state'. No snapshot required.\n";
    }

    # rsync the VM directory to the $BACKUP_DIR/
    my $backup_location = "$BACKUP_DIR/$vm_name";
    make_path($backup_location) if (! -d $backup_location);
    die "Failed to make writable directory $backup_location\n" if (! (-w -d $backup_location));

    print "  Rsyncing '$vm_dir' to '$backup_location'...\n";
    # Capture output and print only a summary
    my $rsync_output = qx{rsync -a --delete --inplace --stats \"$vm_dir/\" \"$backup_location/\"};
    if ($? != 0) {
        warn "  Rsync failed for '$vm_name' (exit code " . ($? >> 8) . "). Backup may be incomplete.\n";
    } else {
        print "  Rsync summary:\n";
        my @summary_lines = grep { /^(Number|Total)/ } split /\n/, $rsync_output;
        print "  $_\n" for @summary_lines;
    }

    # Delete the snapshot if it exists (merges changes back into running VMs)
    if (defined $snapshot_name) {
        print "  Deleting snapshot '$snapshot_name'...\n";
        system("VBoxManage snapshot \"$vm_name\" delete \"$snapshot_name\"");
        if ($? != 0) {
            warn "  Failed to delete snapshot for '$vm_name' (exit code " . ($? >> 8) . "). Manual cleanup may be required.\n";
        }
    }

    print "Finished processing '$vm_name'.\n\n";
}

print "Backup process complete.\n";

exit;

###########################################################################
###########################################################################

sub MyGetOpts {
  my %opts=();
  my @params = (
	"help", "h",
	"verify", "listvms", 'budir=s', 'skip=s@', 'only=s@' );
  my $result = &GetOptions(\%opts, @params);

  my $use_help_msg = "Use --help to see information on command line options.";

  # Set any undefined booleans to 0
  foreach my $param (@params) {
    if ($param !~ m/=/ && (! defined($opts{$param}))) {
      $opts{$param} = 0; # Booleans
    }
  }

  # If the user asked for help give it and exit
  if ($opts{help} || $opts{h}) {
    print GetUsageMessage();
    exit;
  }

  # If GetOptions failed it told the user why, so let's exit.
  if (! int($result)) {
    print "\n" . $use_help_msg . "\n";
    exit;
  }

  my @errs=(); # Collects any errors that we find

  # Require --budir unless we're just doing a --listvms
  if (!($opts{listvms}) && ((!defined($opts{budir})) || !(length($opts{budir})))) {
    push @errs, "Missing required option: --budir=<target-dir>";
  }

  # --skip and --only are mutually exlusive
  if (defined($opts{skip}) && defined($opts{only})) {
    push @errs, "Options --skip and --only are mutually exlusive";
  }

  # If @errs, report them and bail out
  if (scalar(@errs)) {
    warn "There were errors:\n" .
        "  " . join("\n  ", @errs) . "\n\n";
    print $use_help_msg . "\n";
    exit;
  }

  return \%opts;
}

sub GetUsageMessage {
  my $parmlen = 14;
  my $col1len = $parmlen + 3;
  my $pwlen = our $DEFAULT_PASSWD_LEN;
  my @params = (
    [ 'listvms'    => 'List the VMs and exit..' ],
    [ 'budir=s'    => 'The backup directory (target directory).' ],
    [ 'skip=s@'    => 'VMs to skip (multiple allowed).' ],
    [ 'only=s@'    => 'Only backup these VMs (multiple allowed).' ],
    [ 'verify'     => 'Verify with the user before proceeding.' ],
    [ help         => 'This message.' ],
  );
  my $APP_NAME = basename($0);
  my $t="Usage examples:\n" .
	"  \$ $APP_NAME --listvms\n" .
        "  \$ $APP_NAME --verify --budir /vol/backups/VirtualBoxVMs\n" .
	"  \$ $APP_NAME --budir=<target-dir> --only WinXP --only Win7\n" .
	"  \$ $APP_NAME --verify --budir=<target-dir> --skip=WinXP\n" .
  "\n";
  foreach my $param (@params) {
    my $fmt = '  %-'.$parmlen.'s %s';
    $t .= sprintf("$fmt\n", '--'.$param->[0], $param->[1]);
  }
  return $t;
}

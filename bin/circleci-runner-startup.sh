#!/usr/bin/env sh

# Pass env vars to this script:
#   CIRCLECI_TOKEN
#   CIRCLECI_RESOURCE_CLASS


if ! command -v docker ; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker.io
  systemctl enable --now docker
fi
chmod 666 /var/run/docker.sock # so container can write to file

DEVICE="/dev/disk/by-id/circleci-cache-1"
MOUNTDIR="/var/cache/circleci"

if lsblk $DEVICE ; then
  if ! mount "$MOUNTDIR" ; then
    mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard "$DEVICE"
    mkdir -p "$MOUNTDIR"
    mount -o discard,defaults "$DEVICE" "$MOUNTDIR"
    echo "UUID=$(sudo blkid -s UUID -o value $DEVICE)  $MOUNTDIR  ext4  discard,defaults,nofail  0  2" | tee -a /etc/fstab
  fi
fi

# allow anyone to create a file/dir that only they can write to
chmod 1777 "$MOUNTDIR"

# Create circleci user and working directory
id -u circleci >/dev/null 2>&1 || adduser --disabled-password --gecos GECOS circleci

# Set up the runner directories
echo "Setting up CircleCI Runner directories"
mkdir -p /var/cache/circleci/workdirs
chmod 0750 /var/cache/circleci/workdirs
chown -R circleci /var/cache/circleci/workdirs

# This enables code to execute root commands on the instance and changes to the system may persist after the job is run
echo "circleci ALL=(ALL) NOPASSWD:ALL" | tee -a /etc/sudoers

working_directory='/var/cache/circleci/workdirs/%s'

# install CircleCI machine runner per https://circleci.com/docs/install-machine-runner-3-on-linux/
curl -s https://packagecloud.io/install/repositories/circleci/runner/script.deb.sh?any=true | bash
apt-get install -y circleci-runner
sed -i "s/<< AUTH_TOKEN >>/$CIRCLECI_TOKEN/g" /etc/circleci-runner/circleci-runner-config.yaml

# Update the working directory in the file since that takes precedence
sed -i "s|/var/lib/circleci-runner/workdir|$working_directory|g" /etc/circleci-runner/circleci-runner-config.yaml

chown -R circleci: /etc/circleci-runner
chmod 644 /etc/circleci-runner/circleci-runner-config.yaml

# export env vars instead of updating the config file
# shellcheck disable=SC2155
export LAUNCH_AGENT_RUNNER_NAME="$(hostname)"
export LAUNCH_AGENT_RUNNER_CLEANUP_WORK_DIR="true"

# start circleci runner
systemctl enable circleci-runner && systemctl start circleci-runner

# Check status
systemctl status circleci-runner

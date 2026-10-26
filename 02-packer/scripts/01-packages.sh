#!/bin/bash
set -euo pipefail

# ================================================================================
# Base packages: SSSD/realmd (the join happens at boot), tools
# ================================================================================
#
# No Azure CLI: the boot script reads Key Vault with curl and the VM's managed
# identity (an IMDS token), which keeps the image small.
#
# ================================================================================

export DEBIAN_FRONTEND=noninteractive

# The build VM is fresh: let cloud-init and the boot-time apt timers finish so
# they don't hold the dpkg lock while this script installs.
cloud-init status --wait >/dev/null 2>&1 || true
systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service \
  2>/dev/null || true

# apt mirrors can be briefly out of step (a package index newer than the files
# behind it, answering 404). Retry with a fresh index instead of failing the
# whole image build.
cat > /usr/local/bin/apt-install-retry <<'SCRIPT'
#!/bin/bash
for attempt in 1 2 3 4 5; do
  if apt-get install "$@"; then exit 0; fi
  echo "WARN: apt-get install failed (attempt ${attempt}); refreshing and retrying"
  sleep $((attempt * 10))
  apt-get update -y || true
done
exit 1
SCRIPT
chmod 755 /usr/local/bin/apt-install-retry

echo "NOTE: [packages] updating and upgrading"
apt-get update -y
apt-get -y -o Dpkg::Options::=--force-confold upgrade

echo "NOTE: [packages] SSSD / realmd for the AD join at boot"
apt-install-retry -y \
  realmd sssd sssd-tools sssd-ad adcli krb5-user samba-common-bin \
  oddjob oddjob-mkhomedir packagekit jq curl unzip less nano vim

echo "NOTE: [packages] done"

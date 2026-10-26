#!/bin/bash
# ==============================================================================
# custom_data_lubuntu.sh  —  join the Lubuntu desktop host to the mini-AD (SSSD)
#
# The image (02-packer) already has LXQt, XRDP and the SSSD/realmd packages;
# this script does only the per-machine part. realmd joins the domain
# (computer object + keytab), and SSSD becomes the identity/auth provider over
# Kerberos. POSIX UIDs come from AD (ldap_id_mapping = False). The VM is
# private: users reach it through Guacamole over RDP (XRDP, an LXQt desktop)
# or SSH, signed in with their AD password either way.
# ==============================================================================
set -euo pipefail
exec > >(tee -a /root/userdata.log | logger -t user-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR
echo "lubuntu custom-data start ($(date -Is))"

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# Domain admin credential (used only to perform the join), read from Key Vault
# with the VM's managed identity. The identity's role assignment is created
# after the VM, so the first reads can return 403 until it propagates: retry.
# ------------------------------------------------------------------------------
IMDS="http://169.254.169.254/metadata/identity/oauth2/token"
secret=""
for i in $(seq 1 60); do
  token=$(curl -fsS -H Metadata:true \
    "$IMDS?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
    | jq -r '.access_token // empty' || true)
  if [ -n "$token" ]; then
    secret=$(curl -fsS -H "Authorization: Bearer $token" \
      "https://${vault_name}.vault.azure.net/secrets/admin-credentials?api-version=7.4" \
      | jq -r '.value // empty' || true)
  fi
  [ -n "$secret" ] && break
  echo "waiting for Key Vault access ($i/60)"
  sleep 10
done
[ -n "$secret" ]
admin_password=$(echo "$secret" | jq -r .password)
# The secret holds Admin@<domain>; realm wants the bare account name.
admin_user=$(echo "$secret" | jq -r .username | sed 's/@.*//')

# ------------------------------------------------------------------------------
# Join with SSSD (realmd's default client software). The DC can still be
# settling when this VM boots, so retry the join a few times.
# ------------------------------------------------------------------------------
for i in $(seq 1 10); do
  if echo "$admin_password" | realm join -U "$admin_user" ${domain_fqdn} --verbose; then
    break
  fi
  [ "$i" -eq 10 ] && exit 1
  echo "realm join failed ($i/10); retrying"
  sleep 30
done

# ------------------------------------------------------------------------------
# SSSD tweaks:
#   - short login names (jsmith, not jsmith@domain)
#   - POSIX mapping: read uidNumber/gidNumber from AD
#   - home under /home/%u
# ------------------------------------------------------------------------------
sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
sed -i 's/ldap_id_mapping = True/ldap_id_mapping = False/'                     /etc/sssd/sssd.conf
sed -i 's|fallback_homedir = /home/%u@%d|fallback_homedir = /home/%u|'         /etc/sssd/sssd.conf

# SSSD's AD provider enforces AD logon rights (GPO access control), choosing
# the right by PAM service name, and denies services it has no mapping for.
# sshd is mapped to "remote interactive" out of the box; XRDP's service is
# not, so desktop logins failed the account check ("User is not authorized")
# after a correct password. Map it like sshd.
sed -i '/^access_provider = ad/a ad_gpo_map_remote_interactive = +xrdp-sesman' /etc/sssd/sssd.conf

pam-auth-update --enable mkhomedir
systemctl restart sssd

# ------------------------------------------------------------------------------
# Passwordless sudo for the linux-admins domain group
# ------------------------------------------------------------------------------
echo "%linux-admins ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/10-linux-admins
chmod 440 /etc/sudoers.d/10-linux-admins

# ------------------------------------------------------------------------------
# SSH password logins — Guacamole's SSH connection passes the user's AD
# password through. Ubuntu's cloud image turns password auth off in
# 60-cloudimg-settings.conf; sshd takes the first value it reads, so a file
# that sorts earlier wins. Port 22 is open only to the Guacamole server.
# ------------------------------------------------------------------------------
cat > /etc/ssh/sshd_config.d/10-guacamole-password-auth.conf <<'SSHD'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
SSHD
systemctl restart ssh

# ------------------------------------------------------------------------------
# Sanity: resolve the demo users. Non-fatal.
# ------------------------------------------------------------------------------
for u in jsmith rpatel akumar edavis; do
  if id "$u" >/dev/null 2>&1; then echo "OK resolve: $u ($(id -u "$u"))"; else echo "WARN unresolved: $u"; fi
done
echo "lubuntu custom-data done ($(date -Is))"

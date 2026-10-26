#!/bin/bash
set -euo pipefail

# ================================================================================
# XRDP: RDP logins start an LXQt session
# ================================================================================
#
# Guacamole connects with RDP security "tls": XRDP does not do NLA. The login
# is checked by PAM, so once the VM has joined the domain (SSSD), AD users sign
# in with their AD password and get a home directory on first use.
#
# ================================================================================

export DEBIAN_FRONTEND=noninteractive

echo "NOTE: [xrdp] installing xrdp"
apt-get update -y
apt-install-retry -y xrdp xorgxrdp

# XRDP reads the private key of its TLS certificate (the snakeoil pair).
adduser xrdp ssl-cert

echo "NOTE: [xrdp] LXQt session for every login"
tee /etc/xrdp/startwm.sh >/dev/null <<'WM'
#!/bin/sh
if test -r /etc/profile; then
    . /etc/profile
fi

if test -r ~/.profile; then
    . ~/.profile
fi

# XRDP starts Xorg with "-auth .Xauthority" but does not export XAUTHORITY.
# Ordinary apps find ~/.Xauthority by default; snaps (Firefox) run with a
# redirected $HOME and do not, so X refuses them ("Authorization required").
# An absolute XAUTHORITY lets snapd hand the cookie to the snap.
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

export DESKTOP_SESSION=lxqt
export XDG_SESSION_DESKTOP=lxqt
export XDG_CURRENT_DESKTOP=LXQt

exec startlxqt
WM
chmod 755 /etc/xrdp/startwm.sh

# 16-bit colour keeps LXQt responsive over the Guacamole hop.
sed -i 's/^max_bpp=32/max_bpp=16/' /etc/xrdp/xrdp.ini

echo "NOTE: [xrdp] PAM: environment, then the system stack (SSSD + mkhomedir)"
tee /etc/pam.d/xrdp-sesman >/dev/null <<'PAM'
#%PAM-1.0
auth required pam_env.so readenv=1
auth required pam_env.so readenv=1 envfile=/etc/default/locale
@include common-auth
@include common-account
@include common-session
@include common-password
PAM

# Remote sessions otherwise get polkit prompts for colour management and
# package refreshes ("Authentication is required to create a color profile").
echo "NOTE: [xrdp] polkit: no prompts for colord / packagekit refresh"
mkdir -p /etc/polkit-1/rules.d
tee /etc/polkit-1/rules.d/45-xrdp-quiet.rules >/dev/null <<'RULES'
polkit.addRule(function(action, subject) {
  if (action.id.indexOf("org.freedesktop.color-manager.") === 0 ||
      action.id === "org.freedesktop.packagekit.system-sources-refresh") {
    return polkit.Result.YES;
  }
});
RULES

# systemd 258+ prints "OSC 3008" context escapes at every bash prompt
# (/etc/profile.d/80-systemd-osc-context.sh). Guacamole's terminal does not
# understand them and shows the raw text ("start=...;type=shell;cwd=...").
# The symlink is re-created at EVERY BOOT by a tmpfiles.d rule
# (/usr/lib/tmpfiles.d/20-systemd-osc-context.conf), so deleting or diverting
# it does not last. Mask the rule with a same-named /etc entry pointing at
# /dev/null, then remove the symlink once.
echo "NOTE: [xrdp] disabling systemd's OSC 3008 prompt escapes"
ln -sf /dev/null /etc/tmpfiles.d/20-systemd-osc-context.conf
rm -f /etc/profile.d/80-systemd-osc-context.sh

systemctl enable xrdp

echo "NOTE: [xrdp] done"

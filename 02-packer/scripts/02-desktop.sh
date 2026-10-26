#!/bin/bash
set -euo pipefail

# ================================================================================
# Lubuntu core: a minimal LXQt desktop, Firefox (snap), cloud clean-up
# ================================================================================
#
# The LXQt components without Lubuntu's full application set (no office suite,
# mail or media apps), sized for XRDP sessions reached through Guacamole.
#
# ================================================================================

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------------
# LXQt desktop, window manager, terminal, file manager
# --------------------------------------------------------------------------------
echo "NOTE: [desktop] installing LXQt"
apt-get update -y
apt-install-retry -y \
  lxqt-core lxqt-config lxqt-panel lxqt-session lxqt-policykit lxqt-sudo \
  lxqt-runner lxqt-notificationd lxqt-menu-data \
  openbox obconf-qt pcmanfm-qt qterminal featherpad \
  xsel xclip

# xdg-open / xdg-mime: how apps hand a link or file to "the default app".
# Neither package comes with lxqt-core, and without both, opening any link
# fails. Under XDG_CURRENT_DESKTOP=LXQt, xdg-utils delegates to qtxdg-mat
# (qtxdg-tools), so xdg-utils alone is not enough.
apt-install-retry -y xdg-utils qtxdg-tools

update-alternatives --install /usr/bin/x-terminal-emulator \
  x-terminal-emulator /usr/bin/qterminal 50

# --------------------------------------------------------------------------------
# Firefox from the Snap Store, Ubuntu's default packaging. Snaps need the
# XAUTHORITY export in /etc/xrdp/startwm.sh (03-xrdp.sh) to open windows in an
# XRDP session. Wait for snapd's first-boot seeding before installing.
# --------------------------------------------------------------------------------
echo "NOTE: [desktop] installing firefox (snap)"
snap wait system seed.loaded
snap install firefox

# A snap registers no Debian alternatives, so anything that calls
# x-www-browser / www-browser finds nothing. Register Firefox for both names.
#
# Through a wrapper, not a symlink: /snap/bin/firefox is itself a symlink to
# /usr/bin/snap, which picks the app from the name it is invoked by -- run as
# "www-browser" it does not know it means Firefox.
cat > /usr/local/bin/firefox-snap <<'WRAPPER'
#!/bin/sh
exec /snap/bin/firefox "$@"
WRAPPER
chmod 755 /usr/local/bin/firefox-snap
for name in x-www-browser www-browser; do
  update-alternatives --install "/usr/bin/$name" "$name" \
    /usr/local/bin/firefox-snap 200
done

# LXQt has no equivalent of Xfce's helpers.rc: it (and xdg-open) resolve the
# browser from the XDG MIME defaults. System-wide defaults live in
# /etc/xdg/mimeapps.list; the .desktop file is the one snapd generates.
FIREFOX_DESKTOP=/var/lib/snapd/desktop/applications/firefox_firefox.desktop
test -f "$FIREFOX_DESKTOP"
tee /etc/xdg/mimeapps.list >/dev/null <<'MIME'
[Default Applications]
x-scheme-handler/http=firefox_firefox.desktop
x-scheme-handler/https=firefox_firefox.desktop
text/html=firefox_firefox.desktop
application/xhtml+xml=firefox_firefox.desktop
MIME

# Fail the build here, not in a user's session, if LXQt doesn't resolve it.
default_browser=$(cd /tmp && env HOME=/root XDG_CURRENT_DESKTOP=LXQt \
  XDG_DATA_DIRS=/usr/local/share:/usr/share:/var/lib/snapd/desktop \
  xdg-mime query default x-scheme-handler/https)
echo "NOTE: [desktop] LXQt default browser: ${default_browser}"
test "$default_browser" = "firefox_firefox.desktop"

# --------------------------------------------------------------------------------
# LXQt defaults for every new user: openbox, Firefox as BROWSER, a panel with
# an application menu and quick launchers (file manager, terminal, editor,
# Firefox), Desktop icons
#
# On 26.04 (LXQt 2.3):
#   - lxqt-core no longer pulls in lxqt-menu-data (installed above), without
#     which the panel has no application menu at all.
#   - The panel's menu is "fancymenu"; the classic "mainmenu" plugin does not
#     load.
#   - The Debian branding theme ("debian") styles only the old menu button,
#     so fancymenu's button is drawn blank. Any upstream theme draws it.
# --------------------------------------------------------------------------------
echo "NOTE: [desktop] LXQt session and panel defaults"
mkdir -p /etc/xdg/lxqt /etc/xdg/pcmanfm-qt/lxqt /etc/skel/Desktop

tee /etc/xdg/lxqt/session.conf >/dev/null <<'EOF'
[Environment]
BROWSER=firefox-snap
TERM=qterminal

[General]
window_manager=openbox
EOF

# Plugins that misbehave without local hardware (volume, battery,
# power management) are left out of the panel.
tee /etc/xdg/lxqt/panel.conf >/dev/null <<EOF
[General]
iconTheme=Papirus-Dark

[kbindicator]
alignment=Right
type=kbindicator

[quicklaunch]
alignment=Left
apps\\1\\desktop=/usr/share/applications/pcmanfm-qt.desktop
apps\\2\\desktop=/usr/share/applications/qterminal.desktop
apps\\3\\desktop=/usr/share/applications/featherpad.desktop
apps\\4\\desktop=${FIREFOX_DESKTOP}
apps\\size=4
type=quicklaunch

[quicklaunch2]
alignment=left
apps\\1\\desktop=/usr/share/applications/lxqt-leave.desktop
apps\\size=1
type=quicklaunch

[fancymenu]
type=fancymenu
alignment=Left

[panel1]
plugins=fancymenu, showdesktop, desktopswitch, quicklaunch, taskbar, tray, statusnotifier, worldclock, quicklaunch2

[taskbar]
buttonWidth=200
raiseOnCurrentDesktop=true
EOF

tee /etc/xdg/pcmanfm-qt/lxqt/settings.conf >/dev/null <<'EOF'
[Desktop]
DesktopShortcuts=Home
WallpaperMode=zoom
WallpaperRandomize=false

[System]
FallbackIconThemeName=oxygen
Terminal=qterminal

[Window]
AlwaysShowTabs=true

[Behavior]
QuickExec=true
EOF

sed -i 's/^theme=debian$/theme=dark/' /etc/xdg/lxqt/lxqt.conf
grep -q '^theme=dark$' /etc/xdg/lxqt/lxqt.conf

# A symlink (not a copy) keeps the launcher trusted, so LXQt doesn't ask
# before running it.
ln -sf "$FIREFOX_DESKTOP" /etc/skel/Desktop/firefox_firefox.desktop
ln -sf /usr/share/applications/qterminal.desktop /etc/skel/Desktop/qterminal.desktop

# --------------------------------------------------------------------------------
# Things a headless cloud desktop never uses, several of which pop up
# authentication prompts or errors inside an XRDP session. gvfs's mount
# daemons hang LXQt's file manager in remote sessions.
# --------------------------------------------------------------------------------
echo "NOTE: [desktop] removing cloud-irrelevant packages"
apt-get purge -y \
  bluez blueman cups cups-browsed cups-daemon system-config-printer \
  modemmanager speech-dispatcher orca \
  lxqt-powermanagement xscreensaver update-notifier \
  gvfs gvfs-backends gvfs-fuse \
  2>/dev/null || true
apt-get autoremove -y

# --------------------------------------------------------------------------------
# NetworkManager: LXQt can pull it in, and on Azure it fights cloud-init and
# systemd-networkd for the NIC, so the VM loses its network after a reboot.
# Remove it, pin it out, and mask its units.
# --------------------------------------------------------------------------------
echo "NOTE: [desktop] removing NetworkManager"
apt-get purge -y network-manager 2>/dev/null || true
tee /etc/apt/preferences.d/disable-network-manager >/dev/null <<'EOF'
Package: network-manager
Pin: release *
Pin-Priority: -1

Package: network-manager-*
Pin: release *
Pin-Priority: -1
EOF
systemctl mask NetworkManager.service NetworkManager-wait-online.service \
  2>/dev/null || true

# A display manager on the console is pointless here (XRDP starts its own X
# sessions) and only competes for resources.
for dm in lightdm sddm; do
  systemctl disable "$dm" 2>/dev/null || true
done
systemctl set-default multi-user.target

echo "NOTE: [desktop] done"

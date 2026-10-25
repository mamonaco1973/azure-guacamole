# HANDOFF: port aws-guacamole to Azure (azure-guacamole)

Written 2026-10-25 for the agent picking this up on the lab server. Read this
whole file before changing anything. Mike (the owner) commits and pushes; do
not run git commit/push unless he asks.

## Goal

An Azure version of [aws-guacamole](https://github.com/mamonaco1973/aws-guacamole):
a browser-only gateway into a **private** Windows + Linux environment.
Apache Guacamole sits behind an HTTPS load balancer; users sign in with their
Active Directory account and open RDP to Windows, and RDP (XRDP) + SSH to a
Linux desktop host, all as themselves. No server has a public IP; no VPN,
no bastion, no SSH keys to hand out.

**Deliberate difference from AWS: the Linux desktop is Lubuntu (LXQt), not
Xubuntu (Xfce).** Mike wants the Azure version to look different. Name things
`lubuntu`, and label the Guacamole connections `Lubuntu (RDP)` /
`Lubuntu (SSH)`.

## What this repo is right now

A straight copy of [azure-lubuntu-xrdp](https://github.com/mamonaco1973/azure-lubuntu-xrdp)
at `d309005` (no history), plus this file. Nothing has been ported yet. It
already has the right shape:

| aws-guacamole | this seed (azure-lubuntu-xrdp) |
|---|---|
| `01-directory`: VPC, NAT, `module-aws-mini-ad`, users | `01-directory`: VNet, NAT gateway, `module-azure-mini-ad`, users, Key Vault (`vault.tf`), **bastion (remove)** |
| `02-packer`: Xubuntu core + XRDP + SSSD | `02-packer`: full Lubuntu workstation (Chrome, VS Code, OnlyOffice, ...) + XRDP; **slim it** |
| `03-servers`: ALB, Guacamole, Windows, Xubuntu | `03-servers`: Windows + Lubuntu VMs **with public IPs**, NFS; **no Guacamole, no load balancer** |

Read both source repos side by side. The AWS repo is the behavioural spec
(its README is the best description of the intended result); the Azure seed
is the idiom to write it in.

## Target architecture

```
internet ─443/80─▶ App Gateway ─8080─▶ Guacamole ─3389──────▶ Windows
   (public IP)     (own subnet)       (private)  └─22, 3389─▶ Lubuntu
                                          │
                                          └─LDAPS 636─▶ mini-AD DC (ad1.<dns_zone>)
```

| Piece | Azure | Notes |
|---|---|---|
| Front door | Application Gateway Standard_v2 | HTTPS with self-signed cert; HTTP→HTTPS redirect. The only public piece. |
| Guacamole | Ubuntu VM, private, managed identity | guacd + Guacamole web app + PostgreSQL in Docker (port of `userdata_guacamole.sh`) |
| Windows Server 2022 | existing `windows.tf`, minus public IP | domain-joined; RDP from Guacamole only |
| Lubuntu | existing Packer image + `lubuntu_vm.tf`, minus public IP | SSSD domain join at boot; RDP + SSH from Guacamole only |
| mini-AD | `module-azure-mini-ad` (needs a change, below) | users/groups/DNS/Kerberos/LDAPS |
| Secrets | Key Vault (`vault.tf`, RBAC mode) | replaces Secrets Manager; VMs read via managed identity + `az keyvault secret show` |
| Egress | existing NAT gateway | outbound for private VMs |

## Step 0 (blocking): change module-azure-mini-ad to publish its CA

Guacamole signs users in over **LDAPS** (`LDAP_ENCRYPTION_METHOD: ssl`, port
636). Samba generates a **self-signed** CA and server certificate at
provision time (`/var/lib/samba/private/tls/ca.pem`), and Guacamole's JVM
rejects that certificate unless the CA is in its trust store. Guacamole has
no "ignore LDAP certificate" option, so the client must get the CA.

The AWS module solves this by serving the CA over HTTP from the DC's
existing Flask service (`maxids`, port 80). The Azure module does not have
that route. Port it:

- Repo: [module-azure-mini-ad](https://github.com/mamonaco1973/module-azure-mini-ad),
  file `scripts/maxUidNumber.py`.
- Copy the `/ca.pem` route and `CA_PEM_PATH` from
  [module-aws-mini-ad/scripts/maxUidNumber.py](https://github.com/mamonaco1973/module-aws-mini-ad/blob/main/scripts/maxUidNumber.py)
  (also add `Response` to the `flask` import). Returns the PEM, or 503 if
  Samba has not written it yet; clients retry.
- The CA is public (it only lets clients verify the DC), so serving it
  unauthenticated is fine. Keep the comment explaining that.
- Nothing else needed in the module: both modules already rely on Samba's
  auto-generated TLS for 636; the Azure NSG already allows 80 and 636; the
  DC hostname is already `ad1` (`HOSTNAME_DC` in `dc.tf`), so the URL is
  `http://ad1.<dns_zone>/ca.pem`, matching AWS.
- **Other Azure projects use this module** (xubuntu/mate/lubuntu-xrdp,
  rstudio-cluster, ...). The change is additive (a new route), so it is safe,
  but tell Mike before pushing the module, since he owns that commit.
- The DC only picks up the new script on a **fresh** DC (it is installed by
  the DC's boot script), so test with a full `01-directory` rebuild.

Then on the Guacamole VM, exactly as AWS does: poll
`http://ad1.<dns_zone>/ca.pem` until it is a certificate, import it with the
Guacamole image's own `keytool` into `/opt/guacamole/tls/truststore.jks`,
and pass it to the web app with `JAVA_OPTS -Djavax.net.ssl.trustStore=...`.
The LDAPS hostname must be `ad1.<dns_zone>` (the name in the cert), not an IP.

## Port tasks by phase

### 01-directory

- Delete `bastion.tf` (Guacamole replaces it) and anything referencing it.
- Add a **dedicated subnet for the App Gateway** (v2 requires its own
  subnet, nothing else in it). The VNet is `10.0.0.0/23` and the two
  existing /25s use only `10.0.0.0/24`, so e.g. `10.0.1.0/24` is free.
- Tighten the VM-subnet NSG. Today it allows 22, 3389 and 445 from `*`
  (the old design had public IPs). Target, mirroring AWS security groups:
  App Gateway subnet → Guacamole 8080; Guacamole → Windows 3389, Lubuntu 22 +
  3389; plus whatever the App Gateway v2 subnet itself needs (its NSG must
  allow `GatewayManager` 65200-65535 and the `AzureLoadBalancer` probe; put
  that NSG on the gateway subnet, not the VM subnet). Separate NSGs or ASGs
  for Guacamole vs targets are fine; keep it readable.
- Users/groups: already fine. `scripts/users.json.template` has the groups
  the Guacamole config depends on: **`mcloud-users`** (gate: only members may
  sign in) and **`linux-admins`** (Guacamole ADMINISTER + passwordless sudo).
- VNet DNS already points at the DC (the module's
  `azurerm_virtual_network_dns_servers`), so `ad1.<dns_zone>` resolves from
  the Guacamole VM.

### 02-packer (Lubuntu image)

Slim it to what AWS ships, and switch to the AWS snap approach:

- Drop the workstation extras: `chrome.sh`, `firefox.sh`, `vscode.sh`,
  `hashicorp.sh`, `awscli.sh`, `gcloudcli.sh`, `docker.sh`, `postman.sh`,
  `krdc.sh`, `onlyoffice.sh` (and their provisioners). Keep `azcli.sh` only
  if the boot script still needs `az` for Key Vault (it does today).
- **Snap: keep it.** `packages.sh` currently purges snapd and pins it out
  (`nosnap.pref`) because "XRDP has issues with snap". That was the old
  workaround; the AWS port abandoned it. The real fix is one line in
  `/etc/xrdp/startwm.sh`: `export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"`
  (XRDP starts Xorg with `-auth .Xauthority` but does not export it; snaps
  run with a redirected `$HOME` and get "Authorization required"). So:
  remove the snap purge/pin, install Firefox as a snap after
  `snap wait system seed.loaded`, and add the XAUTHORITY export. See
  aws-guacamole `02-packer/scripts/02-desktop.sh` and `03-xrdp.sh`.
- Default browser: AWS registers a `/usr/local/bin/firefox-snap` wrapper as
  `x-www-browser`/`www-browser` (a symlink does not work: `/snap/bin/firefox`
  dispatches on argv[0]). Keep that. The Xfce-only
  `sed ... /etc/xdg/xfce4/helpers.rc` has **no LXQt equivalent**; set the
  default under LXQt via `xdg-mime`/`/etc/xdg/mimeapps.list`
  (`x-scheme-handler/http`, `https`, `text/html` → `firefox_firefox.desktop`)
  and verify in a session that the panel's browser launcher and links open it.
- Port from AWS `03-xrdp.sh`, adapted to LXQt (`exec startlxqt`, the
  `DESKTOP_SESSION=lxqt` exports already in the Azure `xrdp.sh`):
  - `adduser xrdp ssl-cert` (XRDP needs the snakeoil key for TLS security)
  - `xorgxrdp` package
  - PAM `xrdp-sesman` using the system stack (SSSD + mkhomedir). The Azure
    version uses a `pam_exec` mkhomedir hack; prefer the AWS stack +
    `pam-auth-update --enable mkhomedir` already done at boot
  - polkit rule silencing colord / packagekit prompts
  - **systemd OSC 3008 mask** (`ln -sf /dev/null
    /etc/tmpfiles.d/20-systemd-osc-context.conf` + remove
    `/etc/profile.d/80-systemd-osc-context.sh`). Without it Guacamole's SSH
    terminal shows `start=...;type=shell;cwd=...` garbage on systemd 258+.
  - purge of cloud-irrelevant packages (bluez, cups, modemmanager, ...),
    `systemctl disable lightdm`, `set-default multi-user.target`
  - AWS's `apt-install-retry` helper (mirrors briefly 404)
- Ubuntu version: AWS uses **26.04**; the seed uses 24.04
  (`image_offer = "ubuntu-24_04-lts"`). Try 26.04 to match: find the real
  offer/SKU with `az vm image list --publisher Canonical --all -o table |
  grep 26_04`. Risk: LXQt package names in `lubuntu.sh` may have changed in
  26.04. If the build fights you, stay on 24.04 and tell Mike; but note
  the OSC 3008 mask only matters on systemd 258+ (26.04).

### 03-servers

- **Remove public IPs** from `windows.tf` and `lubuntu_vm.tf`.
- Delete `nfs.tf` and the NFS bits of `scripts/custom_data.sh` (the
  `/nfs` mount, the `/home` → `/nfs/home` move, `force group` in smb.conf
  if it only served NFS). Homes are local, created by mkhomedir, as on AWS.
  **Keep `storage.tf`**: it hosts the Windows AD-join script for the
  extension, not NFS. Verify before deleting anything there.
- **Guacamole VM** (`guacamole.tf`, new): Ubuntu (Canonical marketplace
  image, not the Packer image), ~`Standard_B2ms`/D2s (AWS uses t3.medium),
  ~30 GB disk, private NIC only, system-assigned identity with
  `Key Vault Secrets User` on the vault (same pattern as `lubuntu_vm.tf`).
  `custom_data` = port of aws-guacamole `03-servers/scripts/userdata_guacamole.sh`:
  - replace the AWS CLI install + `aws secretsmanager get-secret-value` with
    `az login --identity` + `az keyvault secret show --name admin-credentials`
    (the Azure seed's secret name; check `01-directory/accounts.tf`)
  - template vars: `dc_fqdn = "ad1.${var.dns_zone}"`, `base_dn`, `netbios`,
    `windows_ip`, `lubuntu_ip`, `guac_version = "1.6.0"`
  - rename the Xubuntu connections to `Lubuntu (RDP)` / `Lubuntu (SSH)`
  - keep everything else: LDAPS + trust store, `mcloud-users` filter, DB
    groups named like the AD groups, `${GUAC_USERNAME}`/`${GUAC_PASSWORD}`
    pass-through, NLA + `MCLOUD` domain for Windows, `security=tls` and no
    domain for XRDP, disabling `guacadmin`
  - templatefile escaping: AWS uses `$${...}` for literal `${...}`; keep it
  - Azure has no `user_data_replace_on_change`; `custom_data` changes
    already force replacement on azurerm Linux VMs, check that's the case
- **App Gateway** (`appgateway.tf`, new): start from
  [azure-rstudio-cluster/04-cluster/appgateway.tf](https://github.com/mamonaco1973/azure-rstudio-cluster/blob/main/04-cluster/appgateway.tf),
  which is HTTP-only. Changes:
  - backend = Guacamole VM private IP, port 8080, HTTP; probe path `/`
    (Guacamole's ROOT context; `WEBAPP_CONTEXT: ROOT` in the compose file)
  - **cookie-based affinity** is harmless with one backend; WebSocket works
    on v2 without extra config
  - HTTPS listener on 443 with a **self-signed certificate**, plus an HTTP
    80 listener that redirects to HTTPS (AWS does the same on the ALB).
    Recommended: `azurerm_key_vault_certificate` with a `Self` issuer policy
    in the existing vault, a user-assigned identity on the gateway with
    `Key Vault Secrets User`, and `ssl_certificate { key_vault_secret_id }`.
    Fallback: Terraform `tls` provider + PFX via openssl in `apply.sh`.
  - `request_timeout`: raise well above 30 s. Guacamole tunnels are long
    lived; check whether the gateway drops idle WebSocket sessions and set
    what's needed so a desktop session doesn't disconnect after a minute.
  - Cost note for Mike: App Gateway v2 has a fixed hourly cost, unlike ALB's
    near-zero idle. Fine for the lab; mention it in the README.

### Scripts

- `apply.sh`: 3 phases as today (directory, packer, servers). Keep
  `check_env.sh`. Each run builds a fresh image; phase 3 uses the newest.
- `validate.sh`: port AWS's: wait for the gateway backend to be healthy,
  sign in to Guacamole's REST API as `jsmith` (password from Key Vault),
  assert all three connections are granted, print the URL (App Gateway
  public IP FQDN) and the sign-in line.
- `destroy.sh`: phase 3, delete images, delete secrets if needed, phase 1.
  Key Vault is purge-protection off already. Keep it idempotent.
- `README.md`: rewrite around Guacamole using the AWS README as the
  template (Try it, Troubleshooting table, Notes "Lab only"). Remove the
  Lubuntu workstation screenshots/drawio from the seed or replace them.
  AWS has `make_diagram.py` for its architecture SVGs; an Azure version is
  nice-to-have, not required.

## Definition of done

1. `./apply.sh` from clean succeeds; `./validate.sh` passes.
2. Browser → App Gateway URL → cert warning → sign in as `jsmith`.
3. `Lubuntu (RDP)`: LXQt desktop as jsmith, home created on first login;
   Firefox (snap) opens from the menu and as default browser.
4. `Lubuntu (SSH)`: clean prompt (no OSC 3008 text); `id`, `sudo -l` works
   for jsmith (linux-admins).
5. `Windows (RDP)`: desktop as `MCLOUD\jsmith` (allow ~10 min after deploy
   for the domain join + reboot).
6. Sign in as `rpatel`: same connections, no admin menu, no sudo.
7. No VM has a public IP; only the App Gateway does.
8. `./destroy.sh` leaves nothing behind.

## House conventions

- Follow the repo `CLAUDE.md` commenting standards if present (Mike's
  standard): comment the *why*, lines ≤ 80 chars, 80-wide `# ===` section
  headers in `.tf`/`.sh`/`.py`, `set -euo pipefail` in every shell script,
  scripts idempotent where possible.
- Mirror the AWS repo's file names and structure where Azure allows it, so
  the two read as a pair.
- Record any Azure-specific gotcha you hit (and its fix) in the README
  Troubleshooting table, the way AWS does.

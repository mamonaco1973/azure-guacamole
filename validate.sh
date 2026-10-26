#!/bin/bash
# ==============================================================================
# validate.sh - Guacamole + Active Directory on Azure: deployment check
# ------------------------------------------------------------------------------
#   - Waits for the App Gateway to report the Guacamole server healthy (its
#     setup takes a few minutes after Terraform finishes).
#   - Checks the HTTPS URL answers (self-signed certificate, so curl -k) and
#     that HTTP redirects to it.
#   - Signs in to Guacamole's API as jsmith -- LDAPS to AD, the mcloud-users
#     group gate -- and checks all three connections are granted.
#   - Checks no VM has a public IP.
#   - Prints the URL and a login. One line per check, then a summary.
# ==============================================================================
set -euo pipefail
cd "$(dirname "$0")"

fail() { echo "FAILED"; echo "ERROR: $*" >&2; exit 1; }
step() { printf '%-58s' "$1..."; }
ok()   { echo "${1:-ok}"; }

out() { terraform -chdir=03-servers output -raw "$1" 2>/dev/null || true; }
URL="$(out guacamole_url)"
RG="$(out resource_group_name)"
APPGW="$(out app_gateway_name)"
VAULT="$(out vault_name)"
GUAC_VM="$(out guacamole_vm_name)"
[ -n "${URL}" ] || fail "No guacamole_url output. Run ./apply.sh first."

LOG_HINT="az vm run-command invoke -g ${RG} -n ${GUAC_VM} --command-id RunShellScript --scripts 'tail -50 /root/userdata.log'"

# ------------------------------------------------------------------------------
# App Gateway backend health (Guacamole's setup: Docker, images, LDAPS trust)
# ------------------------------------------------------------------------------
# Each show-backend-health call runs a live probe and can take a minute, so
# print the state after every call instead of sitting silent.
echo "Guacamole healthy behind the App Gateway (up to 15 min)..."
STATE=""
START=${SECONDS}
while :; do
  STATE="$(az network application-gateway show-backend-health \
    --resource-group "${RG}" --name "${APPGW}" \
    --query 'backendAddressPools[0].backendHttpSettingsCollection[0].servers[0].health' \
    --output tsv 2>/dev/null || true)"
  ELAPSED=$((SECONDS - START))
  printf "  %02d:%02d  %-49s" $((ELAPSED / 60)) $((ELAPSED % 60)) "backend ${STATE:-not reported yet}"
  if [ "${STATE}" = "Healthy" ]; then
    ok
    break
  fi
  echo "waiting"
  ((ELAPSED < 900)) || fail "Backend is '${STATE}'. Setup log: ${LOG_HINT}"
  sleep 10
done

step "HTTPS answers at the App Gateway"
CODE="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "${URL}")"
[ "${CODE}" = "200" ] || fail "${URL} answered ${CODE}."
ok

step "HTTP redirects to HTTPS"
LOCATION="$(curl -s --max-time 15 -o /dev/null -w '%{redirect_url}' "${URL/https:/http:}")"
[ "${LOCATION}" = "${URL}" ] || fail "http:// redirected to '${LOCATION}'."
ok

# ------------------------------------------------------------------------------
# Sign in as an AD user and list the connections Guacamole grants
# ------------------------------------------------------------------------------
JSMITH="$(az keyvault secret show --vault-name "${VAULT}" --name jsmith-credentials \
  --query value --output tsv | jq -r .password)"

step "Sign-in as jsmith (LDAPS to AD)"
TOKEN=""
for ((i = 0; i < 12; i++)); do
  TOKEN="$(curl -sk --max-time 15 -X POST "${URL}api/tokens" \
    --data-urlencode "username=jsmith" --data-urlencode "password=${JSMITH}" \
    | jq -r '.authToken // empty' 2>/dev/null || true)"
  [ -n "${TOKEN}" ] && break
  sleep 10
done
[ -n "${TOKEN}" ] || fail "jsmith could not sign in. Check LDAPS from the Guacamole server (cd /opt/guacamole && docker compose logs guacamole)."
ok

step "Connections granted to mcloud-users"
CONNECTIONS="$(curl -sk --max-time 15 "${URL}api/session/data/postgresql/connections" \
  -H "Guacamole-Token: ${TOKEN}" | jq -r '[.[].name] | sort | join(", ")')"
[ "${CONNECTIONS}" = "Lubuntu (RDP), Lubuntu (SSH), Windows (RDP)" ] || fail "Expected three connections, got '${CONNECTIONS}'."
ok "${CONNECTIONS}"
curl -sk -o /dev/null -X DELETE "${URL}api/session" -H "Guacamole-Token: ${TOKEN}" || true

# ------------------------------------------------------------------------------
# Only the App Gateway (and the NAT gateway, outbound only) have public IPs
# ------------------------------------------------------------------------------
step "No VM has a public IP"
VM_PIPS="$(az vm list-ip-addresses --resource-group "${RG}" \
  --query "[].virtualMachine.network.publicIpAddresses[].ipAddress" --output tsv)"
[ -z "${VM_PIPS}" ] || fail "VMs have public IPs: ${VM_PIPS}"
ok

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
cat <<EOF

Guacamole + Active Directory
============================
URL      : ${URL}
           Self-signed certificate: the browser warns once;
           choose Advanced > Proceed.
Sign in  : jsmith / ${JSMITH}
           (any mcloud-users member; passwords in Key Vault ${VAULT}
           as <user>-credentials)
Connect  : Windows (RDP), Lubuntu (RDP desktop) and Lubuntu (SSH),
           as the signed-in user.
EOF

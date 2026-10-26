#!/bin/bash
# ==============================================================================
# custom_data_guacamole.sh  —  Apache Guacamole behind the App Gateway
#
# Runs guacd, the Guacamole web app and PostgreSQL in Docker on this private
# VM. The App Gateway terminates HTTPS and forwards to Tomcat on :8080.
#
#   Sign-in   LDAP against the mini-AD (LDAPS, port 636). Only members of
#             mcloud-users may log in. The DC's own CA is fetched from
#             http://<dc>/ca.pem and put in a Java trust store for that.
#   Access    Three connections live in PostgreSQL: RDP to the Windows host,
#             and RDP (XRDP, an LXQt desktop) and SSH to the Lubuntu host. All
#             pass the user's own AD credentials through ($${GUAC_USERNAME} / $${GUAC_PASSWORD} tokens), so one
#             sign-in reaches both. The database grants them to a group named
#             mcloud-users, which Guacamole matches to the AD group.
#   Admin     Members of linux-admins also get Guacamole's ADMINISTER right.
#             The built-in guacadmin account is disabled.
# ==============================================================================
set -euo pipefail
exec > >(tee -a /root/userdata.log | logger -t user-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR
echo "guacamole custom-data start ($(date -Is))"

hostnamectl set-hostname guacamole
export DEBIAN_FRONTEND=noninteractive

GUAC_VERSION="${guac_version}"
GUAC_DIR=/opt/guacamole
mkdir -p "$GUAC_DIR/initdb" "$GUAC_DIR/tls"

# ------------------------------------------------------------------------------
# Packages: Docker + compose, jq
# ------------------------------------------------------------------------------
apt-get update -y
apt-get install -y docker.io docker-compose-v2 jq curl openssl
systemctl enable --now docker

# ------------------------------------------------------------------------------
# LDAP bind credential: the AD admin account, read-only use (user searches).
# Read from Key Vault with the VM's managed identity (an IMDS token; no Azure
# CLI needed). The role assignment is created after the VM, so the first reads
# can return 403 until it propagates: retry.
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
bind_password=$(echo "$secret" | jq -r .password)

# ------------------------------------------------------------------------------
# Trust the DC's certificate for LDAPS
# ------------------------------------------------------------------------------
# The Samba DC generates its own CA and serves it at /ca.pem. Retry: the DC
# may still be finishing its own boot when this instance starts.
for i in $(seq 1 60); do
  if curl -fsS "http://${dc_fqdn}/ca.pem" -o "$GUAC_DIR/tls/ca.pem"; then break; fi
  echo "waiting for http://${dc_fqdn}/ca.pem ($i/60)"
  sleep 10
done
grep -q "BEGIN CERTIFICATE" "$GUAC_DIR/tls/ca.pem"

docker pull "guacamole/guacamole:$GUAC_VERSION"
docker pull "guacamole/guacd:$GUAC_VERSION"
docker pull postgres:16

# keytool from the Guacamole image's own JRE, so the store matches its Java.
docker run --rm --user root --entrypoint keytool -v "$GUAC_DIR/tls:/tls" \
  "guacamole/guacamole:$GUAC_VERSION" \
  -importcert -noprompt -alias mini-ad-ca -file /tls/ca.pem \
  -keystore /tls/truststore.jks -storepass changeit
chmod 644 "$GUAC_DIR/tls/truststore.jks"

# ------------------------------------------------------------------------------
# Database: Guacamole's schema, then this demo's connections and groups
# ------------------------------------------------------------------------------
docker run --rm "guacamole/guacamole:$GUAC_VERSION" \
  /opt/guacamole/bin/initdb.sh --postgresql > "$GUAC_DIR/initdb/001-schema.sql"

# Quoted heredoc: the $${GUAC_...} tokens must reach the database literally;
# Guacamole fills them in with the signed-in user's credentials.
cat > "$GUAC_DIR/initdb/002-demo.sql" <<'SQL'
-- Three connections; each passes the signed-in user's AD credentials through.
INSERT INTO guacamole_connection (connection_name, protocol) VALUES
  ('Windows (RDP)', 'rdp'),
  ('Lubuntu (RDP)', 'rdp'),
  ('Lubuntu (SSH)', 'ssh');

INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT c.connection_id, p.name, p.value
FROM guacamole_connection c,
     (VALUES ('hostname',    '${windows_ip}'),
             ('port',        '3389'),
             ('username',    '$${GUAC_USERNAME}'),
             ('password',    '$${GUAC_PASSWORD}'),
             ('domain',      '${netbios}'),
             ('security',    'nla'),
             ('ignore-cert', 'true'),
             ('resize-method', 'display-update')) AS p(name, value)
WHERE c.connection_name = 'Windows (RDP)';

-- XRDP does not do NLA: TLS security, and no domain (PAM + SSSD checks the
-- bare username against AD).
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT c.connection_id, p.name, p.value
FROM guacamole_connection c,
     (VALUES ('hostname',    '${lubuntu_ip}'),
             ('port',        '3389'),
             ('username',    '$${GUAC_USERNAME}'),
             ('password',    '$${GUAC_PASSWORD}'),
             ('security',    'tls'),
             ('ignore-cert', 'true'),
             ('resize-method', 'display-update')) AS p(name, value)
WHERE c.connection_name = 'Lubuntu (RDP)';

INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT c.connection_id, p.name, p.value
FROM guacamole_connection c,
     (VALUES ('hostname', '${lubuntu_ip}'),
             ('port',     '22'),
             ('username', '$${GUAC_USERNAME}'),
             ('password', '$${GUAC_PASSWORD}')) AS p(name, value)
WHERE c.connection_name = 'Lubuntu (SSH)';

-- Groups named like the AD groups: Guacamole applies a database group's
-- permissions to LDAP users who are members of the AD group of that name.
INSERT INTO guacamole_entity (name, type) VALUES
  ('mcloud-users', 'USER_GROUP'),
  ('linux-admins', 'USER_GROUP');
INSERT INTO guacamole_user_group (entity_id)
SELECT entity_id FROM guacamole_entity
WHERE type = 'USER_GROUP' AND name IN ('mcloud-users', 'linux-admins');

INSERT INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, c.connection_id, 'READ'
FROM guacamole_entity e, guacamole_connection c
WHERE e.type = 'USER_GROUP' AND e.name = 'mcloud-users';

INSERT INTO guacamole_system_permission (entity_id, permission)
SELECT entity_id, 'ADMINISTER' FROM guacamole_entity
WHERE type = 'USER_GROUP' AND name = 'linux-admins';

-- The built-in guacadmin/guacadmin account is a well-known login: disable it.
UPDATE guacamole_user SET disabled = true
WHERE entity_id = (SELECT entity_id FROM guacamole_entity
                   WHERE type = 'USER' AND name = 'guacadmin');
SQL

# ------------------------------------------------------------------------------
# Compose
# ------------------------------------------------------------------------------
# Secrets go in .env (root-only); the compose file references them.
umask 077
cat > "$GUAC_DIR/.env" <<ENV
PG_PASSWORD=$(openssl rand -hex 24)
LDAP_BIND_PASSWORD=$bind_password
ENV
umask 022

cat > "$GUAC_DIR/docker-compose.yml" <<'YAML'
services:
  guacd:
    image: guacamole/guacd:${guac_version}
    restart: unless-stopped

  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_DB: guacamole_db
      POSTGRES_USER: guacamole
      POSTGRES_PASSWORD: $${PG_PASSWORD}
    volumes:
      - ./initdb:/docker-entrypoint-initdb.d:ro
      - pgdata:/var/lib/postgresql/data

  guacamole:
    image: guacamole/guacamole:${guac_version}
    restart: unless-stopped
    depends_on: [guacd, postgres]
    ports:
      - "8080:8080"
    volumes:
      - ./tls:/etc/guacamole-tls:ro
    environment:
      GUACD_HOSTNAME: guacd
      # Serve at / instead of /guacamole/, so the App Gateway URL is the app.
      WEBAPP_CONTEXT: ROOT
      JAVA_OPTS: "-Djavax.net.ssl.trustStore=/etc/guacamole-tls/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit"

      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_DATABASE: guacamole_db
      POSTGRESQL_USERNAME: guacamole
      POSTGRESQL_PASSWORD: $${PG_PASSWORD}
      POSTGRESQL_AUTO_CREATE_ACCOUNTS: "true"

      LDAP_HOSTNAME: ${dc_fqdn}
      LDAP_PORT: "636"
      LDAP_ENCRYPTION_METHOD: ssl
      LDAP_USER_BASE_DN: "CN=Users,${base_dn}"
      LDAP_USERNAME_ATTRIBUTE: sAMAccountName
      LDAP_SEARCH_BIND_DN: "CN=Admin,CN=Users,${base_dn}"
      LDAP_SEARCH_BIND_PASSWORD: $${LDAP_BIND_PASSWORD}
      LDAP_USER_SEARCH_FILTER: "(&(objectClass=user)(memberOf=CN=mcloud-users,CN=Users,${base_dn}))"
      LDAP_GROUP_BASE_DN: "CN=Users,${base_dn}"
      LDAP_GROUP_SEARCH_FILTER: "(objectClass=group)"

volumes:
  pgdata: {}
YAML

cd "$GUAC_DIR"
docker compose up -d

for i in $(seq 1 60); do
  if curl -fsS -o /dev/null http://localhost:8080/; then
    echo "guacamole is answering on :8080"
    break
  fi
  sleep 5
done
echo "guacamole custom-data done ($(date -Is))"

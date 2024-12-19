#!/bin/bash
set -xe

if [[ -d "/ldapdata.NEEDINIT"  ]]; then
    cp -ra /ldapdata.NEEDINIT/* /ldapdata/
    mv /ldapdata.NEEDINIT /ldapdata.orig
fi
# Reduce maximum number of open file descriptors to 1024
ulimit -n 1024

# Check if required environment variables are set
required_vars=(LDAP_ROOT_PASSWD base_primary_dc base_secondary_dc base_subdomain_dc cn ou1 ou2 ou3 ou4 ou5 ou6 ou7 primary_ldap_server_ip secondary_ldap_server_ip)

for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: Environment variable $var is not set." >&2
    exit 1
  fi
done


# Set default OpenLDAP debug level if not provided
OPENLDAP_DEBUG_LEVEL=${OPENLDAP_DEBUG_LEVEL:-256}

# Run initial setup if not already configured
if [ ! -f /etc/openldap/CONFIGURED ]; then
  # Check if running as root
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: Script must be run as root." >&2
    exit 1
  fi
  # Generate configuration files from templates
  envsubst < /ldap_config/basedomain.ldif.template > /ldap_config/basedomain.ldif
  envsubst < /ldap_config/chdomain.ldif.template > /ldap_config/chdomain.ldif
  envsubst < /ldap_config/ldap.conf.template > /etc/openldap/ldap.conf
  envsubst < /ldap_config/nslcd.conf.template > /etc/nslcd.conf
  envsubst < /ldap_config/multi-master/server1.ldif.template > /ldap_config/multi-master/server1.ldif
  envsubst < /ldap_config/multi-master/server2.ldif.template > /ldap_config/multi-master/server2.ldif

  # Start slapd in the background
  slapd -h "ldap:/// ldaps:/// ldapi:///" -d 256 > /dev/null 2>&1 &
  slapd_pid=$!

  # Wait for slapd to start
  for i in {1..30}; do
    if ldapsearch -Y EXTERNAL -H ldapi:/// -s base -b "cn=config" > /dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if ! ps -p "$slapd_pid" > /dev/null 2>&1; then
    echo "Error: slapd failed to start." >&2
    exit 1
  fi

  # Generate root password hash
  OPENLDAP_ROOT_PASSWORD_HASH=$(slappasswd -s "${LDAP_ROOT_PASSWD}")
  echo "${OPENLDAP_ROOT_PASSWORD_HASH}" > /ldap_root_hash_pw

  # Set root password
  sed -i "s|OPENLDAP_ROOT_PASSWORD|${OPENLDAP_ROOT_PASSWORD_HASH}|g" /ldap_config/chrootpw.ldif
  ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/chrootpw.ldif|| { echo "Error: Failed to set root password."; exit 1; }

  # Add basic schemas
  ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/cosine.ldif -d $OPENLDAP_DEBUG_LEVEL > /dev/null 2>&1
  ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/inetorgperson.ldif -d $OPENLDAP_DEBUG_LEVEL > /dev/null 2>&1
  ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/nis.ldif -d $OPENLDAP_DEBUG_LEVEL > /dev/null 2>&1
  # Configure the domain
  sed -i "s|OPENLDAP_ROOT_PASSWORD|${OPENLDAP_ROOT_PASSWORD_HASH}|g" /ldap_config/chdomain.ldif
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /ldap_config/chdomain.ldif|| { echo "Error: Failed to configure domain."; exit 1; }

  # Add basedomain entries
  # Check if basedomain entries already exist
  if ! ldapsearch -x -D "cn=${cn},dc=${base_secondary_dc},dc=${base_primary_dc}" \
       -w "${LDAP_ROOT_PASSWD}" -b "dc=${base_secondary_dc},dc=${base_primary_dc}" "(objectClass=*)" > /dev/null 2>&1; then

       echo "Basedomain entries not found. Adding basedomain entries..."

       # Add basedomain entries
       ldapadd -x -D "cn=${cn},dc=${base_secondary_dc},dc=${base_primary_dc}" \
          -w "${LDAP_ROOT_PASSWD}" -f /ldap_config/basedomain.ldif || \
          { echo "Error: Failed to add basedomain entries."; exit 1; }
  else
       echo "Basedomain entries already exist. Skipping ldapadd."
  fi
  #Add [syncprov] module
  ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/multi-master/mod_syncprov.ldif > /dev/null 2>&1
  ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/multi-master/syncprov.ldif > /dev/null 2>&1

  # Run LDIF file based on SERVER_ROLE
  case "$SERVER_ROLE" in
    "server1")
      ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/multi-master/server1.ldif > /dev/null 2>&1 &
      ;;
    "server2")
      ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/multi-master/server2.ldif > /dev/null 2>&1 &
      ;;
    *)
      echo "Error: SERVER_ROLE not set or invalid. Exiting."
      exit 1
      ;;
  esac


  # Stop slapd
  kill -2 "$slapd_pid"
  wait "$slapd_pid" || { echo "Error: slapd did not stop correctly."; exit 1; }

  # Test configuration files
  slaptest || echo "Warning: Configuration test failed. Check the output for details."

  # Cleanup
  rm -rf /ldap_config/*.template
  touch /etc/openldap/CONFIGURED
  ssh-keygen -A > /dev/null 2>&1
  #start the nslcd service
fi

# Start slapd in the foreground
if ! pgrep -x "slapd" > /dev/null; then
    echo "Starting slapd..."
    slapd -h "ldap:/// ldaps:/// ldapi:///" -d "$OPENLDAP_DEBUG_LEVEL" &
fi

# Wait for slapd to be ready
echo "Waiting for slapd to start..."
while ! ldapsearch -x -b "" -s base -LLL >/dev/null 2>&1; do
    sleep 1
done
echo "slapd is ready."

# Start nslcd
if ! pgrep -x "nslcd" > /dev/null; then
    echo "Starting nslcd..."
    /usr/sbin/nslcd
fi

# Keep the container running
timeout 10s wait

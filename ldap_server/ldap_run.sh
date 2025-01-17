#!/bin/bash
set -xe

variable_set() {
    # Check if required environment variables are set
    required_vars=(LDAP_ROOT_PASSWD base_primary_dc base_secondary_dc base_subdomain_dc cn ou1 ou2 ou3 ou4 ou5 ou6 ou7 primary_ldap_server_ip secondary_ldap_server_ip uidNumber gidNumber SERVER_ROLE)

    # Set default OpenLDAP debug level if not provided
    OPENLDAP_DEBUG_LEVEL=${OPENLDAP_DEBUG_LEVEL:-256}

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "Error: Environment variable $var is not set." >&2
            exit 1
        fi
    done

    # Generate configuration files from templates
    envsubst < /ldap_config/basedomain.ldif.template > /ldap_config/basedomain.ldif
    envsubst < /ldap_config/chdomain.ldif.template > /ldap_config/chdomain.ldif
    envsubst < /ldap_config/multi-master/server1.ldif.template > /ldap_config/multi-master/server1.ldif
    envsubst < /ldap_config/multi-master/server2.ldif.template > /ldap_config/multi-master/server2.ldif
    envsubst < /ldap_config/nslcd.conf.template > /etc/nslcd.conf
    envsubst < /ldap_config/migrate_common.ph.template > /usr/share/migrationtools/migrate_common.ph
    envsubst < /ldap_config/ldap-script/testuser.ldif.template > /ldap_config/ldap-script/testuser.ldif
}

ldap_conf() {
    local server_role=$1
    local ldap_conf_file

    case "$server_role" in
        "server1")
            ldap_conf_file="/ldap_config/server1_ldap.conf.template"
            ;;
        "server2")
            ldap_conf_file="/ldap_config/server2_ldap.conf.template"
            ;;
        *)
            echo "Error: SERVER_ROLE not set or invalid. Exiting."
            exit 1
            ;;
    esac

    # Set ldap.conf file
    envsubst < "$ldap_conf_file" > /etc/openldap/ldap.conf
}

enable_slapd_service() {
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
}

ldap_root_pw() {
    # Generate root password hash
    OPENLDAP_ROOT_PASSWORD_HASH=$(slappasswd -s "${LDAP_ROOT_PASSWD}")
    echo "${OPENLDAP_ROOT_PASSWORD_HASH}" > /ldap_root_hash_pw

    # Set root password
    sed -i "s|OPENLDAP_ROOT_PASSWORD|${OPENLDAP_ROOT_PASSWORD_HASH}|g" /ldap_config/chrootpw.ldif
    ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/chrootpw.ldif || { echo "Error: Failed to set root password."; exit 1; }
}

import_basic_schema() {
    # Add basic schemas
    ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/cosine.ldif -d $OPENLDAP_DEBUG_LEVEL > /dev/null 2>&1
    ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/nis.ldif -d $OPENLDAP_DEBUG_LEVEL > /dev/null 2>&1
    ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/inetorgperson.ldif -d $OPENLDAP_DEBUG_LEVEL > /dev/null 2>&1
    ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/openldap/schema/nsmattribute.ldif -d $OPENLDAP_DEBUG_LEVEL > /dev/null 2>&1
}

set_domain_name() {
    # Configure the domain
    sed -i "s|OPENLDAP_ROOT_PASSWORD|${OPENLDAP_ROOT_PASSWORD_HASH}|g" /ldap_config/chdomain.ldif
    ldapmodify -Y EXTERNAL -H ldapi:/// -f /ldap_config/chdomain.ldif || { echo "Error: Failed to configure domain."; exit 1; }

    # Add basedomain entries
    if ! ldapsearch -x -D "cn=${cn},dc=${base_secondary_dc},dc=${base_primary_dc}" \
         -w "${LDAP_ROOT_PASSWD}" -b "dc=${base_secondary_dc},dc=${base_primary_dc}" "(objectClass=*)" > /dev/null 2>&1; then

        echo "Basedomain entries not found. Adding basedomain entries..."
        ldapadd -x -D "cn=${cn},dc=${base_secondary_dc},dc=${base_primary_dc}" \
            -w "${LDAP_ROOT_PASSWD}" -f /ldap_config/basedomain.ldif || \
            { echo "Error: Failed to add basedomain entries."; exit 1; }
    else
        echo "Basedomain entries already exist. Skipping ldapadd."
    fi
}

set_module_config() {
    # Add syncprov module
    ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/multi-master/mod_syncprov.ldif > /dev/null 2>&1
    ldapadd -Y EXTERNAL -H ldapi:/// -f /ldap_config/multi-master/syncprov.ldif > /dev/null 2>&1
}

ldap_multi_master() {
    local server_role=$1
    local ldif_file

    case "$server_role" in
        "server1")
            ldif_file="/ldap_config/multi-master/server1.ldif"
            ;;
        "server2")
            ldif_file="/ldap_config/multi-master/server2.ldif"
            ;;
        *)
            echo "Error: SERVER_ROLE not set or invalid. Exiting."
            exit 1
            ;;
    esac

    # Execute the ldapadd command
    ldapadd -Y EXTERNAL -H ldapi:/// -f "$ldif_file" > /dev/null 2>&1 &
    envsubst < /ldap_config/ldap.conf.template > /etc/openldap/ldap.conf
}

Stop_slapd() {
    # Stop slapd service
    kill -2 "$slapd_pid"
    wait "$slapd_pid" || { echo "Error: slapd did not stop correctly."; exit 1; }
}

slap_test() {
    # Test configuration files
    slaptest || echo "Warning: Configuration test failed. Check the output for details."
}

setup_complete() {
    # Mark setup as complete
    touch /etc/openldap/CONFIGURED
}

Start_ldap_services() {
    echo "Starting supervisord..."
    exec /usr/bin/supervisord -c /etc/supervisord.conf
}

if [ ! -f /etc/openldap/CONFIGURED ] && [[ -d "/ldapdata.NEEDINIT" ]]; then
    rsync -a --ignore-existing /ldapdata.NEEDINIT/* /ldapdata/
    mv /ldapdata.NEEDINIT /ldapdata.orig

    # Reduce maximum number of open file descriptors to 1024
    ulimit -n 1024

    variable_set
    ldap_conf "$SERVER_ROLE"
    enable_slapd_service
    ldap_root_pw
    import_basic_schema
    set_domain_name
    slap_test
    setup_complete
    set_module_config
    ldap_multi_master "$SERVER_ROLE"

    sleep 5
    Stop_slapd
    Start_ldap_services
else
    Start_ldap_services
fi

# Keep the container running
timeout 10s wait


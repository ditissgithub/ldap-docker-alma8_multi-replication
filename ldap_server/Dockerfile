# Use AlmaLinux base image
FROM almalinux/8-base:latest

# Maintainer information
LABEL maintainer="satishg@cdac.in"

RUN rm -rf /etc/openldap && mkdir -p /ldapdata/etc/openldap && ln -sf -t /etc /ldapdata/etc/openldap && \
    mkdir -p /ldapdata/var/lib/ldap && ln -sf -t /var/lib /ldapdata/var/lib/ldap

# Install dependencies
RUN dnf install -y wget vim procps-ng cyrus-sasl-devel libtool-ltdl-devel \
    openssl-devel libdb-devel make chrony gettext libtool autoconf tar gcc \
    perl perl-devel epel-release && \
    dnf config-manager --set-enabled powertools && \
    dnf --enablerepo=epel install -y openldap-servers openldap-clients openldap openldap-devel && \
    dnf install -y nss-pam-ldapd iproute oddjob openssh-server && \
    dnf clean all

COPY ./migrationtools-47-35.el8.noarch.rpm /
# Configure OpenLDAP default files
RUN cp /usr/share/openldap-servers/DB_CONFIG.example /var/lib/ldap/DB_CONFIG && \
    chown -R ldap:ldap /var/lib/ldap /etc/openldap && \
    rpm -ivh /migrationtools-47-35.el8.noarch.rpm

# Copy LDAP configuration files
COPY ./ldap_config /ldap_config

COPY ./ldap_int-auth/nsswitch.conf /etc/nsswitch.conf
COPY ./ldap_int-auth/password-auth /etc/pam.d/
COPY ./ldap_int-auth/system-auth /etc/pam.d/
COPY ./etc_openldap_config/ldap.conf.template /ldap_config/
COPY ./etc_openldap_config/migrate_common.ph.template /ldap_config/

RUN sed -i -e 's|#PermitRootLogin yes|PermitRootLogin yes|g' \
           -e 's|#Port 22|Port 2201|g' \
           -e 's|#UseDNS yes|UseDNS no|g' /etc/ssh/sshd_config && \
    echo "StrictHostKeyChecking no" >> /etc/ssh/ssh_config && \
    echo "root:Rudra@@123" | chpasswd && \
    mv /ldapdata /ldapdata.NEEDINIT

# Copy startup script
COPY ./ldap_run.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/ldap_run.sh

# Expose LDAP and LDAPS ports
EXPOSE 389 636


# Set the entrypoint script
ENTRYPOINT ["/usr/local/bin/ldap_run.sh"]

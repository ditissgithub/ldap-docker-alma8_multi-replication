#!/bin/bash

read -p "Enter user name:" id
dc=$(ldapsearch -x uid=$id | grep dn: | cut -d' ' -f2)
read -p "Enter user new password:" pass
echo ""
ldappasswd -s $pass -W -D "cn=Manager,dc=nsm,dc=in" -x "$dc"

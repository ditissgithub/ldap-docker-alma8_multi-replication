#!/bin/bash

set -x

pass=Admin@@123

echo "Enter The username you want to delete: " ; read uname
echo $uname
##echo " $uname is present "
dname=$(ldapsearch -x cn=$uname | grep dn: | head -n 1 | cut -d : -f2 | sed 's/^ *//g')
echo $dname
dname1=$(ldapsearch -x cn=$uname | grep dn: | tail -n -1 | cut -d : -f2 | sed 's/^ *//g')
echo $dname1
ldapdelete -H ldap://172.25.0.1 -x -D "cn=Manager,dc=nsm,dc=in" -w $pass  "$dname"
ou1=$(ldapsearch -x cn=$uname | grep dn: | head -n 1 | cut -d : -f2 | cut -d ',' -f2 | cut -d = -f2 | sed 's/^ *//g')
echo "user deleted from $ou1 organization..."
ldapdelete -H ldap://172.25.0.1 -x -D "cn=Manager,dc=nsm,dc=in" -w $pass  "$dname1"
ou2=$(ldapsearch -x cn=$uname | grep dn: | tail -n -1 | cut -d : -f2 | cut -d ',' -f2 | cut -d = -f2 | sed 's/^ *//g')
echo "user deleted from $ou2 ..."

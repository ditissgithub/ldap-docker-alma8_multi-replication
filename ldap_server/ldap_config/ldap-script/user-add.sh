#!/bin/bash
while IFS= read -r line; do
        line=$(echo $line | sed 's/^\s+//g' )
        a="$a $line^"
done < "file"
echo $a
#-------------------------------------------------------------
value=$(cat file | wc -l)
if [[ $value -lt 20 ]];then
echo "%$%$%$%$---All Fields are neccessary---$%$%$%$"
exit 1
fi
#--------------------------------------------------------------
displayName=$(echo $a | awk -F '[:^]' '{print $2}');name=$(echo $a | awk -F '[:^]' '{print $4}')
em=$(echo $a | awk -F '[:^]' '{print $6}');organization=$(echo $a | awk -F '[:^]' '{print $8}')
mobile=$(echo $a | awk -F '[:^]' '{print $10}');gender=$(echo $a | awk -F '[:^]' '{print $12}')
institute=$(echo $a | awk -F '[:^]' '{print $14}');department=$(echo $a | awk -F '[:^]' '{print $16}')
designation=$(echo $a | awk -F '[:^]' '{print $18}');domain=$(echo $a | awk -F '[:^]' '{print $20}')
subdomain=$(echo $a | awk -F '[:^]' '{print $22}');application=$(echo $a | awk -F '[:^]' '{print $24}')
projectname=$(echo $a | awk -F '[:^]' '{print $26}');
pi=$(echo $a | awk -F '[:^]' '{print $28}');amount=$(echo $a | awk -F '[:^]' '{print $30}')
funded=$(echo $a | awk -F '[:^]' '{print $32}');cpuhours=$(echo $a | awk -F '[:^]' '{print $34}')
gpuhours=$(echo $a | awk -F '[:^]' '{print $36}');startdate=$(echo $a | awk -F '[:^]' '{print $38}')
enddate=$(echo $a | awk -F '[:^]' '{print $40}');address=$(echo $a | awk -F '[:^]' '{print $42}')
description=$(echo $a | awk -F '[:^]' '{print $44}');
#------------------------------------------------------------------------------------------------
count=`ldapsearch -x dc=* | grep dn: | wc -l`
if [[ $count -ge 2 ]]
then
  dc=`ldapsearch -x dc=* | grep dn: | head -n 1 | cut -d : -f2 | sed 's/^ *//g'`
  dc1=`ldapsearch -x dc=* | grep dn: | tail -n +2 | cut -d : -f2 | sed 's/^ *//g'`
else
  dc=`ldapsearch -x dc=* | grep dn: | head -n 1 | cut -d : -f2 | sed 's/^ *//g'`
  dc1=`ldapsearch -x dc=* | grep dn: | head -n 1 | cut -d : -f2 | sed 's/^ *//g'`
fi

#------------------------------------------------------------------------------------------------
useradd $name
#--------------------------------------- Adding passowrd ------------------------------------------
echo "$name@@321" | passwd $name --stdin
echo "User password is $name@@321"

#---------------------------------------- Creating Local User ----------------------------------------
grep "^$name" /etc/passwd > /tmp/passwd
grep "^$name" /etc/group > /tmp/group
#---------------------------------------- Creating Ldif file ------------------------------------------
cd /usr/share/migrationtools
./migrate_passwd.pl /tmp/passwd /tmp/users.ldif
./migrate_group.pl /tmp/group /tmp/groups.ldif
sed -i "/mail:/s/.*/mail: $em/; s/ou=People/ou=$organization/g; /^$/d" /tmp/users.ldif
echo """ObjectClass: ExtensibleObject
displayName: $displayName
mobile: $mobile
gender: $gender
institute: $institute
department: $department
designation: $designation
application: $application
projectname: $projectname
mail: $em
sn: $name
PI-HOD: $pi
domain: $domain
subdomain: $subdomain
amount: $amount
funded: $funded
cpuhours: $cpuhours
gpuhours: $gpuhours
startdate: $startdate
enddate: $enddate
address: $address
description: $description""" >> /tmp/users.ldif

read -p "Enter the Ldap Server Password :" pass
exitstatus=$?
if [[ $exitstatus == 0 ]]; then
    ldapadd -x -w "$pass" -D "cn=Manager,$dc" -f /tmp/users.ldif > /dev/null 2>&1
        if [[ $(echo $?) -eq 49 ]];then
                read -ep "Enter the valid LDAP password: " pass
                ldapadd -x -w "$pass" -D "cn=Manager,$dc"  -f /tmp/users.ldif > /dev/null 2>&1
        fi
        ldapadd -x -w "$pass" -D "cn=Manager,$dc" -f /tmp/groups.ldif > /dev/null 2>&1
        if [[ $(echo $?) -eq 49 ]];then
        echo "find out valid password of ldap Server"
        exit 1
        else
                echo "user:$name  created successfully . . ."
        fi

else
        echo "User selected Cancel."
        userdel $name
        exit 0
fi
#################################### scratch creation #############################################
mkdir /scratch/$name
chown $name:$name /scratch/$name
chmod 750 /scratch/$name
######################################### slurm account ###############################################
#read  -ep "Enter slurm account name for $name: " account
#sacctmgr add user name=$name  account=$account
####################################################################################################
ssh arya01 -- df -Th | grep drbd > /dev/null 2>&1
exitstatus=$?
read  -ep "Enter slurm account name for $name: " account
if [[ $exitstatus == 0 ]]; then
        ssh arya02 -- sacctmgr add user name=$name  account=$account
else
        ssh arya01 -- sacctmgr add user name=$name  account=$account
fi

########################################## lfs quota allocation ######################################

while true; do
        echo "Set Default quota for /home and /scratch"
        read -p "[Y]/N: " choice
        choice=${choice:-Y}
        choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')
        case "$choice" in
                Y)
                        lfs setquota -u $name -b 50G -B 50G  /home/
                        lfs setquota -u $name -b 200G -B 200G /scratch
                break
                ;;
                N)
                        read -ep "Enter quota space for /home:" hspace
                        read -ep "Enter quota space for /scratch:" sspace
                        lfs setquota -u $name -b $hspace -B 50G  /home/
                        lfs setquota -u $name -b $sspace -B 200G /scratch
                break
                ;;
                *) echo "Invalid choice. Please enter 'Y' or 'N'."
        ;;
        esac
done

########################################## lfs quota allocation ######################################
#read -ep "Enter quota space for /home:" hspace
#read -ep "Enter quota space for /scratch:" sspace
#lfs setquota -u $name -b 50G -B 50G  /home/
#lfs setquota -u $name -b 200G -B 200G /scratch
######################################### delete local user ##########################################
#getent passwd > /etc/passwd_sync
#getent group > /etc/group_sync
#getent shadow > /etc/shadow_sync
userdel $name

################################## Syncing user authenctication files ################################
#getent passwd > /drbd/xcatdata/synclists/passwd_data
#getent  group > /drbd/xcatdata/synclists/group_data
#getent  shadow > /drbd/xcatdata/synclists/shadow_data

#updatenode all -F

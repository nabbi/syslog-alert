#!/bin/sh

# configuration files
# if you change this path you'll have to patch the script
cp -v alert*.conf /etc/syslog-ng/

# script
# if you chage this path you'll need to update syslog-ng.conf
cp -v syslog-alert.tcl /usr/local/sbin/

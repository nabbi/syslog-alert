# Installation
If you change these paths then you'll have to patch the script and/or update syslog-ng.conf references

See USAGE.md for configuration setup

## configuration files
```
cp -iv alert*.conf /etc/syslog-ng/
chmod 600 /etc/syslog-ng/alert*.conf
```

## script
```
cp -iv syslog-alert.tcl /usr/local/sbin/
chmod 700 /usr/local/sbin/syslog-alert.tcl
```

# Installation
If you change these paths then you'll have to patch the script and/or update syslog-ng.conf references

See USAGE.md for configuration setup

## configuration files
```
cp -iv alert*.conf /etc/syslog-ng/
chmod 600 /etc/syslog-ng/alert*.conf
chown root:root /etc/syslog-ng/alert*.conf
```

## script
```
cp -iv syslog-alert.tcl /usr/local/sbin/
chmod 700 /usr/local/sbin/syslog-alert.tcl
chown root:root /usr/local/sbin/syslog-alert.tcl
```

## Security notes

- The configuration files (especially `alert.conf`) are **trusted input** and can
  execute arbitrary Tcl code via the CUSTOM field. Ensure they are only writable
  by root and not world-readable (mode 600).
- The script runs as the UID of syslog-ng. Restrict file ownership accordingly.
- Syslog input is treated as untrusted. Lines exceeding 8192 bytes are dropped.
- A hardened PATH is set at startup: `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`

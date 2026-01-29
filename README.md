# syslog-alert
I wrote this to dabble with TclOO while improving my solution for throttling email alerts from syslog-ng.

* Provides per host message throttling and is intended to run on a centralized log collector.
* Configurable sub exclusions to filter out false alarm noise.
* Selectively alert different support groups, including shorter messages to pagers or mobile devices.

## Concept
* Reads standard input from syslog-ng OSE by using the program() driver.
* Alerted logs are tracked within SQLite so recent occurrences can be discarded
* Sendmail recipients are compiled from group memberships within SQLite
* A single configuration file defines contacts, groups, and log pattern alert rules

## Configuration
The preferred configuration is a single `syslog-alert.conf` file using Tcl dict syntax.
See USAGE.md for the full format reference, and `syslog-alert.conf` for an example.

### Legacy configuration
The old two-file format (`alert.conf` + `alert-contacts.conf`) is still supported.
When no `syslog-alert.conf` is found, the program falls back to the legacy files
and prints a deprecation notice. See USAGE.md for details on both formats.

## CLI flags

```
--config <path>      Specify config file location
--check-config       Validate config and exit (0 = ok, 1 = error)
--dump-config        Load config and print normalized form
--explain "<line>"   Dry-run a syslog line, show matched rule without sending email
```

See USAGE.md and INSTALL.md for more information

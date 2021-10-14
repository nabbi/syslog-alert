# syslog-alert
I wrote this to dabble with TclOO while improving my solution for throttling email alerts from syslog-ng.

* Provides per host message throttling and is intended to run on a centralized log collector.
* Configurable sub exclusions to filter out false alarm noise.
* Selectively alert different support groups, including shorter messages to pagers or mobile devices.

## concept
* Reads standard input from syslog-ng OSE by using the program() driver.
* Alerted logs are tracked within SQLite so recent occurrences can be discarded
* Sendmail recipients are compiled from group memberships within SQLite
* Two configuration files define the contacts and log pattern alert actions

See USAGE.md and INSTALL.md for more information

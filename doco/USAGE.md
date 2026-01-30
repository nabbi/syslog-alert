# Usage

I originally wrote this as I needed a solution for throttling sendmail events piped from syslog-ng
which provided custom per host+message throttling yet was flexible to selectively send specific
events to a different distribution list or an after hours pager/mobile.

Delightfully written in Tcl as an experiment with TclOO
SQLite is used for an in memory database of tracking events


## CLI flags

```
--config <path>      Specify config file location (new format)
--check-config       Validate config and exit (0 = ok, 1 = error)
--dump-config        Load config and print normalized form
--explain "<line>"   Dry-run a syslog line, show matched rule without sending email
```

### Examples

Validate your config:
```
./syslog-alert.tcl --check-config --config syslog-alert.conf
```

Print normalized config:
```
./syslog-alert.tcl --dump-config --config syslog-alert.conf
```

Test what rule matches a syslog line (dry-run, no email sent):
```
./syslog-alert.tcl --explain "{2025-01-01T00:00:00} {testhost} {daemon} {err} {mdadm[123]:} {raid event detected}" --config syslog-alert.conf
```

Normal operation via stdin:
```
echo '{2025-01-01T00:00:00} {testhost} {daemon} {err} {mdadm[123]:} {raid event detected}' | ./syslog-alert.tcl --config syslog-alert.conf
```


## syslog-alert.conf (new format)

Single-file configuration using Tcl dict syntax. This replaces both `alert.conf` and `alert-contacts.conf`.

Copy to `/etc/syslog-ng/syslog-alert.conf` or specify with `--config <path>`.

### Structure

```tcl
global {
    from    syslog@myhost.example.com
    debug   0
    trace   0
}

contacts {
    username {
        groups  {group1 group2}
        email   user@example.com
        page    1111111111@carrier.com
    }
}

rules {
    rule-name {
        pattern  {"*glob*"}
        exclude  {field="*pattern*"}
        subject  {$log(host) description}
        delay    3600
        email    {group1 group2}
        page     group1
        ignore   0
        custom   {set subject "$log(host) custom"}
    }
}
```

### global section (optional)

- **from** - From address for sendmail. Defaults to `syslog@<hostname>`
- **debug** - Enable debug output (0/1)
- **trace** - Enable trace output showing generated switch method (0/1)

### contacts section (required)

Each contact is a named dict with:

- **groups** - Group memberships (string or list). Each group becomes a separate row in the internal lookup table
- **email** - Email address(es). Multiple addresses can be csv: `{one@ex.com, two@ex.com}`
- **page** - Pager/mobile address(es). Same format as email

At least one of `email` or `page` is required per contact.

Example:
```tcl
contacts {
    user1 {
        groups  {admin disk}
        email   user1@example.com
        page    1111111111@carrier.com
    }
    user2 {
        groups  oncall
        email   {user2work@example.com, user2home@example.com}
    }
    user3 {
        groups  disk
        page    3333333333@carrier.com
    }
}
```

### rules section (required)

Rules are evaluated in order, first match wins. Each rule is a named dict with:

- **pattern** (required) - Glob pattern(s) matched against `$log(all)` (the full reassembled log line). Use `default` for a catch-all.
  ```tcl
  pattern  {"*mdadm*"}
  pattern  {"*alert*" "*crit*"}
  pattern  {default}
  ```

- **exclude** (optional) - Sub-exclusion patterns. Glob matched against a specific log field. Multiple conditions are OR'd.
  ```tcl
  exclude  {host="foo*" level="debug"}
  exclude  {all="*crit*cron*some event*"}
  ```

- **subject** (optional) - Subject line for email/page. Also used as the throttle hash. Supports `$log()` variable substitution.
  ```tcl
  subject  {$log(host) raid event}
  ```

- **delay** (optional, default 0) - Throttle delay in seconds between repeated alerts for the same hash.

- **email** (optional) - Group name(s) to email.

- **page** (optional) - Group name(s) to page. Pages receive a shorter message (just `$log(msg)`).

- **ignore** (optional, default 0) - Set to 1 to silently drop matching lines.

- **custom** (optional) - Arbitrary Tcl code executed before email/page actions. Runs as the syslog-ng UID.
  ```tcl
  custom   {set subject "$log(host) event"}
  ```


## Notes on testing and troubleshooting

As a result of using only an in memory database, if this program crashes or syslog-ng restarts,
you may see alerts which notify again within X threshold. syslog-ng expects said program not to exit and
continually accept stdio -- you will see the pid change if this script happens to crash as syslog-ng will restart it

 *syslog.info syslog-ng[]: Child program exited, restarting; cmdline='/usr/local/sbin/syslog-alert.tcl', status='256'*

Use `--check-config` and `--explain` to validate your configuration before deploying.

You can run this program directly to validate the behaviors.
Paste or pipe in some test log messages to see what happens, this must match the syslog-ng template.

```
{datetime stamp} {sandbox} {error} {info} {smartd[12334]:} {test message}
{datetime stamp} {sandbox} {debug} {info} {smartd[555]:} {test message}
{datetime stamp} {sandbox} {debug} {info} {test[3333]:} {test message garbage}
```

Or to test this with syslog-ng generate events with logger (or trigger the real condition on the source)


## Legacy configuration (deprecated)

The old two-file format is still supported but deprecated. When no `syslog-alert.conf` is found
(and no `--config` flag is used), the program falls back to reading:

- `/etc/syslog-ng/alert-contacts.conf` - contact definitions
- `/etc/syslog-ng/alert.conf` - alert rules

A deprecation notice is printed to stdout when legacy files are used.

### alert-contacts.conf

syntax tcl list
```
{name} {group} {email@example.com} {pager@example.com}
{name} {group} {one@example.com, two@example.com} {pager1@example.com, pager2@example.com}
```

### alert.conf

syntax tcl list, some elements are lists themselves
```
{{pattern1} {pattern2}} {{exclude1} {exclude2}} {hash} {delay} {email} {page} {ignore} {custom tcl code}
```

See the example `alert.conf` and `alert-contacts.conf` files for reference.


## tcl 8.6 (tested with 8.6.11)

Originally there was dependency on tcllib (1.20) to provide csv (0.8.1)
While I included logic to import csv without this, I decided to rewrite the config
using lists instead as I found the statements easier to read.
Simpler. Possibly more portable as some distros ship with dated packages


## sqlite3 (tested with 3.35.5)

compiled with --enable-tcl

Was not written with TDBC - one could easily patch this if that is more desirable
as the database calls are not complex


## sendmail (tested with sSMTP 2.64)

expects to find a "sendmail" compatible in the system path


## syslog-ng (tested with 3.32.2)

This program depends on adjusting your /etc/syslog-ng/syslog-ng.conf

Below describes how to integrate this into your config as an external program call

### Template
In order to parse log events into variables, a predictable and parsable structure
needs to be established. We escape each message section with {} to create a tcl list.

```
template t_alert {
   template( "{${ISODATE}} {${HOST}} {${FACILITY}} {${LEVEL}} {${MSGHDR}} {${MSG}}\n" );
   template_escape(no);
};#
```

### Destination
Defines where you placed this script so syslog-ng can pipe events to it
Note that this is where you bind the template formatting

```
destination d_alert { program("/usr/local/sbin/syslog-alert.tcl" template(t_alert) mark-freq(0) ); };
```

To use a custom config path:
```
destination d_alert { program("/usr/local/sbin/syslog-alert.tcl --config /etc/syslog-ng/syslog-alert.conf" template(t_alert) mark-freq(0) ); };
```


### Filters
This script was written with the mindset of pre-filtering events within syslog-ng
The expectation is, if you pipe messages to this alert script then you intend send emails.

Think of syslog-ng as the course comb and this script as the fine side of the comb.
This results in some duplication of config mgmt; in syslog-ng.conf and within this script.
While it appears capable to handle forward all events, I haven't extensively load tested this inversed behavior.

```
filter f_level3 { level (err..emerg); };
```

### Log
This links your filters and destination together

```
log { source(s_net); source(s_local); filter(f_level3); destination(d_alert);  };
```

# Usage

I originally wrote this as I needed a solution for throttling sendmail events piped from syslog-ng
which provided custom per host+message throttling yet was flexible to selectively send specific 
events to a different distribution list or an after hours pager/mobile.

Delightfully written in Tcl as an experiment with TclOO
SQLite is used for an in memory database of tracking events

This has gone through various rewrites over the years. It started as a Perl script over a decade ago
which flocked a file for event tracking, it was a crude database (if you could even call it that).
Refreshed a few years ago in TclOO to leverage SQLite. For me, this was one of those scripts which
silently ran in the background and forgotten about. So this stayed around in this state for another year or 
three before I picked it up again.
This latest update expands filtering functionality, cleaner per group alerting, and leverages configuration
files instead of hacking the script.



## Notes on testing and troubleshooting

As a result of using only an in memory database, if this program crashes or syslog-ng restarts,
you may see alerts which notify again within X threshold. syslog-ng expects said program not to exit and 
continually accept stdio -- you will see the pid change if this script happens to crash as syslog-ng will restart it 

 *syslog.info syslog-ng[]: Child program exited, restarting; cmdline='/usr/local/sbin/syslog-alert.tcl', status='256'*

This usually indicates a syntax issue introduced into the code base. Since the switch condition is now generated 
from the user configuration file, errors have been reduced from manually editing conditions within code.
There is still high probability of a bad config to load or miss parse. Very minimal non-existent validations are performed
when reading these conf files.
Read up on TCL Lists if this is foreign to you.

That being said, what I have seen more likely is frequent restarts to syslog-ng itself triggering alerts to trigger again;
that is the anticipated design.


You can run this program directly to validate the behaviors.
Toggle debug and trace flags to log more info to stdout
Paste or pipe in some test log messages to see what happens, this must match the syslog-ng template.

```
{datetime stamp} {sandbox} {error} {info} {smartd[12334]:} {test message}
{datetime stamp} {sandbox} {debug} {info} {smartd[555]:} {test message}
{datetime stamp} {sandbox} {debug} {info} {test[3333]:} {test message garbage}
```

Or to test this with syslog-ng generate events with logger (or trigger the real condition on the source)


## alert-contacts.conf

copy into /etc/syslog-ng/

This file defines, based on a group label name, who should receive an alert

syntax tcl list
```
{name} {group} {email@example.com} {pager@example.com}
{name} {group} {one@example.com, two@example.com} {pager1@example.com, pager2@example.com}
```

* NAME is unused, exists for your config doco purposes
* GROUP is a label for a team or SME for who should receive a particular type of event
* EMAIL and PAGE/mobile both expect valid email addresses.
** multiple email address can be added if csv defined (ie ", " separator)
** We aren't doing any sms integration so Lookup their carriers phonenumber@domain online

Both are optional. pages get a smaller formatted message, not the entire raw log like email
If someone only has one type of contact method then just leave it blank (ie "{}")


Example:
```
{user1} {admin} {user1@example.com} {1111111111@carrier.com}
{user2} {admin} {user2@example.com, user2other@exampleother.com} {}
{user3} {disk} {} {3333333333@carrier.com}
{user4} {admin} {user4@example.com} {4444444444@carrier.com}
{user4} {disk} {user4@example.com} {4444444444@carrier.com}
```

## alert.conf

copy into /etc/syslog-ng/

This file defines which events to alert on by dynamically generating the tcl switch conditions. First matched so order matters

syntax tcl list, some elements are lists themselves
```
{{pattern1} {pattern2}} {{exclude1} {exclude2}} {hash} {delay} {email} {page} {ignore} {custom tcl code}
```

PATTERN nocase glob matches against $log(all)
* all=is the complete reassembled log message
** Must escape with double quotes to match tcl switch;  unless it's the default (you must define that here too)
**  These are a list of lists to allow the same throttling and action to occur with minimizing config lines and minimizing duplicate switch bodies in memory.

``` 
  {{""}}
  {{"*mdadm*}}
  {{"*alert*"} {"*crit*"}}
  {{default}}
```

EXCLUDE pattern sub negates what matched at PATTERN
* Also nocase glob matches but this filters to a specific section of the log message
** Multiple conditions are treated as OR
** if you need AND then use all= and string together the template order with glob wildcards

```
  {}
  {{}}
  {{host="foo*"} {level="debug"}}
  {{all="*crit*cron**some event*"}}
  {{msg="*some other event all daemons*"}}
```
HASH controls how we throttle an alert
*  This is also the default subject for email and pages
*  Usually I include the host which allows similar events from other nodes to still alert
** This can be anything, as it does not pattern match against the real message, although they are linked so this needs to be unique for the log event and if too generic or matched too soon, it could suppress other events

```
  {"$log(host) label"}
  {"common message from all sources"}
```

DELAY throttles how long between getting another alert
* Defined as an integer in seconds

```
  {600}
  {3600}
  {86400}
```

EMAIL these groups
* multiple can be listed separated with a space
* can be omitted, then no action is taken
**  (ie maybe use with IGNORE or CUSTOM if no EMAIL action is desired)

```
  {}
  {admin disk}
  {oncall}
```

PAGE these groups
* same as EMAIL

IGNORE is a boolean true false
* This does not process the pattern for alerting

> Consider filtering heavy noise within syslog-ng itself

```
  {}
  {0}
  {1}
```

CUSTOM eval as tcl code
* This extends further flexibility of the program by tclsh code injection
*  customize the action behavior, positioned before email/page actions

>  A good reminder to limit modification to the config files and tcl script this will exec as the UID of syslog-ng

```
  {}
  {set subject "$log(host) event"}
  {exec /usr/local/bin/something-cool.sh}
```

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



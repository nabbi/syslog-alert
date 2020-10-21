#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"

## copyright 2020 nic@boet.cc
#
# I originally wrote this as I needed a solution for throttling sendmail events piped from syslog-ng
# which provided custom per host+message throttling yet was flexible to # selectively send specific 
# events to a different distribution list or after hours pager/mobile.
#
# Delightfully written in Tcl as an experiment with TclOO
# SQLite is used for an in memory database of tracking events
# 
# This has gone through various rewrites over the years. It started as a Perl script over a decade ago
# which flocked a file for event tracking, it was a crude database (if you could even call it that).
# Refreshed a few years ago in TclOO to leverage SQLite. For me, this was one of those scripts which
# silently ran in the background and forgotten about. So this say around in this state for another year or 
# three before picking it up again.
# This latest update expands filtering functionality, cleaner per group alerting, and leverages configuration
# files instead of hacking the script.



## Notes on testing and troubleshooting
#
# As a result of using only an in memory database, if this program crashes or syslog-ng restarts,
# you may see alerts which notify again within X threshold. syslog-ng expects said program not to exit and 
# continue to accept stdio -- you will see the pid change if this script happens to crash as syslog-ng will try
# to restart it 
# syslog.info syslog-ng[]: Child program exited, restarting; cmdline='/usr/local/sbin/syslog-alert.tcl', status='256'
#
# This usually indicates a syntax issues introduced into the code base. Since the switch condition is now generated 
# from the user configuration file, errors have been reduced from manually editing the code.
# There is still high probability of a bad confg to load or miss parse. Very minimal non-existent validations are performed.
# Read up on TCL Lists if this is foreign to you.
#
# That being said, what I have seen more likely is frequent restarts to syslog-ng itself triggering alerts to trigger  again.
#
#
# You should, and are encouraged, to run this program directly to validate the behaviors.
# Toggle debug and trace flags to log more info to stdout
# Paste or pipe in some test log messages to see what happens.
#
# {datetime stamp} {sandbox} {error} {info} {smartd[12334]:} {test message}
# {datetime stamp} {sandbox} {debug} {info} {smartd[555]:} {test message}
# {datetime stamp} {sandbox} {debug} {info} {test[3333]:} {test message garbage}
#
# Or to test this with syslog-ng generage events with logger (or trigger the real condition on the source)


## alert-contacts.conf
#
# copy into /etc/syslog-ng/
# This file defines who, based on a group name, should receive an alert
# 
# syntax tcl list
# {name} {group} {email@example.com} {pager@example.com}
# {name} {group} {one@example.com, two@example.com} {pager1@example.com, pager2@example.com}
#
# NAME is unused, config doco
# GROUP is a label for a team or sme for who should receive a particular type of event
# EMAIL and PAGE/mobile both expect valid email addresses.
# multiple email address can be added if csv defined (ie ", " separator)
# We aren't doing any sms integration so Lookup their carriers phonenumber@domain online
#
# Both are optional. pages get a smaller formatted message, not the entire raw log like email
# If someone only has one type of contact method then just leave it blank (ie "{}")
#
# {user1} {admin} {user1@example.com} {1111111111@carrier.com}
# {user2} {admin} {user2@example.com, user2other@exampleother.com} {}
# {user3} {disk} {} {3333333333@carrier.com}
# {user4} {admin} {user4@example.com} {4444444444@carrier.com}
# {user4} {disk} {user4@example.com} {4444444444@carrier.com}


## alert.conf
#
# copy into /etc/syslog-ng/
# This file defines what events to alert on by dynamically generating the tcl switch conditions
# First matched so order matters
#
# syntax tcl list, some elements are lists themselves
# {{pattern1} {pattern2}} {{exclude1} {exclude2}} {hash} {delay} {email} {page} {ignore} {custom tcl code}
#
# PATTERN nocase glob matches against $log(all)
#   all=is the complete reassembled log message
#   Must escape with double quotes to match tcl switch;  unless it's the default (you define that here too)
#   These are a list of lists to allow the same throttling and action to occur with minimizing config lines
#   and minimizing duplicate switch bodies in memory.
#  
#   {{""}}
#   {{"*mdadm*}}
#   {{"*alert*"} {"*crit*"}}
#   {{default}}
#
#
# EXCLUDE patten sub negates what matched at PATTERN
#   Also nocase glob matches but this filters to which section of the log message
#   Multiple conditions are treated as OR
#   if you need AND then use all= and string together the template order with glob wildcards
#
#   {}
#   {{}}
#   {{host="foo*"} {level="debug"}}
#   {{all="*crit*cron**some event*"}}
#   {{msg="*some other event all daemons*"}}
#
# HASH controls how we throttle an alert
#   This is also the default subject for email and pages
#   Usually I include the host which allows similar events from other nodes to still alert
#   This can be anything, as it does not patterned matching the real message,
#   although they are linked so this needs to be unique for the log event and if too generic
#   or matched too soon, it could suppress other events
#
#   {"$log(host) label"}
#   {"common message from all sources"}
#
# DELAY throttles how long between getting another alert
#   Defined as an integer in seconds
#
#   {600}
#   {3600}
#   {86400}
#
# EMAIL these groups
#   multiple can be listed separated with a space
#   can be omitted, then no action is taken
#   (ie maybe use with IGNORE or CUSTOM)
#
#   {}
#   {admin disk}
#   {oncall}
#
# PAGE these groups
#   same as EMAIL
#
# IGNORE is a boolean true false
#   This does not process the pattern for alerting
#   Consider filter noise in syslog-ng but if you cannot
#
#   {}
#   {0}
#   {1}
#
# CUSTOM eval as tcl code
#   This extends further flexibility of the program by tclsh injection
#   customize the action behavior, positioned before email/page actions
#
#   A good reminder to limit modification to the config files and tcl script
#   this will run as the UID of syslog-ng
#
#   {}
#   {set subject "$log(host) event"}
#   {exec /usr/local/bin/something-cool.sh}
 

## tcl 8.6(.10)
#
# Originally there was dependency on tcllib (1.20) to provide csv (0.8.1)
# While I included logic to import csv without this, I decided to rewrite the config
# using lists instead as I found the statements easier to read.
# Simpler. Possibly more portable as some distros ship with dated packages

## sqlite 3(.33.0)
# 
# compiled with --enable-tcl
# 
# Was not written with TDBC - one could easily patch this if that is more desirable
# as the database calls are not complex
# 


## sendmail
# 
# expects to find a "sendmail" compatible in the system path
# I am using sSMTP (2.64) 


## syslog-ng 3 (3.28.1)
#
# This program depends on adjusting your /etc/syslog-ng/syslog-ng.conf
# Below describes how to integrate this into your config as an external program call
#
#
#
## Template
# In order to parse log events into variables, a predictable and parsable structure
# needs to be established. We escape each section with {} to create a tcl list.
#
# template t_alert {
#    template( "{${ISODATE}} {${HOST}} {${FACILITY}} {${LEVEL}} {${MSGHDR}} {${MSG}}\n" );
#    template_escape(no);
# };#
#
#
## Destination
# define where you placed this script so syslog-ng can pipe events to it
# Note that this is where you link the template formatting
#
# destination d_alert { program("/usr/local/sbin/syslog-alert.tcl" template(t_alert) mark-freq(0) ); };
#
#
## Filters
# So. This script was written with the mindset of pre-filtering events within syslog-ng
# This results in some duplication of config mgmt; in syslog-ng.conf and within this script
# 
# Think of syslog-ng as the course comb and this script as the fine side of the comb.
# While it may be possible to handle forward all events, I haven't extensively load tested.
#
# filter f_level3 { level (err..emerg); };
#
#
## Log
# This links your filters and destination together
#
# log { source(s_net); source(s_local); filter(f_level3); destination(d_alert);  };
#


oo::class create Alert {

    variable debug
    variable trace
    
    constructor {} {
        variable Db
        set debug 0
        set trace 1

        # initialize database
        package require sqlite3
        sqlite3 Db :memory:
        
        # create table for tracking which alerts
        # note that hash is not cryptographic, it's a composure of custom strings and values from log messages
        Db eval {CREATE TABLE alert(time int, hash text)}

        # create and populate table for looking up email and pager addresses for group contacts
        Db eval {CREATE TABLE contacts(name text, "group" text, email text, page text)}
        my Contacts_import

    }

    destructor {
        Db close
    }

    method recent {delta hash} {
        ##variable trace

        set now [clock seconds]

        ## check if this is new hash to throttle
        if { [Db exists {SELECT 1 FROM alert WHERE hash=:hash ORDER BY time DESC}] } {

            set time [Db eval {SELECT time FROM alert WHERE hash=:hash ORDER BY time DESC}]

            if { [expr {$now-$time}]  > $delta } {
                ##if ($trace) { "## alert - previous event aged out" }
                Db eval {UPDATE alert SET time=:now WHERE hash=:hash}
                return 200
            } else {
                ##if ($trace) { puts "## suppressed - last alert occurred within $delta" }
                return 0
            }
        } else {
            ##if ($trace) { puts "## alert - first time event" }
            Db eval {INSERT INTO alert VALUES(:now,:hash)}
            return 100

        }
    }

    method purge {} {
        ##variable trace

        # the sql table can grow in memory if we do not purge old events
        # ideally this should be greater than your largest throttle delta

        # 3 days
        set historic [expr {259200 - [clock seconds]}]

        Db eval {DELETE FROM alert WHERE time<=:historic}
        ##if {$trace} { puts "#trace# purged records [clock seconds] $historic" }

    }

    method Contacts_import {} {
        ##variable trace

        # load our contacts config into the database
        #{name} {group} {email} {page}
        set conf [open /etc/syslog-ng/alert-contacts.conf {r}]
        set lines [split [read $conf] "\n"]
        close $conf

        foreach l $lines {

            if { [string index $l 0] == "#" || [string index $l 0] == " " || [string length $l] == 0 } {
                continue
            }

            lassign $l name group email page

            ##if {$trace} { puts "#trace contacts_import# name: $name group: $group email: $email page: $page" }
            Db eval {INSERT INTO contacts VALUES(:name,:group,:email,:page)}

        }

    }

    method contacts_group {group a} {
        #group
        #address, email or page
        
        foreach g $group {
            # SELECT :a or $a resulted in a literal return of that var value
            switch -glob -- $a {
                "email" { append results { } [Db eval {SELECT "email" FROM contacts WHERE "group"=:g ORDER BY name DESC}] }

                "page" { append results { } [Db eval {SELECT "page" FROM contacts WHERE "group"=:g ORDER BY name DESC}] }

                default { return }
            }
        }

        #format results for csv sendmail recipient
        return [join [lsearch -all -inline -not -exact $results {}] ", "]
    }
    
    method generate_switch {} {
        variable trace

        # load our contact list into the database
        # name, group, email, page
        set conf [open /etc/syslog-ng/alert.conf {r}]
        set lines [split [read $conf] "\n"]
        close $conf

        foreach l $lines {

            if { [string index $l 0] == "#" || [string index $l 0] == " " || [string length $l] == 0 } {
                continue
            }
            
            #TODO validate inputs
            if { [llength $l] != 8 } {
                puts "#ignore bad config line: $l"
                continue
            }
            
            #{pattern} {exclude} {hash} {delay} {email} {page} {ignore} {custom}
            lassign $l pattern exclude hash delay email page ignore custom

            ##if {$trace} { puts "#trace events_import# p:$pattern e:$exclude h:$hash d:$delay e:$email p:$page i:$ignore c:$custom" }
            
            ## switch condition
            # Generates the inner switch body from the provided configurations
            
            #match patterns
            set i 0
            foreach p $pattern {

                incr i
                #check if this is the last pattern in the list
                if { [llength $pattern] == $i } {

                    #global ignore pattens
                    if { $ignore == 1 } {
                        append sw "$p \{ continue \}\n"

                    } else {
                        append sw "$p \{ \n"

                        #sub exclude patterns
                        foreach e $exclude {
                            # split the key=value (ie host="test*"
                            lassign [split $e "="] ek ev
                            append sw "\tif \{ \[string match -nocase $ev \$log($ek)\] \} \{ continue \}\n"
                        }

                        #check if we throttle or alert
                        append sw "\tif \{ \[\$syslog recent $delay $hash\] \} \{\n"

                        # this section was added to tweak the subject lines form custom config scripts
                        # overrides the default of using the hash
                        append sw "\t\tset subject $hash\n"
                        if { [string length $custom] > 0 } {
                            append sw "$custom\n"
                        }

                        #email groups
                        if { [string length $email] > 0 } {
                            append sw "\t\t\$syslog email \"$email\" \"\$subject\" \$log(all)\n"
                        }

                        #page groups
                        if { [string length $page] > 0 } {
                            append sw "\t\t\$syslog page \"$page\" \"\$subject\" \$log(msg)\n"
                        }

                        # close this switch condition
                        append sw "\t\}\n\}\n"
                    }

                } else {
                    append sw "$p -\n"
                }
            }

        }
        ## end foreach line

        if { ! [info exists sw] } {
            puts "fatal: no switch conditions compiled."
            exit 1
        }
        if {$trace} { puts "##trace compiled switch conditions##\n$sw##trace end##" }
        return $sw
    }

    method page {g s b} {
        #group contact to page
        #subject
        #body

        set to [my contacts_group $g "page"]

        #silently fail as we do not want to exit. check configs for valid entire
        if { [string length $to] > 0 } {
            my sendmail "$to" $s $b
        }
    }

    method email {g s b} {
        #group contact to email
        #subject
        #body

        set to [my contacts_group $g "email"]

        #silently fail as we do not want to exit. check configs for valid entire
        if { [string length $to] > 0 } {
            my sendmail $to "Subject: $s" $b
        }
    }

    method sendmail {to subject body} {
        variable debug

        set msg "From: syslog@[info hostname]"
        append msg \n "To: $to" \n
        append msg $subject \n\n
        append msg $body \n

        if {$debug} { puts "## msg: $msg" }
        #background to not wait as this blocks further message processing
        exec sendmail -oi -t << $msg &
    }


}

global syslog
set syslog [Alert new]
###

# we take a performance hit by dynamically creating this config block
# save .2u by pre-compiling this as a proc instead of eval within while loop
# global syslog;OO and log;stdin to accomidate this change
#
# eval switch 6.8385 microseconds per iteration
# proc switch 6.6365 microseconds per iteration
# real switch 6.456 microseconds per iteration
#
# TODO implement as a method
#
append newproc "proc sw \{\} \{\n"
append newproc "global log\n"
append newproc "global syslog\n"
append newproc "switch -glob -nocase -- \$log(all) \{\n[$syslog generate_switch] \n\}\n"
append newproc "\}\n"
eval $newproc
unset newproc

# read from standard input
while { [gets stdin line] >= 0 } {
    
    # skip line if we did not get expected list length
    # userful while debugging, avoids null pointer issues as a result
    if { [llength $line] != 6 } { continue }

    global log
    # "{${ISODATE}} {${HOST}} {${FACILITY}} {${LEVEL}} {${MSGHDR}} {${MSG}}"
    lassign $line log(isodate) log(host) log(facility) log(level) log(msghdr) log(msg)
    set log(all) "$log(isodate) $log(host) $log(facility).$log(level) $log(msghdr)$log(msg)"
    set log(program) [lindex [split $log(msghdr) "\["] 0]

    #run our switch proc instead of an eval here for performance gain
    sw

    # periodically clean out the database of old alerts to free memory
    # TODO suspect there is a better approach
    incr counter
    if {$counter > 100} {
        set counter 0
        $syslog purge
    }

}
###

$syslog destroy
exit 0


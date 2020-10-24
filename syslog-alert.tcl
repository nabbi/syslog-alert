#!/bin/sh
# the next line restarts using tclsh \
exec tclsh "$0" "$@"

## Copyright (C) 2020 nic@boet.cc


oo::class create Alert {

    variable debug
    variable trace
    
    constructor {} {
        variable Db
        set debug 0
        set trace 0

        # initialize database
        package require sqlite3
        sqlite3 Db :memory:
        
        # create table for tracking which alerts
        # note that hash is not cryptographic, it's a composure of custom strings and values from log messages
        Db eval {CREATE TABLE alert(time int, hash text)}

        # create and populate table for looking up email and pager addresses for group contacts
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
        # the sql table can grow in memory if we do not purge old events
        
        ##variable trace

        # ideally this should be greater than your largest throttle delta
        # 3 days
        set historic [expr {259200 - [clock seconds]}]

        Db eval {DELETE FROM alert WHERE time<=:historic}
        ##if {$trace} { puts "#trace# purged records [clock seconds] $historic" }

    }

    method Contacts_import {} {
        # read contacts list and into the database table
        ##variable trace

        #{name} {group} {email} {page}
        set conf [open /etc/syslog-ng/alert-contacts.conf {r}]
        set lines [split [read $conf] "\n"]
        close $conf
 
        Db eval {CREATE TABLE contacts(name text, "group" text, email text, page text)}

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
        # read configuration file to generate switch condition body.
 
        variable trace

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
            
            #{{pattern1} {pattern2}} {{exclude1} {exclude2}} {hash} {delay} {email} {page} {ignore} {custom tcl code}
            lassign $l pattern exclude hash delay email page ignore custom

            ##if {$trace} { puts "#trace events_import# p:$pattern e:$exclude h:$hash d:$delay e:$email p:$page i:$ignore c:$custom" }
            
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
                    #shares same body
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
# save .2us by pre-compiling this as a proc instead of eval within while loop
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
    # TODO This isn't perfect as some vendors don't encode messages consitently
    # consider using syslog-ng PROGRAM var and adjust the input templates.
    # consider replacing trailing ": " for when pid was not include in MSGHDR
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


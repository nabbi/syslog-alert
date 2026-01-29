#!/bin/sh
# the next line restarts using tclsh \
exec /usr/bin/env tclsh "$0" "$@"

## Copyright (C) 2020 nic@boet.cc
# https://github.com/nabbi/syslog-alert

# Harden PATH to trusted directories only
set ::env(PATH) "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Maximum allowed length for a single syslog input line (bytes)
set ::MAX_LINE_LENGTH 8192


oo::class create SQLite {
    constructor {} {
        package require sqlite3
        sqlite3 Db :memory:
        next
    }

    destructor {
        Db close
    }
}

oo::class create Contacts {

    constructor {} {
        variable debug
        variable trace
        set debug 0
        set trace 0

        # create and populate table for looking up email and pager addresses for group contacts
        my ImportContacts
        if {$debug} { puts "## Database ## contacts imported" }
        next
    }

    method ImportContacts {} {
        # read contacts list and into the database table
        ##variable trace

        #{name} {group} {email} {page}
        set conf [open /etc/syslog-ng/alert-contacts.conf {r}]
        set lines [split [read $conf] "\n"]
        close $conf

        Db eval {CREATE TABLE contacts(name text, "group" text, email text, page text)}

        foreach l $lines {

            if { [string index $l 0] == "#" || [string length $l] == 0 } {
                continue
            }

            lassign $l name group email page

            ##if {$trace} { puts "#trace contacts_import# name: $name group: $group email: $email page: $page" }
            Db eval {INSERT INTO contacts VALUES(:name,:group,:email,:page)}

        }

    }

    method Group {groups a} {
        #groups to lookup
        #address, email or mobile-pager
        
        foreach g $groups {
            # TODO SELECT :a or $a resulted in a literal return of that var value
            switch -glob -- $a {
                "email" { append results { } [Db eval {SELECT "email" FROM contacts WHERE "group"=:g}] }

                "page" { append results { } [Db eval {SELECT "page" FROM contacts WHERE "group"=:g}] }

                default { return }
            }
        }

        #format results for csv sendmail recipient
        return [join [lsearch -all -inline -not -exact $results {}] ", "]
    }

    method page {g s b} {
        #group contact to page
        #subject
        #body

        set to [my Group $g "page"]

        #silently fail as we do not want to exit. check configs for valid entry
        if { [string length $to] > 0 } {
            my Sendmail "$to" $s $b
        }
    }

    method email {g s b} {
        #groups to email
        #subject
        #body

        set to [my Group $g "email"]

        #silently fail as we do not want to exit. check configs for valid entry
        if { [string length $to] > 0 } {
            my Sendmail $to "Subject: $s" $b
        }
    }

    method Sendmail {to subject body} {
        variable debug

        # Strip newlines/carriage returns from header fields to prevent header injection
        set to [string map {\n {} \r {}} $to]
        set subject [string map {\n {} \r {}} $subject]

        set msg "From: syslog@[info hostname]"
        append msg \n "To: $to" \n
        append msg $subject \n\n
        append msg $body \n

        if {$debug} { puts "## msg: $msg" }
        #background to not wait as this blocks further message processing
        exec -- sendmail -oi -t << $msg &
    }

}


oo::class create Alert {
    mixin SQLite Contacts

    constructor {} {
        variable debug
        variable trace

        # create table for tracking which alerts
        Db eval {CREATE TABLE alert(time int, hash text primary key)}
        if {$debug} { puts "## Database ## alert table created" }

        my CreatePatterns
        if {$debug} { puts "## Config imported" }
    }

    method Recent {delta hash} {
        ##variable trace

        set now [clock seconds]
        set time [Db eval {SELECT time FROM alert WHERE hash=:hash}]

        ## check if this is new hash to throttle
        if { [string length $time] <= 0} {
            ##if ($trace) { puts "## alert - first time event" }
            Db eval {INSERT INTO alert VALUES(:now,:hash)}
            return 100
        } elseif { [expr {$now-$time}]  > $delta } {
            ##if ($trace) { "## alert - previous event aged out" }
            Db eval {UPDATE alert SET time=:now WHERE hash=:hash}
            return 200
        } else {
            ##if ($trace) { puts "## suppressed - last alert occurred within $delta" }
            return 0
        }

    }

    method purge {} {
        # the sql table can grow in memory if we do not purge old events
        ##variable trace

        # ideally this should be greater than your largest throttle delta
        # 3 days
        set historic [expr {[clock seconds] - 259200}]

        Db eval {DELETE FROM alert WHERE time<=:historic}
        ##if {$trace} { puts "#trace# purged records [clock seconds] $historic" }

    }

    method CreatePatterns {} {
        #assemble the patterns method from user configuration file
        variable trace

        append method "oo::define Alert method patterns \{line\} \{\n\n"

        # "{${ISODATE}} {${HOST}} {${FACILITY}} {${LEVEL}} {${MSGHDR}} {${MSG}}"
        append method "lassign \$line log(isodate) log(host) log(facility) log(level) log(msghdr) log(msg)\n"
        append method "set log(all) \"\$log(isodate) \$log(host) \$log(facility).\$log(level) \$log(msghdr)\$log(msg)\"\n"

        # TODO This isn't perfect as some vendors don't encode messages consitently
        # consider using syslog-ng PROGRAM var and adjust the input templates.
        # consider replacing trailing ": " for when pid was not include in MSGHDR
        set split "\\\["
        append method "set log(program) \[lindex \[split \$log(msghdr) \"$split\"\] 0\]\n"

        append method "\nswitch -glob -nocase -- \$log(all) \{\n[my ImportAlert] \}\n"
        append method "\}\n"

        eval $method

        if {$trace} { puts "## method patterns\n[info class definition Alert patterns]" }
    }

    method ImportAlert {} {
        # read configuration file to generate switch condition body.
        ##variable trace

        set conf [open /etc/syslog-ng/alert.conf {r}]
        set lines [split [read $conf] "\n"]
        close $conf

        foreach l $lines {

            if { [string index $l 0] == "#" || [string length $l] == 0 } {
                continue
            }
            
            #validate inputs
            if { [llength $l] != 8 } {
                puts "#ignore bad config line: $l"
                continue
            }

            #{{pattern1} {pattern2}} {{exclude1} {exclude2}} {hash} {delay} {email} {page} {ignore} {custom tcl code}
            lassign $l pattern exclude hash delay email page ignore custom

            # validate delay is a non-negative integer
            if { ![string is integer -strict $delay] || $delay < 0 } {
                puts "#ignore bad delay value in config line: $l"
                continue
            }

            # validate ignore is 0, 1, or empty
            if { $ignore ne {} && $ignore != 0 && $ignore != 1 } {
                puts "#ignore bad ignore flag in config line: $l"
                continue
            }

            ##if {$trace} { puts "#trace events_import# p:$pattern e:$exclude h:$hash d:$delay e:$email p:$page i:$ignore c:$custom" }
            
            # Generates the inner switch body from the provided configurations
            #match patterns
            set i 1
            foreach p $pattern {

                #check if this is the last pattern in the list
                #shares same body
                if { [llength $pattern] > $i } {
                    incr i
                    append sw "$p -\n"
                    continue
                }

                #global ignore pattens
                if { $ignore == 1 } {
                    append sw "$p \{ return \}\n"
                    continue

                } else {
                    append sw "$p \{ \n"

                    #sub exclude patterns
                    foreach e $exclude {
                        # split the key=value (ie host="test*")
                        lassign [split $e "="] ek ev
                        append sw "\tif \{ \[string match -nocase $ev \$log($ek)\] \} \{ return \}\n"
                    }

                    #check if we throttle or alert
                    append sw "\tif \{ \[my Recent $delay $hash\] \} \{\n"

                    # this section was added to tweak the subject lines form custom config scripts
                    # overrides the default of using the hash
                    append sw "\t\tset subject $hash\n"
                    if { [string length $custom] > 0 } {
                        append sw "$custom\n"
                    }

                    #email groups
                    if { [string length $email] > 0 } {
                        append sw "\t\tmy email \"$email\" \"\$subject\" \$log(all)\n"
                    }

                    #page groups
                    if { [string length $page] > 0 } {
                        append sw "\t\t\my page \"$page\" \"\$subject\" \$log(msg)\n"
                    }

                    # close this switch condition
                    append sw "\t\}\n\}\n"
                    continue
                }

            }

        }
        ## end foreach line

        if { ! [info exists sw] } {
            puts "fatal: no switch conditions compiled."
            exit 1
        }
        ##if {$trace} { puts "## Imported alerts.conf\n$sw" }
        return $sw
    }

}




set syslog [Alert new]
###

# read from standard input
set counter 0
while { [gets stdin line] >= 0 } {

    # reject excessively long lines to prevent resource exhaustion
    if { [string length $line] > $::MAX_LINE_LENGTH } { continue }

    # skip line if we did not get expected list length
    # useful while debugging, avoids null pointer issues as a result
    if { [llength $line] != 6 } { continue }

    #call our dynamically created method
    if { [catch {$syslog patterns $line} err] } {
        puts "#error processing line: $err"
    }

    # periodically clean out the database of old alerts to free memory
    incr counter
    if {$counter > 100} {
        set counter 0
        $syslog purge
    }

}
###

$syslog destroy
exit 0


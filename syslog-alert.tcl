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
	constructor {args} {
		package require sqlite3
		sqlite3 Db :memory:
		next {*}$args
	}

	destructor {
		Db close
	}
}

oo::class create Contacts {

	constructor {args} {
		variable debug
		variable trace
		set debug 0
		set trace 0

		Db eval {CREATE TABLE contacts(name text, "group" text, email text, page text)}
		next {*}$args
	}

	method PopulateContacts {contactsDict} {
		# Insert contact rows into SQLite from a normalized contacts dict
		# Each contact with multiple groups gets one row per group
		dict for {name info} $contactsDict {
			set groups [dict get $info groups]
			set email ""
			set page ""
			if {[dict exists $info email]} { set email [dict get $info email] }
			if {[dict exists $info page]}  { set page [dict get $info page] }
			foreach g $groups {
				Db eval {INSERT INTO contacts VALUES(:name,:g,:email,:page)}
			}
		}
	}

	method ImportContacts {} {
		# Legacy
		set path "/etc/syslog-ng/alert-contacts.conf"
		set conf [open $path {r}]
		set lines [split [read $conf] "\n"]
		close $conf

		foreach l $lines {
			if { [string index $l 0] == "#" || [string length $l] == 0 } {
				continue
			}
			lassign $l name group email page
			Db eval {INSERT INTO contacts VALUES(:name,:group,:email,:page)}
		}
	}

	method Group {groups a} {
		set results [list]
		foreach g $groups {
			switch -glob -- $a {
				"email" { lappend results {*}[Db eval {SELECT "email" FROM contacts WHERE "group"=:g}] }
				"page"  { lappend results {*}[Db eval {SELECT "page" FROM contacts WHERE "group"=:g}] }
				default { return }
			}
		}
		return [join [lsearch -all -inline -not -exact $results {}] ", "]
	}

	method page {g s b} {
		set to [my Group $g "page"]
		if { [string length $to] > 0 } {
			my Sendmail "$to" $s $b
		}
	}

	method email {g s b} {
		set to [my Group $g "email"]
		if { [string length $to] > 0 } {
			my Sendmail $to "Subject: $s" $b
		}
	}

	method Sendmail {to subject body} {
		variable debug
		variable fromAddr

		set to [string map {\n {} \r {}} $to]
		set subject [string map {\n {} \r {}} $subject]

		if {[info exists fromAddr] && $fromAddr ne ""} {
			set msg "From: $fromAddr"
		} else {
			set msg "From: syslog@[info hostname]"
		}
		append msg \n "To: $to" \n
		append msg $subject \n\n
		append msg $body \n

		if {$debug} { puts "## msg: $msg" }

		if {[info exists ::env(SYSLOG_ALERT_TESTMODE)] && $::env(SYSLOG_ALERT_TESTMODE)} {
			# Test mode: append to capture file instead of sending email
			set actionsFile [expr {[info exists ::env(SYSLOG_ALERT_ACTIONS_FILE)]
				? $::env(SYSLOG_ALERT_ACTIONS_FILE) : "/dev/stderr"}]
			set fd [open $actionsFile a]
			puts $fd "ACTION: to=<$to> subject=<$subject>"
			puts $fd "BODY: $body"
			puts $fd "---"
			close $fd
			return
		}

		exec -- sendmail -oi -t << $msg &
	}

}


oo::class create Alert {
	mixin SQLite Contacts
	constructor {args} {
		variable debug
		variable trace
		variable fromAddr
		variable configFile
		variable normalizedRules

		# Parse constructor args (passed from CLI as key-value pairs)
		set configFile ""
		set fromAddr ""
		if {[dict exists $args configFile]} {
			set configFile [dict get $args configFile]
		}

		# create table for tracking which alerts
		Db eval {CREATE TABLE alert(time int, hash text primary key)}

		# Load config: try new format first, then legacy
		my LoadAndApplyConfig

		if {$debug} { puts "## Config imported" }
	}

	method LoadAndApplyConfig {} {
		variable configFile
		variable debug
		variable trace
		variable fromAddr
		variable normalizedRules

		if {$configFile ne ""} {
			# Explicit --config path: must be new format
			set normalizedRules [my LoadConfig $configFile]
		} elseif {[file exists "/etc/syslog-ng/syslog-alert.conf"]} {
			set normalizedRules [my LoadConfig "/etc/syslog-ng/syslog-alert.conf"]
		} else {
			# Legacy fallback
			puts "notice: using legacy config files (alert.conf + alert-contacts.conf). Consider migrating to syslog-alert.conf"
			set normalizedRules [my LoadLegacyConfig]
		}

		my CreatePatterns $normalizedRules
	}

	method LoadConfig {path} {
		# Load new unified syslog-alert.conf format
		variable debug
		variable trace
		variable fromAddr

		set fd [open $path r]
		set raw [read $fd]
		close $fd

		# Strip comment lines (# at start of line) before parsing as dict
		set cleaned ""
		foreach line [split $raw "\n"] {
			set trimmed [string trimleft $line]
			if {[string index $trimmed 0] eq "#"} { continue }
			append cleaned $line \n
		}

		set config $cleaned
		if {[catch {dict size $config} err]} {
			puts "fatal: failed to parse config file $path: $err"
			exit 1
		}

		# Validate top-level sections
		if {![dict exists $config contacts]} {
			puts "fatal: config missing 'contacts' section"
			exit 1
		}
		if {![dict exists $config rules]} {
			puts "fatal: config missing 'rules' section"
			exit 1
		}

		# Process global section
		if {[dict exists $config global]} {
			set g [dict get $config global]
			if {[dict exists $g debug]} { set debug [dict get $g debug] }
			if {[dict exists $g trace]} { set trace [dict get $g trace] }
			if {[dict exists $g from]}  { set fromAddr [dict get $g from] }
		}

		# Process contacts
		set contactsDict [dict get $config contacts]
		dict for {name info} $contactsDict {
			if {![dict exists $info groups]} {
				puts "fatal: contact '$name' missing 'groups'"
				exit 1
			}
			if {![dict exists $info email] && ![dict exists $info page]} {
				puts "fatal: contact '$name' must have at least one of 'email' or 'page'"
				exit 1
			}
		}
		my PopulateContacts $contactsDict

		if {$debug} { puts "## Database ## contacts imported" }

		# Process rules into normalized list
		set rulesDict [dict get $config rules]
		set normalized [list]

		dict for {ruleName ruleBody} $rulesDict {
			set rule [dict create name $ruleName]

			if {![dict exists $ruleBody pattern]} {
				puts "fatal: rule '$ruleName' missing 'pattern'"
				exit 1
			}
			dict set rule pattern [dict get $ruleBody pattern]

			# Optional fields with defaults
			dict set rule exclude [expr {[dict exists $ruleBody exclude] ? [dict get $ruleBody exclude] : ""}]
			dict set rule subject [expr {[dict exists $ruleBody subject] ? [dict get $ruleBody subject] : ""}]

			set delay [expr {[dict exists $ruleBody delay] ? [dict get $ruleBody delay] : 0}]
			if {![string is integer -strict $delay] || $delay < 0} {
				puts "fatal: rule '$ruleName' has invalid delay '$delay'"
				exit 1
			}
			dict set rule delay $delay

			dict set rule email [expr {[dict exists $ruleBody email] ? [dict get $ruleBody email] : ""}]
			dict set rule page [expr {[dict exists $ruleBody page] ? [dict get $ruleBody page] : ""}]

			set ignore [expr {[dict exists $ruleBody ignore] ? [dict get $ruleBody ignore] : 0}]
			if {$ignore ne "" && $ignore != 0 && $ignore != 1} {
				puts "fatal: rule '$ruleName' has invalid ignore flag '$ignore'"
				exit 1
			}
			dict set rule ignore $ignore

			dict set rule custom [expr {[dict exists $ruleBody custom] ? [dict get $ruleBody custom] : ""}]

			lappend normalized $rule
		}

		return $normalized
	}

	method LoadLegacyConfig {} {
		# Load legacy two-file format, return normalized rules list
		variable debug
		variable trace

		# Load contacts via legacy method
		my ImportContacts
		if {$debug} { puts "## Database ## contacts imported" }

		# Load alert rules
		set conf [open /etc/syslog-ng/alert.conf {r}]
		set lines [split [read $conf] "\n"]
		close $conf

		set normalized [list]

		foreach l $lines {
			if { [string index $l 0] == "#" || [string length $l] == 0 } {
				continue
			}
			if { [llength $l] != 8 } {
				puts "#ignore bad config line: $l"
				continue
			}

			lassign $l pattern exclude hash delay email page ignore custom

			if { ![string is integer -strict $delay] || $delay < 0 } {
				puts "#ignore bad delay value in config line: $l"
				continue
			}
			if { $ignore ne {} && $ignore != 0 && $ignore != 1 } {
				puts "#ignore bad ignore flag in config line: $l"
				continue
			}

			# Legacy hash/subject has embedded quotes, strip them
			set hash [string trim $hash "\""]

			set rule [dict create \
				name	 "" \
				pattern  $pattern \
				exclude  $exclude \
				subject  $hash \
				delay	$delay \
				email	$email \
				page	 $page \
				ignore   $ignore \
				custom   $custom \
			]
			lappend normalized $rule
		}

		if {[llength $normalized] == 0} {
			puts "fatal: no rules loaded from legacy config."
			exit 1
		}

		return $normalized
	}

	method Recent {delta hash} {
		set now [expr {[info exists ::env(SYSLOG_ALERT_CLOCK)] ? $::env(SYSLOG_ALERT_CLOCK) : [clock seconds]}]
		set time [Db eval {SELECT time FROM alert WHERE hash=:hash}]

		if { [string length $time] <= 0} {
			Db eval {INSERT INTO alert VALUES(:now,:hash)}
			return 100
		} elseif { [expr {$now-$time}]  > $delta } {
			Db eval {UPDATE alert SET time=:now WHERE hash=:hash}
			return 200
		} else {
			return 0
		}
	}

	method purge {} {
		set now [expr {[info exists ::env(SYSLOG_ALERT_CLOCK)] ? $::env(SYSLOG_ALERT_CLOCK) : [clock seconds]}]
		set historic [expr {$now - 259200}]
		Db eval {DELETE FROM alert WHERE time<=:historic}
	}

	method CreatePatterns {rules} {
		# Generate the patterns method from normalized rules list
		variable trace

		append method "oo::define Alert method patterns \{line\} \{\n\n"

		append method "lassign \$line log(isodate) log(host) log(facility) log(level) log(msghdr) log(msg)\n"
		append method "set log(all) \"\$log(isodate) \$log(host) \$log(facility).\$log(level) \$log(msghdr)\$log(msg)\"\n"

		set split "\\\["
		append method "set log(program) \[lindex \[split \$log(msghdr) \"$split\"\] 0\]\n"

		append method "\nswitch -glob -nocase -- \$log(all) \{\n"

		foreach rule $rules {
			set pattern [dict get $rule pattern]
			set exclude [dict get $rule exclude]
			set subject [dict get $rule subject]
			set delay   [dict get $rule delay]
			set email   [dict get $rule email]
			set page	[dict get $rule page]
			set ignore  [dict get $rule ignore]
			set custom  [dict get $rule custom]

			# Use subject as hash for throttling
			set hash $subject

			set i 1
			foreach p $pattern {
				# Quote pattern for switch body (handles empty strings)
				if {$p eq "default"} {
					set qp "default"
				} else {
					set qp "\"$p\""
				}

				if { [llength $pattern] > $i } {
					incr i
					append sw "$qp -\n"
					continue
				}

				if { $ignore == 1 } {
					append sw "$qp \{ return \}\n"
					continue
				} else {
					append sw "$qp \{ \n"

					foreach e $exclude {
						set eqIdx [string first "=" $e]
						set ek [string range $e 0 $eqIdx-1]
						set ev [string range $e $eqIdx+1 end]
						set ev [string trim $ev]
						if {[string length $ev] >= 2 &&
							[string index $ev 0] eq "\"" &&
							[string index $ev end] eq "\""} {
							set ev [string range $ev 1 end-1]
						}
						append sw "\tif \{ \[string match -nocase $ev \$log($ek)\] \} \{ return \}\n"
					}

					append sw "\tif \{ \[my Recent $delay \"$hash\"\] \} \{\n"

					append sw "\t\tset subject \"$hash\"\n"
					if { [string length $custom] > 0 } {
						append sw "\t\t$custom\n"
					}

					if { [string length $email] > 0 } {
						append sw "\t\tmy email \"$email\" \"\$subject\" \$log(all)\n"
					}

					if { [string length $page] > 0 } {
						append sw "\t\tmy page \"$page\" \"\$subject\" \$log(msg)\n"
					}

					append sw "\t\}\n\}\n"
					continue
				}
			}
		}

		if { ! [info exists sw] } {
			puts "fatal: no switch conditions compiled."
			exit 1
		}

		append method "$sw\}\n"
		append method "\}\n"

		eval $method

		if {$trace} { puts "## method patterns\n[info class definition Alert patterns]" }
	}

	method dumpconfig {} {
		variable normalizedRules

		puts "# Normalized configuration"
		puts ""
		set i 0
		foreach rule $normalizedRules {
			incr i
			set name [dict get $rule name]
			if {$name eq ""} { set name "rule-$i" }
			puts "rule: $name"
			puts "  pattern: [dict get $rule pattern]"
			set exclude [dict get $rule exclude]
			if {$exclude ne ""} { puts "  exclude: $exclude" }
			set subject [dict get $rule subject]
			if {$subject ne ""} { puts "  subject: $subject" }
			puts "  delay:   [dict get $rule delay]"
			set email [dict get $rule email]
			if {$email ne ""} { puts "  email:   $email" }
			set page [dict get $rule page]
			if {$page ne ""} { puts "  page:	$page" }
			set ignore [dict get $rule ignore]
			if {$ignore == 1} { puts "  ignore:  1" }
			set custom [dict get $rule custom]
			if {$custom ne ""} { puts "  custom:  $custom" }
			puts ""
		}
	}

	method explain {inputLine} {
		# Dry-run a syslog line through patterns, showing what would match
		variable normalizedRules

		if {[llength $inputLine] != 6} {
			puts "error: input must be a 6-element Tcl list"
			puts "format: {ISODATE} {HOST} {FACILITY} {LEVEL} {MSGHDR} {MSG}"
			return
		}

		lassign $inputLine isodate host facility level msghdr msg
		set all "$isodate $host $facility.$level $msghdr$msg"
		set split "\["
		set program [lindex [split $msghdr $split] 0]

		puts "Input:"
		puts "  isodate: $isodate"
		puts "  host:	$host"
		puts "  facility: $facility"
		puts "  level:   $level"
		puts "  msghdr:  $msghdr"
		puts "  msg:	 $msg"
		puts "  all:	 $all"
		puts "  program: $program"
		puts ""

		set matched 0
		set ruleNum 0
		foreach rule $normalizedRules {
			incr ruleNum
			set name [dict get $rule name]
			if {$name eq ""} { set name "rule-$ruleNum" }
			set pattern [dict get $rule pattern]
			set exclude [dict get $rule exclude]
			set ignore  [dict get $rule ignore]

			foreach p $pattern {
				if {$p eq "default" || [string match -nocase $p $all]} {
					puts "MATCHED rule: $name"
					puts "  pattern:  $p"

					# Check excludes
					set excluded 0
					foreach e $exclude {
						set eqIdx [string first "=" $e]
						set ek [string range $e 0 $eqIdx-1]
						set ev [string range $e $eqIdx+1 end]
						set ev [string trim $ev]
						if {[string length $ev] >= 2 &&
							[string index $ev 0] eq "\"" &&
							[string index $ev end] eq "\""} {
							set ev [string range $ev 1 end-1]
						}
						set testVal ""
						switch -- $ek {
							all	   { set testVal $all }
							host	  { set testVal $host }
							facility  { set testVal $facility }
							level	 { set testVal $level }
							msghdr	{ set testVal $msghdr }
							msg	   { set testVal $msg }
							program   { set testVal $program }
							isodate   { set testVal $isodate }
						}
						if {[string match -nocase $ev $testVal]} {
							puts "  EXCLUDED by: $e"
							set excluded 1
						}
					}

					if {!$excluded} {
						if {$ignore == 1} {
							puts "  action: IGNORE (no alert)"
						} else {
							puts "  subject: [dict get $rule subject]"
							puts "  delay:   [dict get $rule delay]s"
							set email [dict get $rule email]
							if {$email ne ""} { puts "  email:   $email" }
							set page [dict get $rule page]
							if {$page ne ""} { puts "  page:	$page" }
							set custom [dict get $rule custom]
							if {$custom ne ""} { puts "  custom:  $custom" }
						}
					}

					set matched 1
					break
				}
			}
			if {$matched} { break }
		}

		if {!$matched} {
			puts "NO MATCH: no rule matched this input"
		}
	}
}


# --- CLI argument parsing ---
set configFile ""
set checkConfig 0
set dumpConfig 0
set explainLine ""

for {set i 0} {$i < $argc} {incr i} {
	set arg [lindex $argv $i]
	switch -- $arg {
		"--config" {
			incr i
			set configFile [lindex $argv $i]
		}
		"--check-config" {
			set checkConfig 1
		}
		"--dump-config" {
			set dumpConfig 1
		}
		"--explain" {
			incr i
			set explainLine [lindex $argv $i]
		}
	}
}

# Helper to create Alert with config args
proc CreateAlert {configFile} {
	if {$configFile ne ""} {
		return [Alert new configFile $configFile]
	} else {
		return [Alert new]
	}
}

# --check-config mode
if {$checkConfig} {
	if {[catch {set syslog [CreateAlert $configFile]} err]} {
		puts "CONFIG ERROR: $err"
		exit 1
	}
	puts "Configuration OK"
	$syslog destroy
	exit 0
}

# --dump-config mode
if {$dumpConfig} {
	if {[catch {set syslog [CreateAlert $configFile]} err]} {
		puts "CONFIG ERROR: $err"
		exit 1
	}
	$syslog dumpconfig
	$syslog destroy
	exit 0
}

# --explain mode
if {$explainLine ne ""} {
	if {[catch {set syslog [CreateAlert $configFile]} err]} {
		puts "CONFIG ERROR: $err"
		exit 1
	}
	$syslog explain $explainLine
	$syslog destroy
	exit 0
}

# Normal operation: read from stdin
set syslog [CreateAlert $configFile]

set counter 0
while { [gets stdin line] >= 0 } {

	if { [string length $line] > $::MAX_LINE_LENGTH } { continue }
	if { [llength $line] != 6 } { continue }

	if { [catch {$syslog patterns $line} err] } {
		puts "#error processing line: $err"
	}

	incr counter
	if {$counter > 100} {
		set counter 0
		$syslog purge
	}

}

$syslog destroy
exit 0

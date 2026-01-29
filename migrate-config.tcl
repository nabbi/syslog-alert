#!/bin/sh
# the next line restarts using tclsh \
exec /usr/bin/env tclsh "$0" "$@"

## migrate-config.tcl - Convert legacy alert.conf + alert-contacts.conf to syslog-alert.conf
#
# Usage:
#   tclsh migrate-config.tcl alert-contacts.conf alert.conf > syslog-alert.conf
#   tclsh migrate-config.tcl /etc/syslog-ng/alert-contacts.conf /etc/syslog-ng/alert.conf

proc usage {} {
    puts stderr "Usage: [file tail [info script]] <alert-contacts.conf> <alert.conf>"
    puts stderr ""
    puts stderr "Reads the legacy two-file configuration and writes the new"
    puts stderr "single-file syslog-alert.conf format to stdout."
    exit 1
}

if {$argc != 2} { usage }

set contactsPath [lindex $argv 0]
set rulesPath    [lindex $argv 1]

foreach p [list $contactsPath $rulesPath] {
    if {![file readable $p]} {
        puts stderr "error: cannot read $p"
        exit 1
    }
}

# --- Parse contacts ---
# Legacy format: {name} {group} {email} {page}
# A name may appear on multiple lines with different groups.
# Merge into: name -> {groups {g1 g2} email addr page addr}

set fd [open $contactsPath r]
set lines [split [read $fd] "\n"]
close $fd

# Keyed by contact name
array set contacts {}
# Preserve insertion order
set contactOrder [list]

foreach l $lines {
    if {[string index $l 0] eq "#" || [string length $l] == 0} { continue }
    lassign $l name group email page

    if {$name eq ""} { continue }

    if {![info exists contacts($name)]} {
        lappend contactOrder $name
        set contacts($name) [dict create groups [list] email "" page ""]
    }

    set c $contacts($name)

    # Accumulate groups
    set groups [dict get $c groups]
    if {$group ne "" && $group ni $groups} {
        lappend groups $group
    }
    dict set c groups $groups

    # Take the first non-empty email/page seen (they should be identical across rows)
    if {[dict get $c email] eq "" && $email ne ""} {
        dict set c email $email
    }
    if {[dict get $c page] eq "" && $page ne ""} {
        dict set c page $page
    }

    set contacts($name) $c
}

if {[llength $contactOrder] == 0} {
    puts stderr "warning: no contacts found in $contactsPath"
}

# --- Parse rules ---
# Legacy format: {{pat1} {pat2}} {{excl1}} {hash} {delay} {email} {page} {ignore} {custom}
# Comments (#) and blank lines are preserved as comment blocks above the next rule.

proc generate_rule_name {subject pattern counter} {
    # Try to derive a short name from the subject or pattern
    set src $subject
    if {$src eq ""} { set src [lindex $pattern 0] }
    if {$src eq "" || $src eq "default"} {
        return "rule-$counter"
    }

    # Strip variable references and glob chars
    set name [regsub -all {\$log\([^)]+\)} $src ""]
    set name [string map {* "" "\"" "" \{ "" \} ""} $name]
    set name [string trim $name]

    if {$name eq ""} {
        return "rule-$counter"
    }

    # Convert to kebab-case
    set name [string tolower $name]
    set name [regsub -all {[^a-z0-9]+} $name "-"]
    set name [string trim $name "-"]

    if {$name eq ""} {
        return "rule-$counter"
    }

    return $name
}

set fd [open $rulesPath r]
set raw [read $fd]
close $fd
set lines [split $raw "\n"]

set rules [list]
set pendingComments [list]
set ruleCounter 0

foreach l $lines {
    set trimmed [string trimleft $l]

    if {$trimmed eq "" || [string index $trimmed 0] eq "#"} {
        lappend pendingComments $l
        continue
    }

    if {[llength $l] != 8} {
        lappend pendingComments "# (skipped malformed line) $l"
        continue
    }

    lassign $l pattern exclude hash delay email page ignore custom

    # Legacy patterns have embedded quotes around glob values, strip them
    set cleanPattern [list]
    foreach p $pattern {
        lappend cleanPattern [string trim $p "\""]
    }
    set pattern $cleanPattern

    if {$delay eq ""} { set delay 0 }
    if {![string is integer -strict $delay] || $delay < 0} {
        lappend pendingComments "# (skipped bad delay) $l"
        continue
    }

    # Strip embedded quotes from legacy hash/subject
    set hash [string trim $hash "\""]

    incr ruleCounter

    # Auto-generate a rule name from the subject or pattern
    set ruleName [generate_rule_name $hash $pattern $ruleCounter]

    lappend rules [dict create \
        comments $pendingComments \
        name     $ruleName \
        pattern  $pattern \
        exclude  $exclude \
        subject  $hash \
        delay    $delay \
        email    $email \
        page     $page \
        ignore   $ignore \
        custom   $custom \
    ]
    set pendingComments [list]
}

# Any trailing comments
if {[llength $pendingComments] > 0} {
    lappend rules [dict create comments $pendingComments name "" pattern ""]
}

# --- Emit new format ---

# Helper: format a Tcl value for config output.
# If it contains spaces or special chars, brace it.
proc emit_val {v} {
    if {$v eq ""} { return {{}} }
    if {[string match {* *} $v] || [string match {*\**} $v] || [string match {*\$*} $v] ||
        [string match {*\"*} $v] || [string match {*\{*} $v] || [string match {*\}*} $v] ||
        [string match {*=*} $v]} {
        return "{$v}"
    }
    return $v
}

# Emit a list value: single element bare, multi-element as braced list
proc emit_list {lst} {
    if {[llength $lst] == 1} {
        return [lindex $lst 0]
    }
    return "{$lst}"
}

puts "# syslog-alert.conf"
puts "# Migrated from legacy format by migrate-config.tcl"
puts ""

puts "global {"
puts "    # from   syslog@myhost.example.com"
puts "    debug  0"
puts "    trace  0"
puts "}"
puts ""

# Contacts
puts "contacts {"
foreach name $contactOrder {
    set c $contacts($name)
    set groups [dict get $c groups]
    set email  [dict get $c email]
    set page   [dict get $c page]

    puts "    $name {"
    puts "        groups  [emit_list $groups]"
    if {$email ne ""} {
        puts "        email   [emit_val $email]"
    }
    if {$page ne ""} {
        puts "        page    [emit_val $page]"
    }
    puts "    }"
}
puts "}"
puts ""

# Rules
puts "rules {"
foreach rule $rules {
    # Trailing-comment-only entry
    if {[dict get $rule name] eq "" && [dict get $rule pattern] eq ""} {
        foreach c [dict get $rule comments] {
            puts "    $c"
        }
        continue
    }

    # Emit preserved comments
    foreach c [dict get $rule comments] {
        if {$c eq ""} {
            puts ""
        } else {
            puts "    $c"
        }
    }

    set name    [dict get $rule name]
    set pattern [dict get $rule pattern]
    set exclude [dict get $rule exclude]
    set subject [dict get $rule subject]
    set delay   [dict get $rule delay]
    set email   [dict get $rule email]
    set page    [dict get $rule page]
    set ignore  [dict get $rule ignore]
    set custom  [dict get $rule custom]

    puts "    $name {"

    # Pattern: emit as braced list of quoted globs
    set patElems [list]
    foreach p $pattern {
        lappend patElems [emit_val $p]
    }
    puts "        pattern  {[join $patElems " "]}"

    if {$exclude ne ""} {
        set exElems [list]
        foreach e $exclude {
            lappend exElems [emit_val $e]
        }
        puts "        exclude  {[join $exElems " "]}"
    }

    if {$subject ne ""} {
        puts "        subject  [emit_val $subject]"
    }

    puts "        delay    $delay"

    if {$email ne ""} {
        puts "        email    [emit_list $email]"
    }
    if {$page ne ""} {
        puts "        page     [emit_list $page]"
    }
    if {$ignore eq "1"} {
        puts "        ignore   1"
    }
    if {$custom ne ""} {
        puts "        custom   [emit_val $custom]"
    }

    puts "    }"
}
puts "}"

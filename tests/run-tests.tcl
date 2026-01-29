#!/usr/bin/env tclsh
# Master test runner - runs all unit and integration tests
# Usage: tclsh tests/run-tests.tcl

set thisDir [file dirname [file normalize [info script]]]
set rootDir [file dirname $thisDir]

puts "=== syslog-alert test suite ==="
puts ""

# Run unit tests
puts "--- Unit tests ---"
set unitDir [file join $thisDir unit]
set unitFailed 0
foreach f [lsort [glob -nocomplain [file join $unitDir *.test]]] {
    puts "Running [file tail $f] ..."
    if {[catch {exec [info nameofexecutable] $f} output]} {
        puts $output
        set unitFailed 1
    } else {
        puts $output
    }
    puts ""
}

# Run integration tests
puts "--- Integration tests ---"
set intDir [file join $thisDir integration]
set intFile [file join $intDir run.tcl]
set intFailed 0
if {[file exists $intFile]} {
    puts "Running integration tests ..."
    if {[catch {exec [info nameofexecutable] $intFile} output]} {
        puts $output
        set intFailed 1
    } else {
        puts $output
    }
} else {
    puts "No integration test runner found."
}

puts ""
puts "=== Done ==="
if {$unitFailed || $intFailed} {
    puts "SOME TESTS FAILED"
    exit 1
} else {
    puts "ALL TESTS PASSED"
    exit 0
}

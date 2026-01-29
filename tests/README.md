# syslog-alert test suite

## Prerequisites

- tclsh 8.6+
- sqlite3 Tcl package

## Run all tests

```
tclsh tests/run-tests.tcl
```

## Run unit tests only

```
tclsh tests/unit/config.test
tclsh tests/unit/explain.test
tclsh tests/unit/stdin.test
```

## Run integration tests only

```
tclsh tests/integration/run.tcl
```

## Test categories

| Category | File(s) | What it validates |
|---|---|---|
| Config parsing | unit/config.test | Good/bad configs, validation errors, dump-config |
| Rule matching | unit/explain.test | Pattern matching, excludes, case insensitivity, ignore rules |
| Stdin processing | unit/stdin.test | Line parsing, max length, malformed input, action capture |
| Integration | integration/run.tcl | End-to-end CLI: config checks, explain, stdin with throttling, paging |

## Test hooks

Three env vars enable testing without network/sendmail:

- `SYSLOG_ALERT_TESTMODE=1` - routes Sendmail to a capture file
- `SYSLOG_ALERT_ACTIONS_FILE=<path>` - where to write captured actions
- `SYSLOG_ALERT_CLOCK=<epoch>` - fixed clock for deterministic throttle tests

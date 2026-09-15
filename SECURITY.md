# Security

Boost signals other processes and reads the process table. That is a lot of
reach for a utility, so this page states exactly what it does with it. If
something here does not match the code, that is a bug — please report it.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** — the *Report a vulnerability*
button under the Security tab. It goes straight to the maintainer and stays
private until there is a fix.

Please don't open a public issue for anything exploitable.

Expect a reply within a week. There is no bounty — this is a solo project.

## What Boost can do to your machine

| Capability | Why it needs it | Scope |
| --- | --- | --- |
| `SIGSTOP` / `SIGCONT` | Pause and resume | Processes you own, never the guard list |
| `SIGTERM` / `SIGKILL` | Close and Force Quit | Same |
| `sysctl(KERN_PROC_ALL)` | Read the process table | Read-only, no privileges needed |
| `proc_pid_rusage` | Per-process memory and CPU | Read-only; fails for root-owned processes, which is why they show `—` |
| Accessibility (optional) | Count an app's open windows, for "close button quits the app" | Read-only, window counts only. Off unless you enable the feature |
| Admin password (optional) | `/usr/sbin/purge` | Off by default. See below |

It does **not** read window contents, keystrokes, files, or the network. It has
no analytics, no telemetry, no update check, and makes no outbound connections
of any kind. There is nothing to opt out of.

## The guard list

`Guard` in `Sources/BoostKit/Models.swift` is a hard-coded set of processes that
can never be closed or paused — WindowServer, Dock, Finder, loginwindow,
launchd and friends. Signalling any of them takes the desktop down with it.

It is not configurable, not overridable from the UI, and covered by tests. If
you are adding to it, add the test too.

## The admin password prompt

One optional feature asks for your password: **Purge disk cache**, which runs
`/usr/sbin/purge` as root through `osascript`. It is **off by default** and
should generally stay that way — it throws away macOS's disk cache, which makes
"free memory" look higher and the machine briefly slower, because everything it
discarded has to be read from disk again.

Nothing else in Boost runs as root, and the command string is a literal with no
interpolation.

## Accessibility access

Used by exactly one optional feature, "close button quits the app", which needs
to know whether an app still has windows open. macOS exposes no other way to
ask. Boost reads window *counts* and nothing else — not titles, not contents.

Turn the feature off and Boost never calls the API.

## Code signing

Release builds are signed and notarized. Builds you make yourself are signed
with a local self-signed certificate (see `docs/codesigning.md`) — which is why
a build of your own will ask for Accessibility access again the first time.

Verify a release before trusting it:

```bash
codesign -dv --verbose=4 /Applications/Boost.app
spctl -a -vvv -t exec /Applications/Boost.app
```

## Scope

In scope: privilege escalation, signalling processes outside the documented
rules, anything that gets Boost to touch a guarded process, code execution via
the keep-list file or any other input.

Out of scope: the fact that Boost can close your apps — that is the point.

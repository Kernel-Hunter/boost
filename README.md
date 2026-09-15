# Boost

A control panel for reclaiming RAM and CPU on macOS. Close things, or **freeze them
and bring them back** exactly as they were.

Open **Boost** from Spotlight (⌘-Space → "Boost"), or keep it in the Dock.

## The two actions

|  | What it does | Reversible |
| --- | --- | --- |
| **Close** | Quits the app properly. Unsaved work prompts you to save first. | No |
| **Pause** | `SIGSTOP`s the app and every helper it spawned. Zero CPU, state preserved in place. | **Yes — Resume All** |

**Pause is the interesting one.** A paused app uses no CPU at all, and because it
stops touching its memory, macOS is free to compress or swap its pages out when
something else needs them. Tick what you want frozen, hit Pause, do your heavy
work, hit **Resume All** and everything comes back mid-scroll.

Resume All sweeps the **whole system** for frozen processes, not just ones Boost
paused — so nothing can get stranded if Boost is quit or crashes. Boost also
resumes everything automatically when it quits (switchable in the ⋯ menu).

## Making the red button actually quit

macOS treats an app and its windows as separate things: closing the last window
leaves the app running so ⌘N is instant. There's no system setting to change
that, and only apps that opt in (Calculator, System Settings) quit on close.

Boost adds it. In the **⋯ menu → "Close button quits the app"**. While it's on,
a blue **Close = quit** pill shows in the toolbar.

It needs **Accessibility access** (System Settings → Privacy & Security →
Accessibility), which is how it reads whether an app still has windows. Boost
uses it for nothing else. Until you grant it, a banner sits under the toolbar and
the feature stays inert.

Three deliberate limits, each of which is a bug if you get it wrong:

- **Minimising is not closing.** Window counts come from the Accessibility API,
  where a minimised window still counts. The obvious alternative — CGWindowList's
  on-screen list — drops minimised windows, so minimising an app would quit it.
- **It only acts on a transition.** An app must be seen *holding* a window and
  then losing it. An app that was already windowless when you switched the
  feature on (a Terminal with no windows open) is left alone, so turning this on
  doesn't mass-quit things.
- **Two-second settle, eight-second launch grace.** So closing one document to
  open another doesn't quit the app, and apps aren't killed while starting up.

Pinned apps are exempt, and it quits politely — unsaved work still prompts.

## What it shows you

Four groups, each with a tick-all box and a live total:

- **Apps** — anything with a window. Ticked by default.
- **Menu Bar & Background** — no windows, still holding RAM: OneDrive, CodexBar,
  Sapphire, Übersicht, Vorssaint, stray `python` processes. Ticked by default when
  it isn't Apple's.
- **Widgets** — Notification Centre and desktop widgets. Collapsed and unticked by
  default: there are ~43 of them and together they hold about 44 MB, so closing
  them buys you nothing and macOS just restarts them. Tick the section if you want
  them gone anyway.
- **System** — macOS internals, hidden behind the toggle. The ones that would take
  your desktop down with them (Dock, WindowServer, Finder, loginwindow…) are
  marked **Protected** and cannot be closed or paused at all, by you or by Boost.

An app and all its helpers count as one row — Claude is 31 processes and ~3.2 GB,
and it's listed once, with the real total.

## Per-row controls

Hover a row for **pause / close / pin**. Pin (also right-click → *Never close this*)
protects an app permanently; it goes grey and no longer counts as selected.

## Reading the numbers

The header bar is solid accent for **in use**, pale for **cached**. Cached memory
is *available* — macOS filling spare RAM with cache is correct behaviour, not a
leak, so "freeing" it is not automatically a win.

**Swap is the number that matters.** At `no swap` your Mac is fine and closing
things buys you little. Once swap starts climbing, macOS is paging to disk and
everything feels slow — that's when this app earns its place.

## Command line

`boost.sh` does the same job headlessly — handy on a hotkey (Shortcuts.app → Run
Shell Script → assign a key).

    ./boost.sh              # close apps + helpers, then purge disk cache
    ./boost.sh --pause      # freeze them instead
    ./boost.sh --resume     # unfreeze everything, system-wide
    ./boost.sh --dry-run    # show what it would touch, change nothing
    ./boost.sh --force      # kill apps that won't quit (LOSES UNSAVED WORK)
    ./boost.sh --no-purge   # skip the cache purge, no password prompt

It never quits the terminal or app it was launched from.

## Config

- Pins made in the app are written to
  `~/Library/Application Support/Boost/keep.txt` and **the script reads the same
  file**, so both stay in sync. Format is `<bundle id><TAB><name>`.
- `keep.txt` (this folder) — extra names the script should never quit.
- `extras.txt` — background processes for the script to kill. Seeded with OneDrive;
  CodexBar, Sapphire, Vorssaint and Übersicht are listed commented out.

## Performance

Boost samples the process table natively (`sysctl` + `libproc`) rather than
shelling out to `ps`. That took a refresh from ~111 ms to ~4 ms, and idle CPU
from ~20% to ~0%. Executable paths are cached per process (keyed on start time,
so a recycled pid can't inherit a stale one), and it refreshes every 2 s while
you're using it, every 10 s in the background.

One consequence: `ps` is setuid root and can read memory for every process,
while Boost runs as you. Memory for root-owned daemons is therefore shown as
**—** (unknown) rather than as a misleading zero. It affects only a handful of
rows in the hidden System group — all of them processes you couldn't signal
anyway.

## Caveats worth knowing

- Pausing an app mid-download or mid-upload can make that connection time out when
  you resume it. Pausing is safe for the app; the far end may have moved on.
- **Purging the disk cache needs your password** (it runs `purge` as root). Cancel
  the prompt and everything else still happens.
- Boost cannot close or pause itself.
- Rebuilding Boost changes its signature, so macOS may ask you to grant
  Accessibility again (untick and retick it in System Settings).

## Building

    ./BoostApp/build.sh              # builds and installs to /Applications
    ./BoostApp/build.sh --no-install # build only

Swift 6 + SwiftUI, built with Command Line Tools only — no Xcode required. Sources
in `BoostApp/Sources/`, icon generated by `BoostApp/gen-icon.swift`.

`build.sh` installs **one** copy, at `/Applications/Boost.app`. It deletes stray
copies from `~/Applications` and this folder, stages inside `build.noindex/` so
Spotlight never indexes a second bundle, and removes the staged copy afterwards.
There should only ever be one Boost in Spotlight.

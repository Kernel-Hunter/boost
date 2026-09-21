# Boost

A memory and disk utility for macOS that tells you the truth.

Free memory without closing apps, freeze apps and bring them back exactly as
they were, and find disk space that is genuinely safe to reclaim. Boost is the
macOS answer to tools like Mem Reduct on Windows, built around what macOS
actually allows rather than a fake cleaner number.

```bash
brew install --cask kernel-hunter/boost/boost
```

Or build it yourself, which takes about as long and involves no Gatekeeper
at all:

```bash
git clone https://github.com/Kernel-Hunter/boost.git
cd boost && ./Scripts/build.sh
```

macOS 14+, Apple Silicon and Intel — every build is universal, one binary for
both. Builds with Command Line Tools. Xcode is not required.

![Boost's memory tab: a radial pressure gauge, 11.56 GB in use of 16.00 GB, and
a card list of running apps grouped with their helper processes](docs/images/memory.png)

> **On signing.** Boost is signed with a local certificate, not notarized:
> notarizing needs a paid Apple Developer account, and this is free software.
> A direct download of the `.zip` will therefore be stopped by Gatekeeper, and
> on recent macOS that is genuinely awkward to get past. The cask clears the
> quarantine flag for you; building from source never sets one. Those are the
> two paths worth using.

---

## Why another one of these

Most "Mac cleaner" apps work by showing you a large number and offering to make
it smaller. The number is usually cached memory, which is memory macOS is
*using well*, and making it smaller makes your Mac slower.

Boost is built the other way round:

- **It tells you when there is nothing to do.** If swap is at zero, the header
  says your Mac is coping and closing things buys you little.
- **It explains what a figure means** before offering to change it. Cached
  memory is shown as available, because it is.
- **It refuses the impressive-looking options.** The disk cleaner ignores your
  Downloads folder and your iPhone backups. They would score well and they are
  not safe.
- **Free Memory is the primary action.** It asks macOS to reclaim idle pages,
  watches swap while it runs, and tells you what actually happened.

## Free Memory, compared with Mem Reduct

Mem Reduct works by calling `EmptyWorkingSet`, a Windows API that lets one
process force another process's pages out to the pagefile. macOS has no
equivalent. No public API lets a third-party app reach into another process
and push its memory to disk. That's confirmed in
[Apple's own kernel source](https://github.com/apple-oss-distributions/xnu/blob/main/doc/vm/memorystatus_notify.md),
not a limitation of this app.

It's also not a technique worth copying if it existed. Apple redesigned macOS
around memory compression specifically to avoid swap: reading a compressed
page back from RAM is far faster than reading from disk, even an SSD, and
repeated swap writes wear the drive down. Mem Reduct's approach predates that
redesign. On today's macOS, deliberately forcing pages to swap would make the
Mac slower, not lighter.

So Boost uses the route macOS actually offers: it briefly asks the system for
memory using Apple's own `memory_pressure` tool, which nudges the kernel to
release idle pages and compress what it can. Boost then gives that request
back, checks the before and after readings, and reports only the memory that
stopped being used.

That means:

- It does not close apps.
- It does not delete files.
- It does not need your admin password, unless you turn on the optional disk
  cache purge yourself.
- It stops early if swap starts growing, because paging to disk would cost more
  than the reclaim is worth.

Expect a few hundred MB to around a gigabyte on a typical run. That's not a
bug: even `purge`, Apple's own and more aggressive disk-cache tool, nets a
similar range on Apple Silicon. If your Mac genuinely isn't short on memory,
there isn't much sitting idle to give back, on Windows or on macOS. If you
want Boost to push harder anyway, Settings has an aggressive mode that asks
for memory more forcefully. It's off by default and says why in the same
screen: pushed far enough, it can be the reason the kernel decides to kill
something on its own, with no warning from Boost first.

## What it does

### Memory

| | | Reversible |
| --- | --- | --- |
| **Free Memory** | Reclaims idle memory through macOS without closing apps. This is the main feature. | No app state changes |
| **Pause** | `SIGSTOP`s an app and every helper it spawned. Zero CPU, state kept in place, and macOS is free to swap its pages out. | **Yes** |
| **Close** | Quits it properly. Unsaved work prompts you first. | No |
| **Purge disk cache** | Optional advanced setting. Asks for your password and is rarely the right answer. | No |

**Free Memory is the main button.** It is for the moment your Mac feels heavy
but you do not want to close your work. Pause is the reversible backup plan:
freeze what you are not using, do your heavy work, hit Resume All, and
everything comes back mid-scroll. Resume All sweeps the whole system, so nothing
can be stranded frozen if Boost crashes or is quit.

An app and all its helpers count as one row. A browser is one entry with its
real total, not thirty mystery processes.

A **sparkline and a sentence** say which way memory has been going, and a badge
names any app whose floor keeps rising, the shape of a leak, which is
invisible in a single reading. Big is not the signal; a browser is supposed to
be big.

### Disk

Finds caches that the tool which made them will simply rebuild: Homebrew, npm,
pip, uv, Cargo, Gradle, Xcode DerivedData, simulator caches, app caches, logs,
Trash.

What it will not touch is the point:

- Your **Downloads** folder
- Any project's **node_modules**
- **iOS device backups**
- Anything behind a privacy prompt. It skips Music, Photos and Safari caches
  rather than ask for access to your media library, because a disk cleaner that
  asks for that is indistinguishable from the ones that deserve the suspicion

![Boost's disk tab, listing reclaimable caches with an explanation of what each
one is and nothing ticked by default](docs/images/disk.png)

Nothing is ticked for you. This deletes files, so opting in should be a decision
rather than the default that happens to be on screen.

Two independent safety layers: an allowlist of what may be scanned, and a
second check of the **resolved** path immediately before every deletion. A
symlink sitting in a cache and pointing at your documents is how tools like
this destroy data; there is a test that builds exactly that trap.

### Elsewhere

- **Menu bar** readout, showing the number only when it is worth reading
- **Dock icon badge**, the same idea applied to the one place you can see it
  without opening Boost at all
- **⌥⌘B** from any app (off by default, because claiming a system-wide shortcut is not
  something an app should help itself to)
- **Sort the list** by name, memory, or CPU, in either direction
- **Reveal in Finder** from any row's menu
- **Close button quits the app**, for apps that stay running with no windows
- **Warn me when swap climbs**: tells you, and can pause what is ticked. It
  can never close anything, and a test enforces that
- **Settings (⌘,)** holds all of the above, plus the aggressive reclaim mode
  and the optional disk cache purge

![Boost's Settings window: window behaviour, the aggressive reclaim toggle
with its trade-off spelled out, and the swap-warning rule](docs/images/settings.png)

## Permissions

| What | Why | When |
| --- | --- | --- |
| None | Reading the process table, memory stats, and signalling your own apps | Always |
| Accessibility | Counting an app's open windows | Only for "close button quits the app" |
| Notifications | The swap warning | Only if you enable it |
| Admin password | `/usr/sbin/purge` | Only if you enable the optional disk-cache purge |

No analytics, no telemetry, no update check, no network access of any kind.
There is nothing to opt out of. See [SECURITY.md](SECURITY.md).

## Command line

`boost.sh` does the same job headlessly, for a hotkey or a script.

```bash
./boost.sh              # close apps and helpers
./boost.sh --pause      # freeze them instead
./boost.sh --resume     # unfreeze everything, system-wide
./boost.sh --dry-run    # show what it would touch, change nothing
```

Pins made in the app are written to
`~/Library/Application Support/Boost/keep.txt`, and the script reads the same
file.

## Building and testing

```bash
./Scripts/build.sh          # build and install to /Applications
./Scripts/test.sh           # run the suite
```

Use `Scripts/test.sh` rather than `swift test`. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the two flags it needs and why their
error messages blame the wrong thing.

## Is it free

Yes, and the parts that matter always will be. Safety, honest readings, and
anything that already shipped free are not going behind a paywall. See the
rules written into [`Pro.swift`](Sources/BoostKit/Pro.swift). If a paid tier
ever appears it will be for things that cost something to run, and the commit
that introduces it will say so plainly.

## Licence

GPL-3.0. See [LICENSE](LICENSE).

Built by [Karim Masmoudi](https://github.com/Kernel-Hunter).

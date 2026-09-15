# Boost

A memory and disk utility for macOS that tells you the truth.

Close apps, or **freeze them and bring them back** exactly as they were. Find
disk space that is genuinely safe to reclaim. And read an honest account of what
your Mac is actually doing, rather than a number engineered to make a button
look worth pressing.

```bash
brew install --cask kernel-hunter/boost/boost
```

Or build it yourself, which takes about as long and involves no Gatekeeper
at all:

```bash
git clone https://github.com/Kernel-Hunter/boost.git
cd boost && ./Scripts/build.sh
```

macOS 14+. Builds with Command Line Tools — Xcode is not required.

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
  Downloads folder and your iPhone backups — they would score well and they are
  not safe.
- **"Free memory" reports what actually happened**, including when the honest
  answer is "the cache you dropped was already available, and your Mac is now
  briefly slower".

## What it does

### Memory

| | | Reversible |
| --- | --- | --- |
| **Pause** | `SIGSTOP`s an app and every helper it spawned. Zero CPU, state kept in place, and macOS is free to swap its pages out. | **Yes** |
| **Close** | Quits it properly. Unsaved work prompts you first. | No |
| **Free memory** | Drops macOS's disk cache. Asks for your password. Rarely the right answer. | No |

**Pause is the interesting one.** Freeze what you are not using, do your heavy
work, hit Resume All, and everything comes back mid-scroll. Resume All sweeps
the whole system, so nothing can be stranded frozen if Boost crashes or is
quit.

An app and all its helpers count as one row — a browser is one entry with its
real total, not thirty mystery processes.

A **sparkline and a sentence** say which way memory has been going, and a badge
names any app whose floor keeps rising — the shape of a leak, which is
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
- Anything behind a privacy prompt — it skips Music, Photos and Safari caches
  rather than ask for access to your media library, because a disk cleaner that
  asks for that is indistinguishable from the ones that deserve the suspicion

Two independent safety layers: an allowlist of what may be scanned, and a
second check of the **resolved** path immediately before every deletion. A
symlink sitting in a cache and pointing at your documents is how tools like
this destroy data; there is a test that builds exactly that trap.

### Elsewhere

- **Menu bar** readout, showing the number only when it is worth reading
- **⌥⌘B** from any app (off by default — claiming a system-wide shortcut is not
  something an app should help itself to)
- **Close button quits the app**, for apps that stay running with no windows
- **Warn me when swap climbs** — tells you, and can pause what is ticked. It
  can never close anything, and a test enforces that

## Permissions

| What | Why | When |
| --- | --- | --- |
| None | Reading the process table, memory stats, and signalling your own apps | Always |
| Accessibility | Counting an app's open windows | Only for "close button quits the app" |
| Notifications | The swap warning | Only if you enable it |
| Admin password | `/usr/sbin/purge` | Only if you press Free memory |

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

Use `Scripts/test.sh` rather than `swift test` — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the two flags it needs and why their
error messages blame the wrong thing.

## Is it free

Yes, and the parts that matter always will be. Safety, honest readings, and
anything that already shipped free are not going behind a paywall — see the
rules written into [`Pro.swift`](Sources/BoostKit/Pro.swift). If a paid tier
ever appears it will be for things that cost something to run, and the commit
that introduces it will say so plainly.

## Licence

GPL-3.0. See [LICENSE](LICENSE).

Built by [Karim Masmoudi](https://github.com/Kernel-Hunter), with Claude.

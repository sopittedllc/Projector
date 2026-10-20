# Software Update

Projector checks for a newer published build on launch and, if the user agrees,
downloads it, installs it and relaunches. This is Sparkle 2, reached through
`UpdateServiceProtocol`.

---

## The one-time setup

**Nothing updates until an EdDSA key pair exists.** The private half signs every
DMG; the public half is compiled into the app and is the only reason a
downloaded update can be trusted. Do this once, on the machine that cuts
releases:

```bash
# Sparkle's tools come with the resolved package. Find them:
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*Sparkle*'

# Generate the pair. The private key goes into this machine's login keychain
# and never leaves it; the command prints the public half.
./generate_keys
```

Put the printed public key into `Projector/Info.plist` as `SUPublicEDKey`.

**Until that value is filled in, the updater does not start at all.** The app is
otherwise completely normal: no update menu item, one warning line in the
diagnostic log. That is deliberate — Sparkle's
own response to a missing key is to fail `startUpdater` and put a modal *"Unable
to Check For Updates"* alert on screen at every launch, which is not a state to
ship. `SparkleUpdateService` checks for the key first and stays inert without
one, because an updater that cannot verify a signature must not install
anything.

Back the private key up somewhere you would not lose (`./generate_keys -x
private-key.txt` exports it). Losing it means no installed copy can ever be
updated again — they would all have to be replaced by hand, because a new key
would not match the one they were built to trust.

---

## What happens on each release

`scripts/build-release.sh` already built, signed, notarized and published the
DMG. It then:

1. Signs the **exact uploaded DMG** with `sign_update`, after notarization and
   stapling — those steps change the file's bytes, and the signature has to
   cover the bytes that get downloaded.
2. Adds an `<item>` to `appcast.xml` via `scripts/appcast.py`, keyed on the
   short version so a same-day rebuild replaces its entry rather than adding a
   duplicate.
3. Commits `appcast.xml` **by path** and pushes it.

That last step is what publishes the update. The build prints
`Appcast: NOT published` when any of it was skipped, because a release that
never reaches the feed is invisible to every copy already installed.

The feed is read from the repository's main branch:

```
https://raw.githubusercontent.com/sopittedllc/Projector/main/appcast.xml
```

A release asset would not do: the feed has to sit at one unchanging URL while
the builds it lists do not.

---

## What is checked before an update installs

Two independent gates:

| Gate | What it stops |
|------|---------------|
| EdDSA signature vs. `SUPublicEDKey` | A rewritten feed pointing at a hostile download |
| Developer ID match | A correctly-signed-but-different app replacing this one |

The feed itself is public and unauthenticated. That is fine — it is a list of
URLs, and trust rests on the signatures rather than on the transport.

---

## Why there is no XPC service

Projector is not sandboxed, so Sparkle installs updates in-process and needs
neither its installer XPC services nor the mach-lookup exceptions that reach
them. Sparkle's sandboxing guide says to undo both when sandboxing is turned
off; `SUEnableInstallerLauncherService` was removed from `Info.plist` and the
exceptions from `Projector.entitlements` for that reason.

It used to be sandboxed. A dropped file granted only that file, so saving a
project beside its media, writing Optimized Media and relinking moved files
each needed a folder panel or a stored bookmark. Distribution is a notarized
Developer ID DMG, which requires Hardened Runtime but not a sandbox.

Copies installed while the app was sandboxed still update: the installer they
run is the one they shipped with.

---

## The Mac App Store

The App Store requires the App Sandbox, and does not accept Sparkle. If
Projector is ever submitted there, that build needs its own configuration with:

- the App Sandbox turned back on, with folder access designed for it
  (the Save sheet, Optimized Media and relinking all write beside user files),
- Sparkle removed from the target,
- an `UpdateServiceProtocol` implementation that reports nothing to update
  (the App Store does the updating).

Every caller goes through that protocol rather than touching Sparkle directly,
so the update half is a swap rather than a hunt.

---

## Update behaviour

| Setting | Value | Why |
|---------|-------|-----|
| `SUEnableAutomaticChecks` | `YES` | Checks are on without a first-launch permission prompt |
| `SUScheduledCheckInterval` | `3600` | One hour, the shortest Sparkle honours — so a launch finds a new version without re-checking on every relaunch |
| `SUAutomaticallyUpdate` | `YES` | A found update downloads in the background; the user is asked once, when it is ready to install (2026-09-15: was `NO`, which asked twice) |

The user can turn checks off in **Settings → Updates**, or check on demand there
or from **Projector → Check for Updates…**.

**"On launch" is approximate.** Sparkle's scheduler owns the timing and will not
check more than once an hour, so relaunching four times in an afternoon produces
one check, not four. There is deliberately no second launch-time check racing
Sparkle's own.

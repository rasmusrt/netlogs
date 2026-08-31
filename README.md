# Netlogs

A native macOS app that watches your router and the internet at the same time,
so "the internet is slow" becomes a question with an answer.

Most speed tests tell you what your connection was doing for twenty seconds
while you watched. Netlogs runs for hours and tells you what it did while you
weren't watching — and, crucially, whether the problem was inside your house or
outside it.

## What it measures

- **Two pings a second, side by side.** Your router and an internet host. When
  only one of them stops answering, you know which half is broken.
- **Latency under load.** Speed tests report throughput *and* what happened to
  ping and jitter while the line was saturated — bufferbloat, the thing that
  makes a fast connection feel slow on calls.
- **Wi-Fi signal over the session**, with a mark wherever the channel or band
  changed. A signal that fell off at 03:10 is visible as a signal that fell off
  at 03:10, not as 600 identical rows.
- **Every failure, timestamped**, with a verdict for the session in plain
  language rather than a grade.

Sessions are saved, so you can compare last night with this morning.

## Install

**Build it. This is the supported path**, and on macOS 15+ it is currently the
only one that works without a fight:

```bash
git clone https://github.com/rasmusrt/netlogs.git
cd netlogs
Scripts/app-bundle.sh
```

That builds the app, installs it to `~/Applications`, and opens it. You need
Xcode or the Command Line Tools; nothing else. No security prompt, because an
app you compiled was never downloaded and so was never quarantined.

### Homebrew — works, but macOS will fight you

```bash
brew tap rasmusrt/netlogs
brew trust rasmusrt/netlogs
brew install --cask netlogs
```

The cask installs correctly. **macOS then refuses to run it**, and — this is
the part worth knowing before you try — the usual escape hatch is not reliably
available. Netlogs is ad-hoc signed rather than notarized, because
notarization needs a paid Apple Developer Program membership and the Mac App
Store is not an alternative (its sandbox blocks the ICMP sockets this app is
built on). For a downloaded ad-hoc signed app, macOS 15+ shows a dialog whose
only buttons are **Move to Trash** and **Done** — one deletes the app, the
other gives up — and the "Open Anyway" button that is supposed to appear in
System Settings → Privacy & Security does not always turn up.

If it does not, the only way to run a Homebrew install is to clear the
quarantine attribute yourself:

```bash
xattr -dr com.apple.quarantine /Applications/Netlogs.app
```

That is a real Gatekeeper bypass, and you should not run it on software just
because a README told you to. Read the source, or build from it — the option
above exists precisely so you never have to take this one on trust.

This is fixed properly by notarization, not by better instructions.

## Requirements

macOS 15 (Sequoia) or later, on Apple silicon or Intel.

## Privacy

Netlogs has no servers, no accounts, and no analytics. Your sessions live in a
SQLite database on your Mac and are never uploaded. It does talk to two places,
both of them measurements you asked for: whatever host you ping, and Cloudflare
when you run a speed test. [PRIVACY.md](PRIVACY.md) spells out exactly what
that means, including the parts that are easy to forget to mention.

## Licence

MIT — see [LICENSE](LICENSE).

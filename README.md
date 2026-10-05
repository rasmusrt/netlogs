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

### Homebrew

```bash
brew tap rasmusrt/netlogs
brew trust rasmusrt/netlogs
brew install --cask netlogs
```

Three commands, because Homebrew 6 asks for a tap outside the official ones to
be tapped and trusted explicitly. Netlogs is signed with a Developer ID and
notarized by Apple, so it opens like any other downloaded app. It is not on the
Mac App Store because the App Sandbox blocks the ICMP sockets it is built on.

### Build from source

```bash
git clone https://github.com/rasmusrt/netlogs.git
cd netlogs
Scripts/app-bundle.sh
```

That builds the app, installs it to `~/Applications`, and opens it. You need
Xcode or the Command Line Tools; nothing else.

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

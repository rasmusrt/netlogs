# Netlogs privacy policy

_Last updated: 31 August 2026. Applies to Netlogs for macOS, version 0.1.0._

Netlogs has no servers, no accounts, and no analytics. Nothing you record is
sent to us, because there is no "us" to send it to. What follows is the whole
of it, in detail, because a network monitoring tool asking for your trust
should be specific.

## What Netlogs stores, and where

Everything stays on your Mac, in a SQLite database at:

```
~/Library/Application Support/Netlogs/netlogs.sqlite
```

It holds, per monitoring session:

- **Ping samples** — a timestamp and a round-trip time for your router and for
  the internet host, once a second.
- **Throughput results** — download and upload rates, latency and jitter
  measured during each speed test.
- **Network snapshots** — your interface name, local IP address, subnet mask,
  gateway, DNS server addresses and MTU; and on Wi-Fi, the signal strength,
  noise, transmit rate, channel, band, protocol and security type. Stored when
  something changes, plus once a minute.

- **Traffic captures** — the names, process IDs and byte rates of programs
  running **on this Mac** that were sending or receiving data at moments when
  your connection went slow. Taken by running the system's `nettop` command
  once, at most one capture every ten minutes, and only while the internet is
  slow *and* your router is responding normally — the moment where knowing what
  was uploading actually explains something.

  This is the only thing Netlogs records that is about your Mac rather than
  about your connection, so it has its own switch: **Settings → Traffic
  capture**, and turning it off stops the captures entirely. It sees this Mac
  only — no other device on your network appears — and, like everything else
  here, it is stored locally and sent nowhere. It *is* included in session
  exports, so check an export before sharing it if that matters to you.

- **Gateway telemetry** — only if you turn it on under **Settings → Gateway
  telemetry**. Netlogs then asks your own UniFi gateway, on your local network,
  for the 5G radio's signal figures (signal quality, band, cell) and the byte
  counters on its internet connection. It stores only those figures. The
  gateway also reports the modem's IMEI and the SIM's ICCID, and Netlogs drops
  them rather than storing them. The API key you give it is kept in your
  Keychain. It is only sent to the gateway, and only after you have trusted
  that gateway's certificate. Nothing is sent to Ubiquiti or anywhere else.

Your Wi-Fi network name (SSID) and access point address (BSSID) are **not**
recorded: macOS 26 does not make them available to apps without a special
entitlement, and Netlogs does not have one.

This database is yours. Delete individual sessions in the app, or delete the
file. Nothing is retained elsewhere, because nothing is sent elsewhere.

## What Netlogs sends, and to whom

Three kinds of traffic leave your Mac, all of them measurements you asked for.

**1. Pings to your router.** ICMP echo requests to your own gateway. This
traffic does not leave your local network.

**2. Pings to an internet host.** ICMP echo requests, once a second while a
session runs. The default is `1.1.1.1`, which is operated by **Cloudflare**.
Like any internet request, it discloses your IP address to whoever runs that
address. You can change the host in Settings to any address you prefer.

**3. Speed tests, to Cloudflare.** When you run a throughput test, Netlogs
downloads from and uploads to `speed.cloudflare.com` — the same public
endpoints Cloudflare's own speed test uses. This means:

- Your IP address is visible to Cloudflare, as with any web request.
- Cloudflare collects the measurement results on completion, and states that it
  does so "for the purpose of calculating aggregated insights". Their handling
  of that data is governed by
  [Cloudflare's privacy policy](https://www.cloudflare.com/privacypolicy/), not
  by this one.
- Speed tests transfer real data — up to 2 GB per download run. On a metered or
  capped connection, that counts against your allowance.

Speed tests only run when you start one or when you enable automatic tests. If
you never run one, Netlogs never contacts Cloudflare for throughput.

## What Netlogs does not do

- No analytics, telemetry, usage reporting or crash reporting of any kind.
- No accounts, no sign-in, no cloud sync, no backups to anywhere.
- No advertising, and no data sold or shared with anyone.
- **Location is not used.** Netlogs requests no location permission.
- No automatic updates, and so no update pings.

## Exports

Exporting a session writes a file where you choose to put it. What happens to
that file afterwards is up to you — it contains the session data described
above, including your local IP address and gateway.

## Changes

Material changes to this policy will be noted in the release notes and in this
file's history, which is public in the repository.

## Contact

Questions: open an issue at
<https://github.com/rasmusrt/netlogs/issues>.

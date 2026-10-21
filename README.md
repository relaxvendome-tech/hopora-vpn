# Hopora

Free Android VPN with a **built-in Tor mode**, anti-censorship bridges and a **calculator camouflage**.
Available in 20 languages. Licensed under the **GNU GPL v3** (see `LICENSE`).

## Modes

- **Fast** — one-tap connection to the fastest public server of the
  [VPN Gate](https://www.vpngate.net/) academic project (OpenVPN, embedded engine).
  Shows an ad before each connection. Volunteer servers may keep logs:
  not for sensitive use.
- **Tor** — the whole phone goes through the Tor network (3 encrypted relays),
  no ads, no trackers.
  - DNS resolved through Tor (local mapping, no leak), IPv6 blocked.
  - Built-in bridges: Snowflake, obfs4, meek, with automatic fallback when Tor is blocked.
  - Independent check through check.torproject.org, new-identity button.
  - In Tor mode the app contacts neither VPN Gate nor the ad network.

## Hopora Ghost (camouflage)

- The launcher icon and name become a **working calculator**; Hopora opens with a secret code followed by `=`.
- Optional **duress code**: shows a normal result while Hopora silently disconnects and wipes its local data.
- **Panic button** (long-press): disconnect, wipe, back to the calculator.
- Automatic re-lock when the app goes to the background; screenshots and recents preview blocked.

Limits, stated honestly: Android still shows a key icon while a VPN is on, the app is still listed
in Settings › Apps, and no app can protect a phone already compromised by spyware.
Hopora has **not** been independently audited. People at high risk should also use
audited tools (Tor Browser, Signal) and can get free help from the
[Access Now Digital Security Helpline](https://www.accessnow.org/help/).

## Components

| Component | License |
|---|---|
| [Tor](https://gitlab.torproject.org/tpo/core/tor) via [tor-android](https://github.com/guardianproject/tor-android) | BSD-3-Clause |
| [IPtProxy](https://github.com/tladesignz/IPtProxy) (Snowflake, Lyrebird/obfs4, meek) | MIT / BSD |
| [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) | MIT |
| [openvpn_flutter](https://github.com/nizwar/openvpn_flutter) / OpenVPN / ics-openvpn | GPL-3.0 / GPL-2.0 |

## Build

The app is a Flutter project; the Android part is generated in CI.
See `.github/workflows/build-apk.yml`: `flutter create`, dependencies, then
`android_templates/patch_android.py` (manifest, Tor service, JNI, camouflage), then
`flutter build apk` / `flutter build appbundle`.

---

**FR —** Hopora : VPN Android gratuit avec mode Tor intégré, ponts anti-censure et camouflage
en calculatrice. Logiciel libre sous licence GNU GPL v3.

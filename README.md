<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/huglab-logo-readme-dark.png">
  <img src="docs/images/huglab-logo-readme-light.png" alt="huglab" width="268">
</picture>

# DuoBar+

Battery, network and volume in one menu bar icon, with a detail page for everything behind them.

[**Download**](https://github.com/huglab-dev/DuoBar-Plus/releases/latest) · macOS 13 or later · Apple Silicon and Intel · MIT License

<br>

<img src="docs/images/duobar-features.png" alt="DuoBar+ features: the menu bar icon's ring, center and dots, and detail pages for Network, Battery, Bluetooth, System, Disk and AI Usage" width="830">

</div>

DuoBar+ is a fork of [DuoBar](https://github.com/Mikeli7666/DuoBar) by Mike Li. DuoBar puts a battery ring, the network state and four volume dots into a single icon. DuoBar+ keeps that idea, lets you choose what each part of the icon shows, and adds a detail page per module to the popover.

## The menu bar icon

<p align="center">
  <img src="docs/images/glyph-states.png" alt="The DuoBar+ menu bar icon in nine states: battery colors, a percentage in the center, charging, AirPods connected and low battery" width="760">
</p>

Each part of the icon can show something else:

| Part | Options |
|---|---|
| Ring | Automatic, Battery, CPU, Memory, Disk, None |
| Center | Wi-Fi, Battery %, CPU %, None |
| Dots | Volume, Network, Battery, Wi-Fi Signal, CPU, None |

You can also set the ring color (any color you like), the icon size, the ring thickness and the size of the center mark. The battery percentage goes inside the icon or next to it.

The icon reacts to events, and each one can be turned off: plugging in, connecting AirPods or headphones, low battery, losing the network, and changing the volume. With **Unfold on Hover**, pointing at the icon opens it into one icon per reading, and clicking one goes straight to its page.

## The popover

<p align="center">
  <img src="docs/images/demo.gif" alt="Animation of the DuoBar+ popover: the Network, Battery and Bluetooth pages" width="800">
</p>

Modules can be reordered and switched off in Settings. A module that is off runs no timers and asks for no permissions.

| Module | What it shows |
|---|---|
| **Network** | Signal, noise, link rate, channel, security and Wi-Fi standard. IP addresses, router, DNS and VPN. Hardware and private MAC addresses. The adapter's name on a wired connection. A speed graph, a Wi-Fi picker that lists known networks first, and an optional roaming log. |
| **Battery** | Level, charger, cycle count and maximum capacity. |
| **Bluetooth** | Paired devices with connect and disconnect. Battery levels, including left, right and case for AirPods. |
| **System** | A live CPU graph with performance and efficiency cores, memory breakdown and pressure, swap, top processes and details about the Mac. |
| **Disk** | All volumes. Click one to open it in Finder, or unmount external drives from the list. |
| **AI Usage** | 5-hour and weekly limits for Claude and Codex, with reset times and a warning from 90 %. Off by default. |
| **Menu Bar Items** | Menu bar icons that the notch or Hidden Bar keeps out of sight. Click one to open its menu, or the app when its menu can't be read. Off by default. |

Right-click a card for shortcuts:

- **Network:** Flush DNS Cache, Edit Hosts File, Renew DHCP Lease, Configure IP and IP Profile. Changes ask for your administrator password.
- **System:** Open Activity Monitor.

**Configure IP** sets IPv4 to DHCP, DHCP with a manual address or manual, along with DNS servers and search domains. While your own lists are empty it shows the ones in use. Save the settings as a profile, then switch profiles from the Network card's right-click menu.

## The notch

On a MacBook with a camera notch, macOS hides menu bar icons that don't fit beside it. DuoBar+ offers two ways around that:

- **Hidden icons:** turn on the Menu Bar Items module, and optionally the arrow to the left of the DuoBar+ icon. The arrow lists the hidden icons and opens their menus. This needs Accessibility access.
- **Menu Bar Below Notch:** switches the built-in display to its mode of the same width and sharpness that ends under the notch, so every icon fits. You lose the top 44 points of the screen. Find it in the arrow's list, the Menu Bar Items page or by right-clicking the DuoBar+ icon. Choose it again to go back.

Launchers like Raycast can use these links:

| Link | What it does |
|---|---|
| `duobarplus://toggle-notch` | Moves the menu bar below the notch, or back |
| `duobarplus://notch-on`, `duobarplus://notch-off` | Below the notch, or full height |
| `duobarplus://ip-profile?name=Home` | Applies the IP profile named Home. `name=dhcp` goes back to DHCP. |

A ready-made Raycast script is in [scripts/raycast](scripts/raycast). Add that folder under Raycast's Extensions → Script Commands.

## Install

Download the latest `.dmg` from [Releases](https://github.com/huglab-dev/DuoBar-Plus/releases), open it and drag DuoBar+ to Applications.

DuoBar+ is signed with a self-signed certificate and is not notarized by Apple, so macOS blocks it the first time you open it. To allow it:

1. Try to open DuoBar+ and close the warning.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Choose **Open Anyway** next to DuoBar+ and confirm with your password.

New versions need the same approval. The app shows a card in the popover when a new version is out, with a link to its download page. It does not install anything itself. You can turn the check off in Settings.

## Build from source

Building needs Xcode 26, because the Liquid Glass code uses the macOS 26 SDK. From a clone of this repository:

```bash
xcodebuild -project DuoBar.xcodeproj -scheme DuoBar -configuration Release -derivedDataPath build build
```

```bash
open "build/Build/Products/Release/DuoBar+.app"
```

The build is signed ad hoc, so macOS may ask for permissions again after each rebuild. If the Bluetooth list is empty, the app tells you when access is missing and links to the right setting. To sign with your own Apple Developer team, set `DEVELOPMENT_TEAM` in the project.

Run the tests with:

```bash
xcodebuild -project DuoBar.xcodeproj -scheme DuoBar -destination 'platform=macOS' test
```

## Privacy

DuoBar+ has no analytics and no account. It makes two kinds of network request:

- When the popover opens, at most once a day, it asks GitHub for the latest release of DuoBar+. Turn this off under Settings → General → Updates.
- If you turn on AI Usage and leave Claude enabled, it fetches your plan limits from Anthropic.

| Access | Why |
|---|---|
| Location | macOS requires it to reveal the name of the Wi-Fi network. |
| Bluetooth | To list devices and recognize audio connections. |
| Keychain (only with AI Usage and Claude on) | To read the sign-in Claude Code already saved. |
| Accessibility (only with Menu Bar Items on) | To find menu bar icons hidden by the notch and open their menus. |
| Administrator password (each time) | To flush the DNS cache, save the hosts file and change the IP configuration. DuoBar+ never stores it. |

AI Usage reads the Claude Code sign-in but never renews or changes it. The request goes to `api.anthropic.com` while the popover is open, at most every two minutes unless you press Refresh. That endpoint is undocumented, so it can stop working without notice. Codex limits come from the session logs Codex saves on your Mac, and nothing about them is sent anywhere.

## Performance

With the popover closed and no CPU, memory, disk or network reading in the icon, DuoBar+ used 0.10 % of one CPU core over five minutes, against 0.13 % for DuoBar 1.4.0 measured at the same time. Readings like CPU in the icon cost about 1.5 %. The method and the other measurements are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Credits and license

DuoBar+ is developed by Hugo Bjurström at huglab.

It is based on [DuoBar](https://github.com/Mikeli7666/DuoBar), Copyright (c) 2026 Mike Li. DuoBar+ is Copyright (c) 2026 Hugo Bjurström. Both are distributed under the [MIT License](LICENSE). The license text is also included in the app, under Settings → General → Developer.

DuoBar+ is an independent project and is not affiliated with or endorsed by Apple, Anthropic or OpenAI, or by the original DuoBar project.

# Gravedecay for Omarchy

Theme-native Omarchy fleet panel for discovering Gravedecay appliances on your
Tailscale network, watching their health, and opening their tools.

The skull follows the fleet: normal when every grave is healthy, dim when no
appliance answers, urgent with an issue badge when something is restless, and
subtly breathing while discovery runs.

## Features

- Multi-appliance discovery over Tailscale with retained unreachable state
- Omarchy-native hero, typography, colors, spacing, meters, cards, and controls
- CPU, memory, and disk history kept only in Quickshell memory
- Sessions, service/container health, uptime, temperatures, and observation age
- Owner-gated T3 chat tracking with working/attention counts and deep links
- State-aware Gravedecay epitaphs
- Optional health-transition and T3-attention desktop notifications
- Installed-web-app detection with existing-window focus, empty-workspace
  launch, and normal-browser fallback

## Install

```sh
omarchy plugin add https://github.com/projectmushroom/omarchy-gravedecay.git --enable
```

## Update, disable, and remove

```sh
omarchy plugin update projectmushroom.gravedecay
omarchy plugin disable projectmushroom.gravedecay
omarchy plugin remove projectmushroom.gravedecay
```

## Requirements and compatibility

- Omarchy 4/Quattro with Quickshell plugin support
- `tailscale`, `curl`, and `grep` available on the Omarchy host
- A Gravedecay appliance exposing summary API v1, introduced in Gravedecay
  v0.19.0
- T3 activity requires the optional owner-only `t3-activity.env` configuration
  from Gravedecay v0.22.0 or newer

This is a root Omarchy plugin repository: install it with `omarchy plugin add`,
not by copying files or running a local installer.

## Security and data behavior

Every 30–300 seconds, and when the panel opens, the widget runs `tailscale
status --json`, considers only online nodes with a valid tailnet DNS name and
stable ID, then requests `https://<dns>/grave/api/v1/summary`. Requests use
bounded time and response-size limits. Only responses identifying themselves as
`product: "gravedecay"` with `api_version: 1` are shown. For each validated
grave it also requests the optional, owner-gated
`https://<dns>/grave/api/t3-activity` projection. Disabled, forbidden, missing,
or unreachable activity feeds do not affect appliance health or reachability.

Discovery, summaries, last-known state, and graph samples remain in Quickshell
memory and disappear with the shell process. The plugin has no registry,
on-disk history, tokens, credentials, remote controls, daemon, listener, or
bundled Gravedecay server. Dashboard, T3, Terminal, Network, and T3 thread
buttons open only validated tailnet HTTPS or same-host paths supplied by the
appliance responses.

The dashboard launcher accepts only a validated `.desktop` identifier and only
uses it when its desktop file contains the selected appliance's exact HTTPS
host. It focuses a matching existing Hyprland window, otherwise launches the
web app on the first empty workspace. Any failed check falls back to the
validated dashboard URL in the default browser. Notifications are disabled by
default.

## Use

Left-click the skull to open or close the panel. Right- or middle-click refreshes
discovery.

| Key | Action |
| --- | --- |
| Left/Right | Select another appliance |
| Up/Down | Scroll the panel |
| Enter or `d` | Open/focus the selected dashboard |
| `r` | Refresh discovery |
| Escape | Close the panel |

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `refreshIntervalSec` | `45` | Background discovery interval |
| `historySamples` | `60` | Samples retained per appliance in memory |
| `desktopEntry` | `gravedecay.desktop` | Installed dashboard PWA; empty means browser only |
| `notificationsEnabled` | `false` | Notify on health changes and new T3 attention requests |

## Validation

```sh
omarchy plugin validate .
node tests/model.test.js
```

The model test runs anywhere Node is available. The Omarchy/Quickshell runtime
requires an Omarchy desktop and is not validated on non-Omarchy hosts.

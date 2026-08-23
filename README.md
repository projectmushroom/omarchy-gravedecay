# Gravedecay for Omarchy

Native Omarchy bar widget for discovering reachable Gravedecay appliances on
your Tailscale network and showing their summary.

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
- `tailscale` and `curl` available on the Omarchy host
- A Gravedecay appliance exposing summary API v1, introduced in Gravedecay
  v0.19.0

This is a root Omarchy plugin repository: install it with `omarchy plugin add`,
not by copying files or running a local installer.

## Security and data behavior

Every 30–60 seconds, and when the panel opens, the widget runs `tailscale
status --json`, considers only online nodes with a valid tailnet DNS name and
stable ID, then requests `https://<dns>/grave/api/v1/summary`. Requests use
bounded time and response-size limits. Only responses identifying themselves as
`product: "gravedecay"` with `api_version: 1` are shown.

Discovery and summaries remain in Quickshell memory. The plugin has no
registry, history, tokens, credentials, remote controls, daemon, listener, or
bundled Gravedecay server. Dashboard, T3, Terminal, and Network buttons open
only safe same-host paths supplied by a validated appliance response.

## Use

Left-click the grave icon to open or close the panel. Right- or middle-click
refreshes discovery. In the panel, use Up/Down to switch appliances, `r` to
refresh, and Escape to close; use the dropdown or buttons with the mouse.

## Validation

```sh
omarchy plugin validate .
node tests/model.test.js
```

The model test runs anywhere Node is available. The Omarchy/Quickshell runtime
requires an Omarchy desktop and is not validated on non-Omarchy hosts.

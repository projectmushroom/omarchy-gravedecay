# Gravedecay for Omarchy

Theme-native Omarchy fleet panel for discovering Gravedecay appliances on your
Tailscale network, watching their health, talking to their Gravekeeper and
Diggers, keeping them updated, and opening their tools.

The skull follows the fleet: normal when every grave is healthy, dim when no
appliance answers, urgent with an issue badge when something is restless, and
subtly breathing while discovery runs.

## Features

- Multi-appliance discovery over Tailscale with retained unreachable state
- Omarchy-native hero, typography, colors, spacing, meters, cards, and controls
- CPU, memory, and disk history kept only in Quickshell memory
- Sessions, service/container health, uptime, temperatures, and observation age
- Owner-gated T3 chat tracking with working/attention counts and deep links
- Talk to each grave's Gravekeeper and Diggers from the panel: pick up recent
  conversations, follow running turns, stop, finish, and resume a
  budget-paused digger
- Digger status, budget and Slack approvals at a glance; approvals light the
  bar badge
- Per-grave release checks with a confirmed one-click grave update
- Plugin update checks with a reviewed, terminal-based update
- State-aware Gravedecay epitaphs
- Optional health-transition, T3-attention, digger-approval, Keeper-answer and
  grave-update desktop notifications
- Installed-web-app detection with existing-window focus, empty-workspace
  launch, and normal-browser fallback

## Install

```sh
omarchy plugin add https://github.com/projectmushroom/omarchy-gravedecay.git --enable
```

## Update, disable, and remove

When a newer plugin is on its git origin, the panel shows it at the bottom.
**Review & update** opens a terminal running `omarchy plugin update`, which
shows the incoming diff and asks before applying it. The same commands work
from any terminal:

```sh
omarchy plugin update projectmushroom.gravedecay
omarchy plugin disable projectmushroom.gravedecay
omarchy plugin remove projectmushroom.gravedecay
```

## Requirements and compatibility

- Omarchy 4/Quattro with Quickshell plugin support
- `tailscale`, `curl`, `jq`, `git`, and `grep` available on the Omarchy host
- Installed with `omarchy plugin add` (a git checkout) for plugin update checks
- A Gravedecay appliance exposing summary API v1, introduced in Gravedecay
  v0.19.0
- T3 activity requires the optional owner-only `t3-activity.env` configuration
  from Gravedecay v0.22.0 or newer
- The Gravekeeper requires a single-owner Linux grave on v0.33.0 or newer;
  Diggers require v0.38.0 or newer. Both appear only when the grave advertises
  them in its capabilities

This is a root Omarchy plugin repository: install it with `omarchy plugin add`,
not by copying files or running a local installer.

## Security and data behavior

Every request to a grave goes through `bin/gravedecay-api`, which keeps the
plugin on the tailnet:

- The host must be an online node in `tailscale status` with a `*.ts.net`
  name, and the connection is pinned to that node's Tailscale `100.64.0.0/10`
  address, so DNS can never steer a request elsewhere.
- HTTPS only, no redirects, no proxies, no `~/.curlrc`, bounded time and
  response size.
- Management calls are a fixed allowlist of `/grave/api/v1/` routes:
  capabilities, release and update status, upgrade, Keeper and Digger
  conversations. Conversation and digger identifiers are validated before
  they reach a URL.
- Request bodies are passed on stdin, never on the command line, and must be
  a single JSON object.

Owner authorization is the grave's own check of your Tailscale identity. The
plugin sends `X-Grave-Client: 1` and nothing else: no token, cookie, or
identity header, and it stores no credentials.

Every 30–300 seconds, and when the panel opens, the widget runs `tailscale
status --json` and probes each online node's `/grave/api/v1/summary`. Only
responses identifying themselves as `product: "gravedecay"` with
`api_version: 1` are shown. For each validated grave it also reads the
optional owner-gated T3 activity projection, the capabilities document, and,
when advertised, the digger list and Keeper conversation list. Release
choices and updater status are read at most every 15 minutes per grave.
Disabled, forbidden, missing, or unreachable feeds never affect appliance
health or reachability.

Writes happen only when you act: sending a message, stopping, finishing, or
resuming, and updating a grave after a second, confirming click. Conversation
and request IDs are created before the request and reused on retry, so a lost
response never runs a turn or an update twice. Remote text is shown as plain
text only.

Discovery, summaries, conversations, last-known state, and graph samples stay
in Quickshell memory and disappear with the shell process. The plugin has no
registry, on-disk history, daemon, listener, or bundled Gravedecay server.
Dashboard, T3, Terminal, Network, and T3 thread buttons open only validated
tailnet HTTPS or same-host paths supplied by the appliance responses.

The plugin update check runs `git fetch` in the plugin's own checkout every six
hours (disable with `updateChecks`). It never applies anything by itself.

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
| `g` | Talk to the selected grave's Gravekeeper |
| `r` | Refresh discovery |
| Escape | Close the panel, or leave a conversation |

Select the Gravekeeper or a digger to open its conversation. The picker at the
top switches between recent conversations and a new one. Enter sends; Escape
leaves the message field, and Escape again returns to the overview. A turn
keeps being followed while the panel is closed, and with notifications on you
hear when it settles. Digger prompt chips fill the message field for editing.

Under **Grave update**, a grave behind its newest release offers **Update
grave to vX.Y.Z**; a grave on a branch or commit offers **Switch grave to
release vX.Y.Z**. Both ask for a second click, then follow the grave's updater
while its dashboard restarts.

## Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| `refreshIntervalSec` | `45` | Background discovery interval |
| `historySamples` | `60` | Samples retained per appliance in memory |
| `desktopEntry` | `gravedecay.desktop` | Installed dashboard PWA; empty means browser only |
| `notificationsEnabled` | `false` | Notify on health changes, T3 attention, digger approvals, Keeper answers, and grave updates |
| `updateChecks` | `true` | Check the plugin's git origin for updates every six hours |

## Validation

```sh
omarchy plugin validate .
node tests/model.test.js
bash tests/api.test.sh
```

The model test runs anywhere Node is available; the API test checks the
helper's refusals without network access. The Omarchy/Quickshell runtime
requires an Omarchy desktop and is not validated on non-Omarchy hosts.

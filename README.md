# HerdEye

![HerdEye in action](assets/herdeyevideo.gif)

A small macOS menu bar app for monitoring [herdr](https://github.com/ogulcancelik/herdr) agent status.

HerdEye watches the agents running inside your herdr sessions and shows their
status as a compact dot grid in the menu bar — so you can tell, at a glance,
which agents are working, blocked, done, or idle without switching windows.

It runs as a background-only app (no Dock icon, no window) and needs no
HerdEye-specific configuration on the herdr side: it just connects to the
standard herdr socket.

## Features

- **Menu bar dot grid.** Up to nine agents are summarized as a 3×3 grid (a 2×2
  grid when four or fewer agents exist). Each dot's shape, fill, and color
  reflect that agent's state.
- **State prioritization.** Active agents are surfaced first. The grid fills
  top-left first by priority `blocked > working > done > idle > unknown`, so the
  dots that need your attention are always in the same place.
- **Click-to-expand popover.** Clicking the menu bar item opens a popover with
  the full agent list — workspace name, agent name and pane number, and current
  state — plus a live connection indicator (`Live`, `Connecting`, `Reconnect #n`).
- **Customizable appearance.** The shape (circle/square), outline, and fill color
  for each state are adjustable in Settings and persist across launches.
- **Robust connection.** HerdEye tracks pane lifetimes, re-subscribes when the
  set of known panes changes, and reconnects with backoff if herdr restarts.

### Agent states and default appearance

HerdEye mirrors herdr's reported states without custom interpretation.

| State   | Meaning                              | Default dot          |
| ------- | ------------------------------------ | -------------------- |
| blocked | Agent is waiting for input/attention | Filled red square    |
| working | Agent is actively running            | Filled blue square   |
| done    | Agent finished its turn              | Filled green square  |
| idle    | Agent is waiting idle                | Gray circle outline  |
| unknown | State could not be determined        | Gray circle outline  |

<img src="assets/herdeyestate.png" width="560" alt="Menu bar dot grid legend">

## How it works

HerdEye connects to the herdr Unix-domain socket
(`~/.config/herdr/herdr.sock`) over a line-delimited JSON protocol:

1. On connect it subscribes to events and fetches a snapshot of the current
   panes and workspaces to seed the agent list.
2. It then streams `pane.agent_status_changed`, `pane.agent_detected`,
   `pane.closed`, `pane.moved`, and workspace lifecycle events to keep the list live.
3. Because `events.subscribe` can only be sent once per connection, HerdEye
   reconnects whenever the set of known panes changes, batching rapid changes
   to avoid churn.

Only panes with a detected agent are tracked; transient herdr UI helper panes
are ignored. The communication and state-reduction logic is split into pure,
independently tested functions (see `HerdEye/Store/PastureReducer.swift`).

## Install

Install HerdEye with Homebrew:

```sh
brew tap shogoisaji/herdeye
brew trust --cask shogoisaji/herdeye/herdeye
brew install --cask herdeye
```

HerdEye is distributed as a Developer ID-signed and notarized app. The
`brew trust` command trusts only the HerdEye cask in this tap.

To upgrade an existing installation:

```sh
brew update
brew upgrade --cask herdeye
```

## Usage

1. Start herdr normally and let it expose its standard socket. No extra setup
   is needed.
2. Launch HerdEye. It appears as a dot grid in the menu bar and begins
   connecting automatically.
3. Glance at the menu bar to monitor your agents:
   - While connecting, slots appear as empty gray outlines.
   - Once live, each dot reflects an agent's state.
   - If you have more than nine agents, the popover notes how many were hidden
     (lower-priority states are dropped first).
4. **Click** the menu bar item to open the popover and see the full list, open
   Settings (gear icon), or quit HerdEye.
5. **Settings → Dot Appearance** lets you change the shape, outline, and fill
   color for each state and reset to defaults.

> HerdEye is a background-only app. To quit it, use the **Quit HerdEye** button
> in the popover.

## Requirements

- macOS 26 or later
- herdr

No HerdEye-specific configuration is required on the herdr side. HerdEye works
when herdr exposes its standard socket.

## Development

HerdEye uses XcodeGen to generate its Xcode project. Install XcodeGen and run
the tests with:

```sh
brew install xcodegen
xcodegen generate
swift test --no-parallel
```

## License

MIT License. See [LICENSE](LICENSE) for details.

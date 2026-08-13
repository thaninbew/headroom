# Headroom

Headroom is a native macOS quota reserve for Codex. Set aside 10% of each
reported Codex usage window, then let lifecycle hooks stop the next controllable
step when either window reaches 90% used.

Headroom is event-driven. It checks only when a prompt is submitted, a tool has
finished, or you press Refresh in the menu-bar app.
There is no background polling, usage prediction, credential scraping, or
provider proxy.

Parallel hook events are coalesced for two seconds behind a local file lock, so
one tool batch produces one meter request rather than one request per tool.

> [!IMPORTANT]
> Codex reports integer usage percentages after work has happened. Headroom
> stops at the first hook boundary where the official meter reports 10% or less
> remaining. It cannot stop a response already in flight or prevent another
> device from consuming the same account quota.

## What ships

- `Headroom`: a small SwiftUI menu-bar app for reading the meter and editing the
  reserve.
- `headroom-hook`: the command Codex lifecycle hooks invoke.
- `HeadroomCore`: the shared policy, configuration, hook protocol, and Codex
  app-server client.
- `headroomctl install`: an explicit installer that adds the two hook entries.
- `headroomctl uninstall`: a scoped remover that deletes only Headroom's entries.

The app never installs hooks merely by being launched.

## Requirements

- macOS 14 or later
- Codex CLI 0.146.0 or later on `PATH`
- A ChatGPT-backed Codex login
- Swift 6.2 or later to build from source

## Build without applying

```sh
swift build -c release
swift test
```

The products are placed under `.build/release/`. Building and running tests do
not modify `~/.codex`.

## Install

Installation is intentionally separate from building:

```sh
.build/release/headroomctl install
```

The installer copies both executables to `~/Library/Application Support/Headroom/bin/`
and merges Headroom's handlers into `~/.codex/hooks.json`, preserving unrelated
hooks. Codex may ask you to trust newly discovered local hooks.

To remove only Headroom's hooks and installed binaries:

```sh
~/Library/Application\ Support/Headroom/bin/headroomctl uninstall
```

## Hook behavior

| Boundary | Protected response |
| --- | --- |
| `UserPromptSubmit` | Blocks the prompt before a model request begins |
| `PostToolUse` | Returns `continue:false` before the next model request |

Headroom intentionally does not install a `PreToolUse` hook. Codex turns a
pre-tool denial into model feedback, which can start another quota-consuming
response. Allowing the tool to finish and stopping at `PostToolUse` is the first
stable hook boundary that prevents another model request.

On any meter or process failure, Headroom fails open. The menu app shows the
error, while Codex remains usable.

## Configuration

Headroom stores its small JSON configuration at:

```text
~/Library/Application Support/Headroom/config.json
```

Defaults:

```json
{
  "enabled": true,
  "reservePercent": 10
}
```

Both primary and secondary rate-limit windows are protected. A missing window
is ignored. The check blocks when `usedPercent >= 100 - reservePercent`.

## Privacy

Headroom launches the locally installed `codex app-server --stdio`, performs
the documented `account/rateLimits/read` RPC, and exits. Authentication remains
owned by Codex. Headroom never reads `~/.codex/auth.json` and sends no analytics.

## License

[MIT](LICENSE)

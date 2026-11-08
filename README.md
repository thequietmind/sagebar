# SageBar

Claude, Codex, and Grok usage in your Mac’s menu bar.

A native Swift app with compact percentages, provider-specific usage windows,
reset countdowns, and a quiet dropdown. Requires macOS 14 or later. No package
dependencies, analytics, or SageBar account.

## Build and run

Install Xcode or the Xcode Command Line Tools, then run:

~~~~~sh
bash Scripts/build-app.sh
open build/SageBar.app
~~~~~

The build targets your Mac’s architecture. To install, quit SageBar and copy the
build into Applications, then enable Launch at Login from that copy:

~~~~~sh
SAGEBAR_SIGN_IDENTITY="Apple Development" bash Scripts/build-app.sh
ditto build/SageBar.app /Applications/SageBar.app
open /Applications/SageBar.app
~~~~~

Without `SAGEBAR_SIGN_IDENTITY`, builds use ad-hoc signing, which runs fine on the
Mac that built it but looks like a new app to Keychain after every rebuild, so
macOS asks again for the saved Claude and Grok sessions. Signing with an Apple
Development certificate keeps that identity stable, so **Always Allow** sticks.
Copies shared with other Macs would need Developer ID signing and notarization;
this project does not publish or notarize a release yet.

## Connect providers

Codex uses the installed CLI’s documented `account/rateLimits/read` interface and
your existing sign-in. It does not start a chat or spend model tokens. Supported
CLI locations are Homebrew, `/usr/local/bin`, `~/.local/bin`, and the Codex Desktop
bundle. The read request starts a temporary app-server process, then stops it.

For Claude, open Settings and paste a `sessionKey` from claude.ai’s browser
storage or a Cookie request header from the usage page. SageBar stores the
session in macOS Keychain. Disconnect removes SageBar’s saved session.
Expired sessions need to be replaced in Settings.

Grok is off by default. Turn it on in Settings, then paste the Cookie request
header from any grok.com request (copied from your browser’s developer tools).
SageBar reads the shared weekly pool that grok.com’s Settings → Usage tab shows,
from `grok.com/rest/grok/credits`; per-product shares are a breakdown of that pool,
not separate limits. Saving a Claude or Grok session turns that provider on.

Claude’s and Grok’s web usage endpoints are undocumented and may change. The app
sends each saved session only to its own site (`claude.ai` or `grok.com`), rejects
redirects to other hosts, and does not log or store response bodies. Codex handles its own credentials; SageBar
does not read or copy Codex access tokens. Rebuilding an ad-hoc-signed app may
cause Keychain to ask for access again.

## Reading the display

The menu bar shows each provider’s logo beside its percentage. Percentages mean **used**
by default; Settings can switch to remaining capacity. **Menu bar shows** can swap
each percentage for a small fill bar that follows the same used or remaining choice;
the tooltip keeps the exact numbers. Bars are monochrome by default; **Color bars by
usage** fills them green below 70% used, yellow from 70%, and red from 90%, even
when showing remaining capacity. Choose which of Claude, Codex, and Grok
appear in Settings. Disabled providers disappear from the menu bar and dropdown,
and stop refreshing; saved connections are retained. At least one stays enabled.

Turn on **Show reset countdowns** to add a reset icon and compact time such as
`3d4h` after each percentage. With bars, the time sits beneath each bar instead,
keeping the menu bar narrow. Countdowns are off by default, use the same usage
window as the percentage, and show `due` when a fresh reading is needed.
Each provider’s primary window appears in the menu bar. The dropdown names its actual duration—Codex’s
primary window is not always five hours—and displays additional returned limits.
Claude’s Fable weekly limit stays hidden unless **Show Fable weekly limit** is on
in Settings.

The window button beside Settings in the dropdown opens the same dashboard in a
standalone window that stays open while you work; SageBar remembers where you put it.
Once popped out, clicking the menu bar item shows and hides that window instead of the
dropdown (bringing it forward if it's covered or minimized). Closing the window with
its close button returns the menu bar item to the dropdown.

A dash means the current reading is unavailable or stale. Last successful
readings remain visibly marked in the dropdown after a refresh error. A reset
countdown reaching zero does not manufacture a fresh quota; the next read
confirms it. Provider restrictions are shown separately from percentages.

## Development

~~~~~sh
swift build
swift test
swift run SageBar --check-codex
open build/SageBar.app --args --demo --preview
build/SageBar.app/Contents/MacOS/SageBar --render-preview /tmp/sagebar-preview.png
build/SageBar.app/Contents/MacOS/SageBar --render-menu-bar /tmp/sagebar-menu-bar.png
~~~~~

`--render-menu-bar` draws every menu bar style in light and dark from synthetic
readings, for comparing layouts without changing your settings.

`--check-codex` makes a live, read-only limit request and prints only percentages
and reset descriptions. `--demo --preview` uses synthetic readings and makes no
provider requests. The regular app does not scan conversation logs.

Core parser tests cover both Claude response formats, Codex window durations,
monthly credits, restrictions, Grok credit periods and legacy billing, empty
responses, reset boundaries, and session header validation. No lint command has
been configured.

## Project status

This is an initial local build. Public distribution, automatic updates, provider
notifications, and a project license have not been configured. An open-source
license should be chosen before publishing.

The bundled Claude and Codex icons come from those desktop apps’ monochrome menu
bar assets; the Grok icon is rendered from the mark in grok.com’s site logo.
Claude, Codex, and Grok marks belong to their respective owners and identify the
services connected to SageBar.

Protocol reference: [Codex App Server](https://learn.chatgpt.com/docs/app-server).

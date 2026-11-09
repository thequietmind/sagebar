# Security

SageBar holds website sessions for Claude and Grok, so please report anything that could expose them,
send them to the wrong host, or let another app read them.

Report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/thequietmind/sagebar/security/advisories/new)
rather than a public issue. Include the SageBar version (Settings shows it), your macOS version, and steps
to reproduce. You can expect an acknowledgement within a week.

## How SageBar handles credentials

- Pasted sessions are stored only in the macOS Keychain, one item per provider, readable when the Mac is
  unlocked and never synced to other devices.
- Each session is sent only to its own site, `claude.ai` or `grok.com`, over HTTPS. Redirects to any other
  host are refused, and responses are neither logged nor written to disk.
- Codex is read through the installed Codex CLI, which manages its own sign-in. SageBar never reads or
  copies Codex tokens.
- SageBar has no server, account, analytics, or crash reporting.

Only the latest release receives security fixes.

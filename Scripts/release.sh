#!/bin/bash
# Builds a universal SageBar.app signed with Developer ID, notarizes and staples it, and writes
# build/SageBar-<VERSION>.zip for a GitHub release. One-time setup, which stores an app-specific
# password in your Keychain:
#   xcrun notarytool store-credentials sagebar --apple-id <Apple ID> --team-id <team ID>
# Optional environment:
#   SAGEBAR_SIGN_IDENTITY   Developer ID Application identity; the only one in your Keychain when unset
#   SAGEBAR_NOTARY_PROFILE  notarytool Keychain profile; "sagebar" when unset
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
identity="${SAGEBAR_SIGN_IDENTITY:-Developer ID Application}"
profile="${SAGEBAR_NOTARY_PROFILE:-sagebar}"
version="$(<VERSION)"
app="build/SageBar.app"
archive="build/SageBar-$version.zip"

SAGEBAR_SIGN_IDENTITY="$identity" SAGEBAR_UNIVERSAL=1 bash Scripts/build-app.sh

# Leave out extended attributes such as com.apple.provenance: ditto would store them as ._ files,
# which unzip and other non-Apple tools extract into the bundle, breaking its signature.
zip_flags=(-c -k --norsrc --noextattr --keepParent)
rm -f "$archive"
ditto "${zip_flags[@]}" "$app" "$archive"
printf 'Submitting %s for notarization...\n' "$archive"
result="$(xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait --output-format json)"
status="$(plutil -extract status raw -o - - <<< "$result")"
if [[ "$status" != Accepted ]]; then
    submission="$(plutil -extract id raw -o - - <<< "$result")"
    xcrun notarytool log "$submission" --keychain-profile "$profile" >&2
    printf 'Notarization finished with status %s.\n' "$status" >&2
    exit 1
fi

# Staple the ticket so Gatekeeper can verify the app offline, then zip the stapled copy.
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"
rm "$archive"
ditto "${zip_flags[@]}" "$app" "$archive"
shasum -a 256 "$archive"
printf 'Ready to upload: %s\n' "$archive"

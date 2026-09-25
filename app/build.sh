#!/bin/zsh
set -eu
cd "${0:A:h}/.."
destination="$PWD/dist/Renamer.app"
signing_dir="$HOME/Library/Application Support/Renamer/Signing"
identity_file="$signing_dir/identity.sha1"
if [[ ! -s "$identity_file" ]]; then
  print -u2 'Missing stable signing identity. Run zsh app/setup-signing.sh once before building.'
  exit 1
fi
signing_identity=$(tr -d '\n\r' < "$identity_file")
if [[ ! "$signing_identity" =~ '^[0-9A-Fa-f]{40}$' ]]; then
  print -u2 'Invalid signing identity; refusing to fall back to ad-hoc signing.'
  exit 1
fi
mkdir -p "$PWD/dist"
build_dir=$(mktemp -d "$PWD/dist/.renamer-build.XXXXXX")
app_bundle="$build_dir/Renamer.app"
trap 'rm -rf "$build_dir"' EXIT
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
swiftc -swift-version 5 -O -module-cache-path /private/tmp/renamer-swift-cache \
  -target arm64-apple-macosx14.0 app/Sources/*.swift \
  -o "$app_bundle/Contents/MacOS/Renamer"
cp app/Info.plist "$app_bundle/Contents/Info.plist"
cp app/THIRD_PARTY_NOTICES.txt "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.txt"
codesign --force --sign "$signing_identity" \
  --keychain "$HOME/Library/Keychains/login.keychain-db" --timestamp=none \
  --identifier dev.local.renamer \
  --requirements "=designated => identifier \"dev.local.renamer\" and certificate leaf = H\"$signing_identity\"" \
  "$app_bundle"
codesign --verify --strict "$app_bundle"
codesign --verify -R "=identifier \"dev.local.renamer\" and certificate leaf = H\"$signing_identity\"" "$app_bundle"
# Keep the installed app intact until compilation and signing both pass.
if [[ -e "$destination" ]]; then mv "$destination" "$build_dir/previous.app"; fi
if ! mv "$app_bundle" "$destination"; then
  if [[ -e "$build_dir/previous.app" ]]; then mv "$build_dir/previous.app" "$destination"; fi
  exit 1
fi
print "Built: $destination"

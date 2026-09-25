#!/bin/zsh
# Two different executables must satisfy the same certificate-bound identity.
set -eu
signing_dir="$HOME/Library/Application Support/Renamer/Signing"
identity=$(tr -d '\n\r' < "$signing_dir/identity.sha1")
requirement="identifier \"dev.local.renamer\" and certificate leaf = H\"$identity\""
temp_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/renamer-signature-check.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
for version in 1 2; do
  print "int main(void) { return $version; }" > "$temp_dir/probe.c"
  clang "$temp_dir/probe.c" -o "$temp_dir/probe-$version"
  codesign --force --sign "$identity" --keychain "$HOME/Library/Keychains/login.keychain-db" \
    --timestamp=none --identifier dev.local.renamer --requirements "=designated => $requirement" "$temp_dir/probe-$version"
  codesign --verify --strict -R "=$requirement" "$temp_dir/probe-$version"
  codesign -d -r- "$temp_dir/probe-$version" 2>/dev/null > "$temp_dir/requirement-$version"
done
[[ -s "$temp_dir/requirement-1" ]]
cmp "$temp_dir/requirement-1" "$temp_dir/requirement-2"
cp "$temp_dir/probe-2" "$temp_dir/unrelated"
codesign --force --sign - --identifier dev.local.renamer "$temp_dir/unrelated"
if codesign --verify -R "=$requirement" "$temp_dir/unrelated" 2>/dev/null; then
  print -u2 'FAIL: an unrelated ad-hoc signature matched the identity.'
  exit 1
fi
print 'PASS: two different builds satisfy the same certificate-bound signing identity.'

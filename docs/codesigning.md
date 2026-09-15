# Why Boost has a local signing identity

`build.sh` used to sign with `codesign --sign -` (ad-hoc). Ad-hoc signing has
no certificate behind it, so macOS ties TCC grants (Accessibility, in
particular — that's what lets `WindowWatcher` see other apps' windows) to the
exact compiled bytes. Every rebuild produces different bytes, so every
rebuild silently orphaned the Accessibility grant and auto-quit-on-close
stopped working with no error anywhere.

## The fix

A self-signed certificate, created once on 15 Sep 2026, imported into the
login keychain and trusted for code signing:

```bash
CN="Boost Local Dev"
openssl req -x509 -newkey rsa:2048 -keyout boost.key -out boost.crt \
  -days 3650 -nodes -subj "/CN=$CN" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

openssl pkcs12 -export -out boost.p12 -inkey boost.key -in boost.crt -passout pass:boost

security import boost.p12 -k ~/Library/Keychains/login.keychain-db -P boost -T /usr/bin/codesign -A

# needed for `codesign` to treat it as a valid identity — without this it
# imports fine but codesign silently falls back to ad-hoc
security find-certificate -c "$CN" -p ~/Library/Keychains/login.keychain-db > boost.pem
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db boost.pem

rm boost.key boost.p12 boost.crt boost.pem   # private key only needs to exist in the keychain
```

`build.sh` now signs with `--sign "Boost Local Dev"` instead of `--sign -`.
TCC ties the grant to the certificate's public key, which is the same on
every build — so Accessibility only needs to be granted once, ever, per
machine.

## If this machine's keychain is ever rebuilt

The identity lives only in `~/Library/Keychains/login.keychain-db`. A fresh
macOS install, a new user account, or deleting that keychain means redoing
the steps above once, then re-granting Accessibility one more time.
`build.sh` detects the missing identity and falls back to ad-hoc with a
warning rather than failing the build.

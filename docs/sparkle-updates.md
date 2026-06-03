# Sparkle Updates

Limit Bar integrates Sparkle 2.9.2 through the official Sparkle Swift Package Manager binary release zip, vendored at `Vendor/Sparkle/Sparkle.xcframework`.

## Required Release Settings

These target build settings are configured for GitHub Releases:

- `SPARKLE_FEED_URL`: `https://github.com/artemsvit/Limit-Bar/releases/latest/download/appcast.xml`
- `SPARKLE_PUBLIC_ED_KEY`: `96VpvrwjTO2r7k7pmBJdFzPVvDeYPbO+uXpPqEuoXzU=`

`Config/LimitBar-Info.plist` maps them into:

- `SUFeedURL`
- `SUPublicEDKey`

Sparkle is started only when both values are present in the built app.

## One-Time Signing Key

From a Sparkle distribution, run:

```sh
Vendor/Sparkle/bin/generate_keys --account limit-bar
```

Keep the private key safe in Keychain. Put the printed public key into `SPARKLE_PUBLIC_ED_KEY`.

For GitHub Actions or another CI system, export the private key and store it as a secret named `SPARKLE_PRIVATE_KEY`:

```sh
Vendor/Sparkle/bin/generate_keys --account limit-bar -x /tmp/limit-bar-sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY --repo artemsvit/Limit-Bar < /tmp/limit-bar-sparkle-private-key
rm /tmp/limit-bar-sparkle-private-key
```

## Publishing

Publish a GitHub Release and appcast from this Mac:

```sh
scripts/publish-release.sh 1.0.1 2
```

The script:

1. Archives the app.
2. Zips `Limit Bar.app`.
3. Generates a signed `appcast.xml`.
4. Creates a GitHub Release with the zip and appcast assets.

Sparkle compares versions with `CFBundleVersion`, currently sourced from `CURRENT_PROJECT_VERSION`.

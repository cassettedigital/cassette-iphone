# Cassette for iPhone

The iPhone app of [Cassette](https://www.cassette.digital). It plays the music on your own computer,
carries the albums you choose, and plays them with or without signal.

This is an open source fork of [Amperfy](https://github.com/BLeeEZ/amperfy) by Maximilian Bauer, under
the GNU General Public License v3 (see [LICENSE](LICENSE)). Amperfy's own README is kept as
[README-Amperfy.md](README-Amperfy.md).

## Where things are

- `integration` is Cassette's branch. Every build that ships is tagged `cassette-ios-<version>-<build>`,
  and the app's About > Source code opens the tag for the build you have.
- Cassette's own code is mostly in `AmperfyKit/Cassette` and `Amperfy/SwiftUI`.
- `AmperfyKit/Cassette/CassetteKitTokens.swift` (colours, sizes, type and the picture sizes) is generated,
  not written. Its source is `CassetteKit/tokens.json`, and `CassetteKit/generate.mjs` is the generator,
  copied here verbatim from Cassette's design kit. It runs in Cassette's own repository, where it also
  writes the website's and the Android app's copies; here it shows exactly how each value is made.

## Building

Xcode 26 or later:

```sh
xcodebuild -project Amperfy.xcodeproj -scheme Amperfy -destination 'generic/platform=iOS' build
```

The app works with Cassette's service at cassette.digital and the Cassette app on your computer.

## Tagging a shipped build

```sh
BuildTools/tag-shipped-build.sh <version> <build> [commit]
git push origin cassette-ios-<version>-<build>
```

## License

GNU General Public License v3. Amperfy: Copyright © 2019-2026 Maximilian Bauer. Changes for Cassette:
Copyright © 2026 the Cassette authors. This program comes with ABSOLUTELY NO WARRANTY. Third-party
notices are in the app's About screen and in `Amperfy/SwiftUI/Settings/LicenseSettingsView.swift`.

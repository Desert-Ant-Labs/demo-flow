# Releasing Flow

A release of Desert Ant Flow is a notarized disk image, a Sparkle appcast signed with the Desert Ant update key, a GitHub release, and a Homebrew cask. Run the release on the Mac that has the signing keys.

Steps marked **Maintainer** need a maintainer's go-ahead, because each one is public or hard to undo.

## Setup

You need these on the Mac:

- Xcode 26 or later, on Apple Silicon.
- [mise](https://mise.jdx.dev). Run `mise install` once in the repo to install xcodegen and dmgbuild.
- A Developer ID Application certificate in the login keychain. `security find-identity -v -p codesigning | grep "Developer ID Application"` prints its name.
- A notary profile, made with `xcrun notarytool store-credentials`. If `xcrun notarytool history --keychain-profile <name>` fails, ask a maintainer for the profile's name.
- The Sparkle EdDSA key in the login keychain, under the account `desert-ant-labs`. The redactor uses the same key, and its public half is `SUPublicEDKey` in `project.yml`. Never print, copy, or commit the private key.
- `gh`, logged in with push rights to `Desert-Ant-Labs/demo-flow` and `Desert-Ant-Labs/homebrew-tap`.

Put the certificate name and the profile name in `mise.local.toml`, which git ignores. `mise run package` reads them from there. For example:

```toml
[env]
FLOW_SIGNING_IDENTITY = "Developer ID Application: Desert Ant Labs B.V. (TEAMID)"
NOTARY_PROFILE = "<profile name>"
```

## Steps

1. Set `CFBundleShortVersionString` in `project.yml` to the new version, and raise `CFBundleVersion` by one. Sparkle compares build numbers, so an installed copy only updates when the build number goes up.
2. Run the tests with the real models:

   ```bash
   FLOW_MODEL_TESTS=1 mise run test
   ```

   Every test must pass. The first run downloads 800MB of models from Hugging Face.
3. Build the release:

   ```bash
   mise run package
   ```

   The script builds the app, signs it with the Developer ID, notarizes and staples it, and builds the disk image. It writes three files into `dist/`:
   - `Desert-Ant-Flow-<version>.dmg`
   - `appcast.xml`, signed with the Sparkle key
   - `desert-ant-flow.rb`, the Homebrew cask with the disk image's checksum

   The last lines show whether Gatekeeper accepts the app. Go on only if they say `accepted`.
4. Check that the app inside the disk image is notarized:

   ```bash
   hdiutil attach "dist/Desert-Ant-Flow-<version>.dmg"
   xcrun stapler validate "/Volumes/Desert Ant Flow/Desert Ant Flow.app"
   ```

   `stapler` prints `The validate action worked!`.
5. Check `dist/appcast.xml`. It has one `<item>`, with `sparkle:version` set to the build number, a `sparkle:edSignature`, and this download URL: `https://github.com/Desert-Ant-Labs/demo-flow/releases/download/v<version>/Desert-Ant-Flow-<version>.dmg`.
6. Drag the app from the disk image to Applications and open it. The app opens without a warning, About shows the new version, and Acknowledgements in About lists the licenses.
7. **Maintainer:** for the first release only, make the repo public. Sparkle and Homebrew download without logging in to GitHub, so the release has to be public:

   ```bash
   gh repo edit Desert-Ant-Labs/demo-flow --visibility public --accept-visibility-change-consequences
   ```

8. **Maintainer:** publish the release. The tag must be `v<version>`, because the appcast's download URL uses that tag:

   ```bash
   gh release create v<version> \
     "dist/Desert-Ant-Flow-<version>.dmg" dist/appcast.xml \
     -R Desert-Ant-Labs/demo-flow --title "Desert Ant Flow <version>" --notes-file <notes>
   ```

   Every installed copy reads `releases/latest/download/appcast.xml`, so each new release must include its own appcast.
9. Check the release from outside GitHub:

   ```bash
   curl -sIL https://github.com/Desert-Ant-Labs/demo-flow/releases/latest/download/appcast.xml | grep -E "^HTTP"
   curl -sIL "https://github.com/Desert-Ant-Labs/demo-flow/releases/download/v<version>/Desert-Ant-Flow-<version>.dmg" | grep -E "^HTTP"
   ```

   The last line of each must be `200`.
10. **Maintainer:** add the cask to Homebrew. `homebrew-tap` is a public repo. Copy `dist/desert-ant-flow.rb` to `Casks/desert-ant-flow.rb` on a branch of `Desert-Ant-Labs/homebrew-tap`, and open a PR. Once the PR merges, run `brew install --cask desert-ant-flow` and check that the app opens.

## Release notes

Write release notes in plain sentences, with no em dashes, no hype words, and no exclamation marks. The notes for 0.0.2:

```markdown
Desert Ant Flow 0.0.2 adds the Ask step and shows results beside the flow.

- The Ask step pauses a flow until you answer: Yes or No, unticking the items a model got wrong, choosing from a few answers, or typing one. A flow that runs on its own asks in the floater and in a notification, and can go on with an answer you set once it has waited long enough.
- Show Results (Command-3) opens the results beside the flow: photos as a wall you can filter by label, tables you can sort and copy, scores as a chart, and text set for reading. Export them all at once as a PDF, as Markdown, or as a folder with each result in its own file.
- Wires on the canvas are smooth curves in the color of what they carry. Hover a wire to see what flows along it, and watch values move along the wires while a flow runs.
```

## Fixing a bad release

If a published release turns out broken, delete the release and its tag, fix the problem, and release again with the next build number:

```bash
gh release delete v<version> --cleanup-tag -R Desert-Ant-Labs/demo-flow
```

Never replace the files of a release that people may have downloaded already. Sparkle checks every download against the appcast's signature.

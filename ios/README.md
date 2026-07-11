# Native iOS client

The native client uses the same Cloudflare Access, SSE, and `/control` protocol as
the remote PWA.

## Generate and test

```bash
brew install xcodegen
cd ios
xcodegen generate
xcodebuild \
  -project CopilotProjects.xcodeproj \
  -scheme CopilotProjects \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The bundle ID is `com.sirfergy.copilotprojects`. Debug builds register APNs
sandbox tokens; TestFlight/App Store builds register production tokens.

## Xcode Cloud

The generated Xcode project remains ignored. Xcode Cloud runs
`ci_scripts/ci_post_clone.sh` to install XcodeGen, generate the project, and
replace `CURRENT_PROJECT_VERSION` with its unique `CI_BUILD_NUMBER`.

## Configure the Mac APNs provider

Create one Apple Developer key with **Apple Push Notifications service (APNs)**
enabled for **Sandbox & Production**, download it once, then run:

```bash
swift ../scripts/import-apns-key.swift \
  ~/Downloads/AuthKey_<KEY_ID>.p8 \
  <KEY_ID> \
  M32S59L6U6 \
  com.sirfergy.copilotprojects
rm ~/Downloads/AuthKey_<KEY_ID>.p8
```

The private key is stored in the macOS Keychain. Device tokens are stored under
the private Copilot Projects state directory and are registered through the
Cloudflare-authenticated `/apns/subscribe` route.

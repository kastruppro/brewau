# App Management for brewau

The brewau menu bar app can retry app protection that macOS deferred during a
scheduled cask update. Give the signed brewau app App Management permission on
the Mac or through MDM.

## MDM configuration profile

Upload [brewau-app-management.mobileconfig](brewau-app-management.mobileconfig)
as a custom profile and assign it on the device channel of a Mac with
user-approved MDM. The primary `SystemPolicyAppBundles` entry matches the
app's bundle ID `com.kastruppro.brewau.app` and team `5W98EXLE44`.
The profile also includes the standalone agent at
`/opt/brewau/libexec/brewau-agent`. That entry may let the daemon protect apps
at night without the menu bar app. Daemon authorization is unverified.
[Apple’s PPPC documentation](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol)

Check the identifiers and team against the installed Developer ID binaries.

```sh
codesign -dr - /Applications/brewau.app
codesign -dr - /opt/brewau/libexec/brewau-agent
```

## Declarative device management

[brewau-app-management.ddm.json](brewau-app-management.ddm.json) contains two
example declarations for the device channel. Replace the placeholder
`ProfileURL` with the HTTPS URL serving the profile on your MDM service.
Publish the `com.apple.configuration.legacy` configuration and the
`com.apple.activation.simple` activation as separate declarations. The
activation’s `StandardConfigurations` array references the configuration’s
identifier.

On macOS 27 or later, you can use `ProfileAssetReference` in place of
`ProfileURL`. Set it to the identifier of a `com.apple.asset.data` declaration
that references the profile plist and declares the matching content type.
DDM delivery is untested. [Apple’s legacy profile documentation](https://developer.apple.com/documentation/devicemanagement/legacyprofile)

## Manual grant

1. Open **System Settings > Privacy & Security > App Management** and click **+**.
2. Select **brewau.app** in Applications and enable its App Management switch.
3. Open brewau to retry pending protections. Casks deferred before upgrade can
   upgrade on the next run once protection succeeds.

If Homebrew itself could not upgrade a cask, resolve the Homebrew error and
choose **Prøv igen** in brewau or run `sudo brewau clear-blocked`.

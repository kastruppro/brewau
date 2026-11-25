# App Management for brewau

macOS checks App Management for the standalone agent at
`/opt/brewau/libexec/brewau-agent` when the scheduled job updates cask apps in
`/Applications`. Grant the agent App Management through MDM or System Settings.

## MDM configuration profile

Upload [brewau-app-management.mobileconfig](brewau-app-management.mobileconfig)
as a custom profile and assign it on the device channel of a Mac with
user-approved MDM. It grants `SystemPolicyAppBundles` to the agent at its
installed path when the binary matches the code requirement. [Apple’s PPPC documentation](https://developer.apple.com/documentation/devicemanagement/privacypreferencespolicycontrol)

The signed agent
must use the identifier `com.kastruppro.brewau.agent` and an Apple-issued
certificate for team `5W98EXLE44`. Inspect the installed binary’s designated
requirement and confirm the identifier and team match the profile.

```sh
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

macOS 26.1 and 26.2 cannot add standalone executables in System Settings.
Update to macOS 26.3 or later, or use the MDM profile on managed Macs. The
manual steps below also work on earlier releases such as macOS 15.
[Apple Developer Technical Support](https://developer.apple.com/forums/thread/813989)

1. Open **System Settings > Privacy & Security > App Management** and click **+**.
2. Press **Command-Shift-G**, enter `/opt/brewau/libexec/brewau-agent`, and add
   the executable. Turn on its App Management switch.

After either grant, choose **Prøv igen** in brewau or run
`sudo brewau clear-blocked` to retry previously blocked casks on the next run.

# Updater rules

Onglai keeps verified update-source mappings in [`Pearcleaner/Resources/updater-rules.json`](../Pearcleaner/Resources/updater-rules.json). The app bundles this document and can refresh it from the same file on this repository's `main` branch.

The first release that includes this loader must be installed before remote rules can take effect. After that, adding a source that uses an existing adapter only requires a JSON change with a higher `revision`. A new protocol, parser, channel policy, version format, or schema requires an app update.

## Loading and fallback

- The app starts with the bundled document or a valid cached document with a higher revision.
- Refresh attempts are limited to once every six hours, including failed attempts. The last attempt time is retained across app launches. An explicit forced refresh can bypass the interval; simultaneous requests share one refresh.
- A request uses a five-second timeout and accepts at most 256 KiB. Only a successful response from the configured repository URL is considered.
- The entire document must pass validation. Unknown schemas, adapters, version formats, invalid fields, duplicate identities, and unsafe URLs reject the document.
- Only a strictly higher revision replaces the current rules and is cached. An offline connection, missing file, invalid document, or older revision keeps the bundled or last valid cached rules.

The rules are configuration data delivered over HTTPS from this repository. They do not contain executable code and cannot add parsers. Existing update verification, including Sparkle's installed public-key checks, still applies.

## Document fields

The root object has five required fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Must be `1` for this app version. |
| `revision` | A positive integer. Increase it whenever published rules change. |
| `sparkleFeeds` | Exact bundle identifiers and verified Sparkle feed URLs. |
| `officialSources` | Exact bundle identifiers and existing official-source adapters. |
| `catalogVersions` | Exact Homebrew cask token and bundle-identifier pairs with known version formats. |

An empty array is valid. Bundle identifiers are case-sensitive and must be exact identifiers, without wildcards. A bundle identifier can occur once in each of `sparkleFeeds` and `officialSources`; a cask token and bundle-identifier pair can occur once in `catalogVersions`.

Every feed, endpoint, and landing page must use HTTPS with a named public host. Credentials, URL fragments, IP literals, local-network host names, and nonstandard ports are rejected. Endpoint placeholders are allowed only outside the host.

### Sparkle feeds

```json
{
  "bundleIdentifier": "dev.kdrag0n.MacVirt",
  "feedURL": "https://api-updates.orbstack.dev/arm64/appcast.xml?bucket=",
  "architectures": ["arm64"]
}
```

`architectures` is optional. If present, it must be a nonempty, unique list containing only `arm64` or `x86_64`. An architecture-specific feed is not used for another architecture. A valid `SUFeedURL` supplied by the installed app remains authoritative.

### Official sources

Each rule requires `bundleIdentifier`, `kind`, `endpointTemplate`, and `page`. The landing page is the official page opened for an available update.

| `kind` | Adapter contract and additional fields |
| --- | --- |
| `json` | JSON object with the numeric version in required `versionKey`. |
| `termius` | Termius-style update YAML. |
| `linear` | Version from a HEAD response's download filename. |
| `proton` | Proton Pass update JSON. |
| `jetbrains` | JetBrains release metadata with required `productCode`. Optional `localProductCode` supplies a different installed product marker; otherwise the API code is used. |
| `studio` | Android Studio update XML. Requires `usesBuild: true` and `channelPolicy: "androidStudioStable"`. |
| `chrome` | Chrome Version History release JSON. |
| `brave` | Brave's stable appcast. Requires `usesBuild: true`. |
| `github` | GitHub latest-release JSON with required `githubOwner` and `githubRepository`. The endpoint must be exactly `https://api.github.com/repos/OWNER/REPOSITORY/releases/latest`. |

Adapter-specific fields must not be attached to other kinds. Product codes must be uppercase alphanumeric identifiers beginning with a letter. `localProductCode` applies only to JetBrains products other than `TBA`. Toolbox (`TBA`) requires its full stable release history endpoint and `usesBuild: true`; an installed build must belong to that history before it is compared.

Optional policy fields are:

| Field | Default and supported values |
| --- | --- |
| `usesBuild` | Defaults to `false`; only the Studio, Brave, and JetBrains adapters support build comparison. |
| `channelPolicy` | Defaults to `numericStable`. `vscodeStable` is available to JSON adapters; `androidStudioStable` is required for Studio. The installed app must pass the selected channel checks. |
| `allowsNoUpdate204` | Defaults to `false`. Only a JSON adapter may opt in when its verified endpoint explicitly uses HTTP 204 to mean no update. An empty response from another endpoint is not proof that the app is current. |
| `nativeDownloadURLKey` | Optional JSON object field containing the explicit HTTPS ZIP/DMG download URL. Requires `nativeSHA256Key`; only `json` supports this field. |
| `nativeSHA256Key` | Optional JSON object field containing the exact archive's 64-character hexadecimal SHA256. Requires `nativeDownloadURLKey`. |
| `nativeFormat` | Optional `zip` or `dmg` when the verified endpoint URL has no archive extension. Requires both native keys. Otherwise the format is inferred from the URL extension. |

Native keys name distinct, top-level scalar fields and cannot be the version field. Missing fields or invalid download metadata leave the update available through Open App and its independent official page; they do not make a successful version check fail. A rule does not bypass local app eligibility, archive identity, architecture, code signature or installation checks. Native updates remain unselected by default.

The bundled Visual Studio Code rule uses the publisher's explicit `url` and `sha256hash` response fields with ZIP format. These fields were verified against the [official Apple silicon stable metadata](https://update.code.visualstudio.com/api/update/darwin-arm64/stable/latest); the version endpoint's `version` field is a commit hash, so `productVersion` remains the release version. No URL is constructed from that hash. Existing JSON rules without native fields retain their prior behavior; GitHub releases do not infer installation eligibility from asset filenames.

The only supported endpoint placeholders are:

| Placeholder | Apple silicon | Intel |
| --- | --- | --- |
| `{darwinPlatform}` | `darwin-arm64` | `darwin` |
| `{macPlatform}` | `mac-arm64` | `mac` |
| `{chromePlatform}` | `mac_arm64` | `mac` |
| `{braveChannel}` | `stable-arm64` | `stable` |

Universal apps use the running machine's architecture. Feed URLs and landing pages do not support placeholders.

### Catalogue version formats

Each rule requires `token`, `bundleIdentifier`, and `format`. These rules describe verified publisher formats after the catalogue's normal application, channel, and platform matching has succeeded.

| `format` | Meaning |
| --- | --- |
| `downloadHash` | A version with a verified download-hash suffix. |
| `downloadUUID` | A version with a verified download-UUID suffix. |
| `postgresVariants` | A marketing version followed by bundled PostgreSQL variant identifiers. |
| `plusBuild` | A catalogue version/build pair compared with an installed `version+build`. |
| `prefixedBuild` | A catalogue version/build pair compared with an installed prefixed build. Requires `buildPrefix`, such as `DB-` or `RD-`. |
| `hyphenBuild` | A combined `version-build` token, with separate numeric version and build comparison. |

Only `prefixedBuild` accepts `buildPrefix`. Unsupported or malformed release values remain unavailable for comparison rather than being declared current.

## Maintaining a rule

1. Verify the installed app's exact bundle identifier and stable-channel markers, the publisher-owned endpoint and landing page, and representative response data for the existing adapter.
2. Add or change the exact mapping in the appropriate array. Preserve architecture limits and explicitly verified build, channel, and HTTP 204 behavior.
3. Increase `revision`, keeping `schemaVersion` unchanged when the app already understands all fields and adapters.
4. Run the rule validation and affected adapter tests. A bundled-resource test also checks that the maintained rules ship with the app.
5. Publish the JSON change to this repository's `main` branch. Existing compatible app releases can adopt it on their next refresh.

To undo a published rule, publish the corrected contents with a new, higher revision. Decreasing the revision cannot roll back rules already accepted by an app. Changing `schemaVersion` without first releasing compatible app code causes existing clients to retain their current rules.

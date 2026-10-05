# JazzWG: LA / Sacramento AutoSwitch

Personal iOS WireGuard fork. Import the existing LA and Sacramento `.conf` files or QR codes on your iPhone. Never commit VPN profiles or private keys to this public repository.

## Current behavior

- Tap **+ → Create AutoSwitch profile**, choose the preferred gateway and alternative, and set thresholds. Enable the newly created profile.
- Both candidates are copied into one encrypted, shared-keychain entry. VPN preferences contain only the entry's persistent reference. The original manual profiles remain available.
- Checks explicitly use Apple's **through-tunnel** TCP connection API, rather than ordinary provider sockets that may bypass the VPN. A small TLS/HTTP request to Cloudflare's `https://1.1.1.1/cdn-cgi/trace` measures reachability and HTTPS response time. This is not ICMP ping, and includes TLS and server delay.
- Every 15 seconds while the extension is running and connectivity is available: three failed checks trigger an alternate-gateway trial. Three responses above the threshold also trigger a trial. An alternate must be at least 25% faster to replace a reachable gateway. Failed or unimproved trials restore the previous configuration.
- A 120-second cooldown applies between trials, including failures. Wi-Fi/cellular path changes schedule a fresh health check after a three-second settling period. A newly started AutoSwitch profile starts with the preferred gateway; startup configuration errors also try the alternative.
- **Optional speed testing is off by default.** A positive Mbps threshold enables a bounded 512 KiB download from `https://speed.cloudflare.com/__down?bytes=524288` at most once per 15 minutes. A low estimate triggers one alternate trial; the alternate must improve the estimate by more than 25%. Failed speed samples alone do not cause failover. The maximum planned payload is about 4 MiB/hour, excluding TLS/headers and transport overhead, if every scheduled check tries both gateways. Failed responses may transfer slightly more before the bounded reader cancels.
- Speed results are end-to-end short-download estimates, including connection setup and TCP startup, not a full speed test or measurement of maximum available bandwidth. Unexpected HTTP statuses, compressed/chunked responses, or different payload sizes are rejected.
- Tap **+ → AutoSwitch status** to see the active gateway, latest measurements, and decision. Imported-profile edits do not update the AutoSwitch snapshots. Delete/recreate the AutoSwitch profile after changing profiles or thresholds. Direct editing is disabled for these composite profiles.

### Initial limitations

This version requires full IPv4 routing (`AllowedIPs` contains `0.0.0.0/0`) in **both** imported profiles. Optional speed testing additionally requires `::/0`, because its hostname may resolve to IPv6. Split-tunnel profiles are rejected rather than silently altered. A future version can add configurable private probe targets for split tunnels.

Only one candidate is active at a time. Trials temporarily move real traffic, can change the public exit IP and disrupt TCP/RDP sessions, and may create brief traffic gaps while routes are replaced. This is not a seamless handover or a guaranteed kill switch. There is no simultaneous benchmarking of inactive tunnels or control of Wi-Fi versus cellular selection.

Health depends on Cloudflare availability as well as the VPN. Sleep, iOS extension termination and system scheduling can delay checks. On-demand startup can be configured using the existing tunnel controls; it does not make continuous sleep-time monitoring guaranteed. No TestFlight/iPhone behavior should be treated as validated until the checks below pass.

## GitHub / TestFlight setup

The workflow uses the **same secret names as this account's LoopWorkspace setup**. GitHub secrets cannot be read back or automatically copied between repositories.

### 1. Configure Apple identifiers

Default identifiers (optional repository variable `APP_ID_IOS` can replace the app identifier):

| Item | Identifier | Capabilities |
| --- | --- | --- |
| iOS app | `com.jazztin98.jazzwg` | Network Extensions (packet tunnel), App Groups, Access Wi-Fi Information |
| VPN extension | `com.jazztin98.jazzwg.network-extension` | Network Extensions (packet tunnel), App Groups |
| Shared App Group | `group.com.jazztin98.jazzwg` | Assign this group to both identifiers |

Use Apple Developer → Certificates, Identifiers & Profiles to create the explicit app IDs and shared group. Attach the group to **both** IDs before provisioning. Create a new **JazzWG** iOS app record in App Store Connect using the app's bundle ID, your choice of SKU, and English as the primary language. The API key must have access to this new app and permission to manage signing assets.

### 2. Configure repository secrets

Under **Settings → Secrets and variables → Actions → Repository secrets**, add:

| Secret | Value |
| --- | --- |
| `TEAMID` | Your ten-character Apple Developer Team ID |
| `GH_PAT` | GitHub token with access to the private `jazztin98/Match-Secrets` repository |
| `FASTLANE_KEY_ID` | App Store Connect API key ID |
| `FASTLANE_ISSUER_ID` | App Store Connect issuer ID |
| `FASTLANE_KEY` | Original multiline `.p8` private-key content, as in your Loop setup |
| `MATCH_PASSWORD` | Password used to encrypt your existing Match signing repository |

Use the same original credential values you supplied for Loop, where their scope allows it. Keep Loop's API key and signing assets intact. If your API key is app-restricted, grant it access to JazzWG or create a suitable key. Do not paste private keys, tokens or passwords into chat or source files.

Optional repository variables: `APP_ID_IOS` and `MATCH_GIT_URL`. Change these before creating identifiers if desired. `MATCH_GIT_URL` defaults to the existing private Match repository. The provisioning operation adds JazzWG profiles there and may create a distribution certificate if needed; it does not revoke certificates or run Match nuke.

### 3. Enable and run Actions

1. Merge the implementation PR once its unsigned iOS build passes. If GitHub disables Actions on the fork, enable them from the **Actions** tab.
2. Run **Build JazzWG for TestFlight**, selecting operation **provision** once, after completing the identifiers and secrets setup.
3. Run it again with operation **testflight**. This uses read-only signing sync, increments the latest TestFlight build number, builds the app and extension, and uploads the IPA.
4. Wait for Apple processing, complete any export-compliance prompts, add yourself as an internal tester, and install from TestFlight. External testing may require beta review. The workflow does not automatically add testers.

This workflow uses macOS 26 and the runner's selected Xcode. Go is pinned to **1.19.13** because the upstream WireGuard project patches that runtime. Upgrading Go without updating the upstream runtime patch is likely to break the build. Actual compatibility with the current runner is checked by the unsigned build workflow; if upstream tooling needs adjustment, fix it before the signed upload.

## Verification

`Check iOS build` compiles the app and VPN extension for iPhone without signing secrets and runs the policy tests. This checks compilation and hysteresis boundaries, not real iPhone VPN behavior. Linux cannot run Xcode or Apple's NetworkExtension frameworks.

Before relying on AutoSwitch:

1. Verify each imported manual profile connects independently and the expected networks remain accessible.
2. Start AutoSwitch, confirm the preferred gateway and plausible HTTPS latency in its status panel.
3. Make the preferred gateway temporarily unreachable while retaining internet access. Confirm alternate selection after failed checks and verify access through the other gateway.
4. Restore service. Test cooldown and rollback with an alternative that is reachable but slower. There is no automatic return to the preferred gateway solely because it recovered; the current healthy gateway remains selected until a degradation trial or restart.
5. Move Wi-Fi → cellular → Wi-Fi; check roaming, correct gateway status and no rapid oscillation. Repeat with the phone locked and after sleep.
6. Enable optional speed tests only if desired. Verify bounded payload estimates against a foreground speed test; adjust the threshold for these conservative short samples.
7. Stop AutoSwitch and verify the extension stops issuing probes. Relaunch the app, delete/recreate an AutoSwitch profile, and confirm its keychain data survives relaunch and is removed on deletion.

Keep the original manual profiles installed while validating this fork.

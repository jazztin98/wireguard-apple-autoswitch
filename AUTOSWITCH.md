# JazzWG: LA / Sacramento AutoSwitch

Personal iOS WireGuard fork with independent build credentials and signing storage. Import the existing LA and Sacramento `.conf` files or QR codes on your iPhone. Never commit VPN profiles or private keys to this public repository.

## Current behavior

- Tap **+ → Create AutoSwitch profile**, choose the preferred gateway and alternative, and set thresholds. Enable the newly created profile.
- Both candidates are copied into one encrypted, shared-keychain entry. VPN preferences contain only the entry's persistent reference. The original manual profiles remain available.
- Checks explicitly use Apple's **through-tunnel** TCP connection API, rather than ordinary provider sockets that may bypass the VPN. A small TLS/HTTP request to Cloudflare's `https://1.1.1.1/cdn-cgi/trace` measures reachability and HTTPS response time. This is not ICMP ping, and includes TLS and server delay.
- Every 15 seconds while the extension is running and connectivity is available: three failed checks trigger an alternate-gateway trial. Three responses above the threshold also trigger a trial. An alternate must be at least 25% faster to replace a reachable gateway. Failed or unimproved trials restore the previous configuration.
- A 120-second cooldown applies between trials, including failures. Wi-Fi/cellular path changes schedule a fresh health check after a three-second settling period. A newly started AutoSwitch profile starts with the preferred gateway; startup configuration errors also try the alternative.
- **Optional speed testing is off by default.** A positive Mbps threshold enables a bounded 512 KiB download from `https://speed.cloudflare.com/__down?bytes=524288` at most once per 15 minutes. A low estimate triggers one alternate trial; the alternate must improve the estimate by more than 25%. Failed speed samples alone do not cause failover. The maximum planned payload is about 4 MiB/hour, excluding TLS/headers and transport overhead, if every scheduled check tries both gateways. Failed responses may transfer slightly more before the bounded reader cancels.
- Speed results are end-to-end short-download estimates, including connection setup and TCP startup, not a full speed test or measurement of maximum available bandwidth. Unexpected HTTP statuses, compressed/chunked responses, or different payload sizes are rejected.
- Tap **+ → AutoSwitch status** to see the active gateway, latest measurements, and decision. Imported-profile edits do not update the AutoSwitch snapshots. Delete/recreate the AutoSwitch profile after changing profiles or thresholds. The Edit button configures manual startup or on-demand connection on Wi-Fi and cellular. Gateway/threshold edits require recreating the composite profile. Disable on-demand on the original manual profiles to avoid competing connection rules.

### Initial limitations

This version requires full IPv4 routing (`AllowedIPs` contains `0.0.0.0/0`) in **both** imported profiles. Optional speed testing additionally requires `::/0`, because its hostname may resolve to IPv6. Split-tunnel profiles are rejected rather than silently altered. A future version can add configurable private probe targets for split tunnels.

Only one candidate is active at a time. Trials temporarily move real traffic, can change the public exit IP and disrupt TCP/RDP sessions, and may create brief traffic gaps while routes are replaced. This is not a seamless handover or a guaranteed kill switch. There is no simultaneous benchmarking of inactive tunnels or control of Wi-Fi versus cellular selection.

Health depends on Cloudflare availability as well as the VPN. Sleep, iOS extension termination and system scheduling can delay checks. On-demand startup can be configured using the existing tunnel controls; it does not make continuous sleep-time monitoring guaranteed. No TestFlight/iPhone behavior should be treated as validated until the checks below pass.

## GitHub / TestFlight setup

The workflow uses **new credentials dedicated to JazzWG**. Do not copy signing secrets from other apps. Its only signing repository is `jazztin98/JazzWG-Signing`, and it targets only the two JazzWG app IDs. No certificates have been created by these code changes; provisioning happens after you complete the account setup below.

### 1. Configure Apple identifiers

The workflow uses these fixed JazzWG identifiers:

| Item | Identifier | Capabilities |
| --- | --- | --- |
| iOS app | `com.jazztin98.jazzwg` | Network Extensions (packet tunnel), App Groups, Access Wi-Fi Information |
| VPN extension | `com.jazztin98.jazzwg.network-extension` | Network Extensions (packet tunnel), App Groups |
| Shared App Group | `group.com.jazztin98.jazzwg` | Assign this group to both identifiers |

Use Apple Developer → Certificates, Identifiers & Profiles to create the explicit app IDs and shared group. Attach the group to **both** IDs before provisioning. Create a new **JazzWG** iOS app record in App Store Connect using the app's bundle ID, your choice of SKU, and English as the primary language. The API key must have access to this new app and permission to manage signing assets.

### 2. Create new credentials and a private signing repository

1. Create a **new private** GitHub repository named `JazzWG-Signing` under `jazztin98`, initialized with a README so it has a default branch. Do not copy certificates, keys or files from another app's signing repository.
2. Generate a **new fine-grained GitHub token** named `JazzWG Signing`. Select only `JazzWG-Signing` under Repository access, with **Contents: Read and write**. It does not need access to the source repository or any other repository.
3. In App Store Connect → Users and Access → Integrations → App Store Connect API, create a **new team API key** named `JazzWG Builds` with the Admin role needed for automated signing/provisioning. Download its `.p8` private key, record its Key ID and Issuer ID, and retain the original securely. Apple permits downloading that private key only once. Do not revoke or change another app's API key.
4. Choose a **new random signing-encryption password** for this repository. Do not reuse another application's password.
5. In the **wireguard-apple-autoswitch source repository**, under Settings → Secrets and variables → Actions → Repository secrets, add:

| Secret | New value |
| --- | --- |
| `JAZZWG_TEAM_ID` | Your ten-character Apple Developer Team ID (the same account identifier is expected) |
| `JAZZWG_SIGNING_TOKEN` | New token scoped exclusively to the private `JazzWG-Signing` repository |
| `JAZZWG_API_KEY_ID` | Key ID for the new `JazzWG Builds` API key |
| `JAZZWG_API_ISSUER_ID` | Issuer ID shown in your App Store Connect account |
| `JAZZWG_API_PRIVATE_KEY` | New multiline `.p8` private-key content |
| `JAZZWG_SIGNING_PASSWORD` | New random password for the encrypted JazzWG signing repository |

The Team ID and Issuer ID identify your existing Apple account; they are not new credentials. Team API keys and Apple's certificate quota are account-wide. A new key and separate repository isolate the stored credentials and workflow, but do not create a separate Apple Developer account.

Starting with the empty dedicated repository, the **provision** operation creates JazzWG signing assets and saves them there encrypted. If Apple has no free distribution-certificate slots, stop and report the error; do not revoke another app's certificate to make room. The workflow contains no certificate-revocation or Match nuke action. Subsequent TestFlight builds use read-only signing synchronization. Never import another app's certificate into this signing repository.

The signing URL and app IDs are fixed in the workflow/Fastfile so optional variables cannot redirect provisioning to another app. Keep the signing repository private. Do not paste private keys, tokens or passwords into chat or source files.

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

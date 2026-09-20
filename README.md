# Swifty

Swifty is an experimental macOS application scaffold for a publicly developed Discord client built with SwiftUI and AppKit. It explores a direct connection to Discord without a project-operated account service, message relay, subscription backend, or required cloud database.

This repository remains an architecture and bootstrap project. It is not a working Discord client and does not claim tested Discord interoperability. The visible application still renders fabricated in-memory state. Live authentication, Gateway and REST sessions, Discord message synchronization, persistence, sending, voice and video, DAVE encryption, screen sharing, notifications, distribution, and release operations remain unimplemented or unverified.

## Present state

The scaffold targets macOS 15 or later with Swift 6 and complete strict-concurrency checking. The application contains a native SwiftUI shell with account, server, channel, timeline, and composer surfaces. The composer is backed by AppKit NSTextView for native selection, undo, text input methods, and keyboard behavior.

The Swift package now exposes three dependency-free libraries. DiscordCore contains lossless Snowflake values, tolerant Gateway opcode values, connection-state data, deterministic exponential backoff, server-provided rate-limit observations, and a credential-attachment policy that permits credentials only on exact Discord API origins and API paths. AuthFeature contains a transport-free remote-auth state machine, an actor coordinator, redacted account models, and an in-memory credential store used only for fixtures and tests. CacheCore contains account namespaces, authorization-versus-presence state, retention bounds, draft and pending-send records, and explicit removal commands.

These modules are contracts and safety primitives, not live adapters. There is no Keychain implementation, Discord remote-auth WebSocket, REST client, Gateway client, database engine, or media bridge in the current repository. The in-memory credential store must not be mistaken for production credential storage.

## Architecture

The XcodeGen manifest in `project.yml` is the source of truth for the macOS application project. `Package.swift` provides a reproducible headless build and test path for DiscordCore, AuthFeature, and CacheCore. Generated Xcode project files are derived artifacts and should not be hand-edited.

The application target contains the macOS entry point, scene setup, commands, views, and temporary presentation state. The package modules are intentionally independent of SwiftUI and AppKit. Future transport, persistence, feature, and media adapters should preserve that dependency direction. Long-running work belongs in actors, while UI state remains main-actor isolated under Swift 6 concurrency checking.

The intended protocol boundary is a set of small adapters rather than one global Discord service. A future Gateway actor will own heartbeat acknowledgements, sequence tracking, identify and resume behavior, reconnect backoff, and tolerant event decoding. A REST actor will consume server-provided route and global rate-limit information, respect cancellation, avoid unsafe retries, and reconcile mutations with Gateway events. The existing credential-attachment policy is a pure guard that callers must re-evaluate for every redirect; it does not perform requests itself.

The cache contracts describe a bounded, per-account local experience. They distinguish cached presence from current authorization, carry account namespaces through removal and revocation commands, and represent drafts and pending sends without performing I/O. They do not provide SQLite storage, encryption, secure deletion, migrations, or a guarantee of access to deleted or inaccessible content. Credentials remain a separate concern and must eventually live in Keychain Services.

## Authentication feasibility gate

Authentication is an early feasibility gate, not an assumption hidden behind the interface. Discord's ordinary documented OAuth2 application flow is not a general replacement-client login mechanism, and a bot-oriented Swift library does not remove those restrictions. The repository now models the user-approved QR or remote-auth lifecycle, but it does not connect to that protocol or claim that login works.

The first authentication proof must cover approval, rejection, expiry, cancellation, session restoration, logout, invalidation, and account-hint matching. MFA, CAPTCHA, and any official-page flow must be tested without bypassing the challenge before support is promised. Credentials, QR session secrets, and messages must never pass through project infrastructure. Production account tokens must never be supplied to coding agents or committed to fixtures.

The production credential boundary is planned around Security.framework Keychain Services. Authentication web content must remain isolated from arbitrary message links, and any JavaScript bridge must expose only narrowly validated actions. Until a supervised manual feasibility gate passes, the application should remain disconnected and should not imply that sign-in works.

## Voice, video, and DAVE

Live media is a separate interoperability project. Discord's current voice and video calls require DAVE in the relevant call paths, so an old voice tutorial or a bot implementation is not sufficient evidence. The official `discord/libdave` implementation is the intended source for Discord's frame encryption and MLS session operations; it is not a complete client or media engine.

The preferred architecture combines libwebrtc with an owned C++ and Objective-C++ bridge, libdave for Discord-specific encryption, Discord Gateway and voice signaling, and ScreenCaptureKit for capture. This design still requires a real two-way call proof with an official client. The project must validate signaling, participant and stream mapping, speaking state, device changes, mute and deafen, codec negotiation, reconnects, encryption transitions, camera streams, and screen sharing with intended audio. A stock WebRTC demo, capture-only prototype, or unencrypted fallback is not Discord interoperability.

Abaddon and related native clients may provide useful implementation references, but they represent different transport and language choices. The project should select one primary media strategy after the proof rather than carrying multiple speculative stacks indefinitely.

## Building

The project requires macOS 15 or later, a stable Xcode release with Swift 6 support, and XcodeGen. From this directory, run `xcodegen generate` to materialize `Swifty.xcodeproj`, then open that project in Xcode to run the native application target.

The package libraries can be built without generating the Xcode project by running `swift build` from the `Swifty` directory. Run `swift test` to execute the DiscordCore, AuthFeature, and CacheCore test targets. The generated Xcode scheme also defines the application test target and coverage collection, which require an actual macOS Xcode destination. No Discord account, token, client secret, signing identity, or production service is needed for the current scaffold.

Third-party dependencies are intentionally absent from the manifests. When a dependency becomes necessary, record why it cannot be replaced by a system framework, pin its exact release or revision, review its license and transitive dependencies, and document reproducible build steps before using it in a release.

## Testing and validation

The present suite covers Snowflake wire preservation, Gateway opcode tolerance, deterministic backoff, authentication lifecycle transitions, redacted credential descriptions, restoration and credential removal through the in-memory store, cache namespace isolation, retention bounds, draft and pending-send invariants, exact Discord API credential origins, redirect re-evaluation, and tolerant parsing of route and global rate-limit metadata. These tests use fabricated values and do not contact Discord.

Future adapter tests should use URLProtocol and WebSocket fakes, injected clocks, split compressed Gateway fixtures, multiple events delivered across receive boundaries, rate-limit responses, cancellation, reconnects, edits, deletions, permission changes, account switching, and channel removal. UI validation should include large fabricated histories, stable pagination position, keyboard-only operation, VoiceOver labels, reduced motion, and Russian and English input methods. Real-device authentication, voice, video, capture, and release testing must record the operating-system and dependency versions used.

## Security and privacy

The project is designed without mandatory telemetry, a developer-hosted credential collection service, message relay, account system, or required cloud database. Remote media, embeds, protocol payloads, authentication content, and future extensions are untrusted input. Links remain inert until activated, arbitrary message HTML and scripts are never executed, and third-party media or upload sessions must never receive Discord authorization headers.

The credential policy rejects non-HTTPS destinations, non-default ports, user information, non-API paths, arbitrary hosts, Discord CDN hosts, and lookalike suffixes. It is a policy primitive rather than proof that every future URLSession integration is safe. Callers must validate each destination and redirect before attaching credentials.

Diagnostics must redact credentials and message content by default, with a user-visible preview before any diagnostic bundle is exported. Account isolation must hold across the database, media cache, notifications, and Keychain. Cache presence must not be represented as authorization. Capture and device resources must stop on logout, cancellation, and permission changes. Release signing keys belong only in protected release infrastructure, while update signatures and notarization must be independently verified before distribution.

The client cannot guarantee a ban-free status, reproduce server permissions locally, grant Nitro entitlements, or make Discord-enforced attachment limits disappear. Any later upload provider, local RPC service, App Intents integration, or extension system must be opt-in, narrowly permissioned, and explicit about where data is sent.

## Contributing

Contributions should preserve the separation between native presentation, protocol adapters, persistence, and media bridges. New behavior should arrive with deterministic fixtures or tests where practical, documented assumptions about Discord's protocol, and a clear statement when behavior is based on unofficial observation rather than public documentation. Do not submit credentials, private package URLs, account data, captured message content, or unreviewed downloaded code.

The initial release direction favors reviewed Swift modules compiled into the application. Themes should use validated design-token JSON, and any future scripting system must have a capability model, resource limits, and process isolation designed before code execution is enabled. Existing Vencord plugins are not expected to run unchanged because a native Swift client does not provide Discord's JavaScript or webpack patching environment.

## Licensing status

This project is licensed under the GNU General Public License, version 3.0, as described in the repository's `LICENSE` file. Contributions and redistribution must preserve the GPL-3.0 terms. Future dependencies, including libwebrtc and libdave, still require separate license and compatibility review before inclusion in a release.

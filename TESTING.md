# Testing

Run the test suite from the repository root on an Apple Silicon Mac with macOS 14 or later and Apple's Command Line Tools:

```sh
./test.sh
```

The runner compiles each test executable separately against the application services and the vendored LAME library. It checks localization before compilation. URLSession protocol mocks intercept API requests; the tests do not read a personal API key or make live ElevenLabs requests. Audio fixtures are generated locally.

Native AAC/M4A tests need access to the macOS audio encoding service. A restricted shell sandbox may reject that service even when the app can use it; run the suite in a normal local Terminal session in that case. Do not replace an encoding failure with a successful build result.

## Automated coverage

The complete runner passed on 2026-10-11: 43 named API/core/integration/media test groups, the localization harness, and the catalog audit. These results use mock transports and local fixtures, not live ElevenLabs generation.

| Suite | Verification | Result |
| --- | --- | --- |
| [CoreTests](Tests/CoreTests.swift) | 13 groups: Unicode segmentation, encodings, output names, API error stop, resumable segments, source changes, no overwrite, pagination, credential redaction, real MP3/M4A/WAV decoding and encoding, expression request parameters, Voice Changer multipart, typed text | Passed with mocks and synthetic audio |
| [APITests](Tests/APITests.swift) | 11 groups: model/language metadata, account allowance, voices and ownership, shared search and add, edit/delete gating, cloning/design, Unicode TTS language parameters, transcription/isolation/effects, history, dubbing lifecycle and signed downloads, error and identifier handling | Passed with mocked responses |
| [MediaImportTests](Tests/MediaImportTests.swift) | 10 groups: encodings and multilingual content, SRT/VTT parsing, folder/multiple import, symlinks and limits, Finder item-provider decoding, WAV metadata, player load/seek/stop, permission denial, pending-permission cancellation | Passed with local fixtures and permission mocks |
| [IntegrationTests](Tests/IntegrationTests.swift) | 9 groups: credential-free initialization, missing-key handling, import without generation, deduplication, recoverable output collisions, preservation of invalid-source errors, independent interface/speech language, model capability mapping, Voice Changer source/output protection, cancellation | Passed with a local observable model and denied network transport |
| [LocalizationTests](Tests/LocalizationTests.swift) | English/Polish lookup, immediate switching, preference storage, speech-language independence, placeholder formatting, missing-key fallback | Passed against native strings catalogs |
| [Localization audit](Scripts/audit-localization.py) | Source-key coverage, matching catalogs, duplicate keys, and format argument consistency | Run by `test.sh` |

The icon build was separately checked by round-tripping the `.icns` asset and verifying all sizes from 16 through 1,024 pixels. A 128-pixel rendition was visually inspected against the supplied design.

The API tests validate the implemented request and response contracts. They do not establish that a particular account has access to a model or endpoint, that a real voice has the expected acoustic result, or that subscription billing matches a fixture.

## Live-service and hardware boundary

No billable live generation, cloning, voice design, transformation, transcription, isolation, sound-effect, or dubbing test was performed for this version's automated suite. Voice quality, cross-language pronunciation, retained delivery, and translated output therefore remain unverified against the live service.

The media tests do not record from a physical microphone or confirm audible playback through speakers. They test permission and cancellation state with injected responses, and playback loading/seeking with local audio. Remote voice-preview availability, physical microphone selection, and output-device behavior require manual checks.

Keychain behavior is implemented through the native Security framework. The automated suite does not modify a real saved credential. Interactive add, replace, removal, and any macOS Keychain prompts should be checked using a disposable test credential.

## Native UI checks performed

The arm64 release build compiled successfully and passed `codesign --verify --deep --strict` and Info.plist validation. A separate test bundle launched with `--ui-test-mode`, without loading the saved key or account data.

Observed on macOS:

- Native sidebar navigation, Settings-only API key field, and immediate Polish-to-English interface switching.
- The English language choice persisted after relaunch.
- A single TXT import through NSOpenPanel preserved Polish, English, and Japanese content and supplied the recording title.
- Importing a folder containing TXT and SRT created two ready jobs without starting generation.
- Text to Speech, Voice Changer, Settings, and Batch Jobs rendered in dark appearance. An oversized text-editor layout was found visually, constrained to the available detail area, rebuilt, and checked again.

The app icon was visible inside the running application and in Finder. Text to Speech was also visually checked in light appearance using an Aqua-only test bundle; the shipping bundle continues to follow the system appearance. Hardware audio, live generation, and the remaining manual checks below are not implied by these UI results.

## Manual checks before a release

Use a test account and knowingly authorize any charged operation. Start with the smallest input needed to verify the workflow.

1. Build with `./build.sh build`, launch `build/Voice Desk.app`, and check the icon in Finder and the Dock.
2. Validate a key with the required scopes. Check partial connection failures by using a key without one optional scope. Replace and remove only the test key.
3. Generate short text, play it, and export each format. Repeat with a supported second language and mixed-language input. Changing the interface language must leave the selected speech language and original text unchanged.
4. Import and record a short Voice Changer source. Confirm permission denial, explicit recording start/stop, conversion, playback, and source preservation.
5. Exercise voice previews, account and shared-library searches, creation, and ownership-gated actions with disposable voices. Confirm destructive dialogs before deletion.
6. Exercise transcription, effects, isolation, history, and dubbing only when the account permits them. For dubbing, check status refresh and an expired result URL without creating a second paid project.
7. Import TXT/SRT/VTT files and a folder; run, cancel, and retry a batch. Confirm output naming, collision handling, source-change errors, reuse of completed segments, and no automatic generation after import.
8. Check both interface languages, light and dark appearance, window resizing, keyboard focus and shortcuts, error messages, and loading/cancellation states.

## Contributing tests

Add a focused executable in `Tests` with a filename ending in `Tests.swift`; `test.sh` discovers it automatically. Service tests exclude App.swift and AppModel.swift. The integration target includes AppModel.swift and runs with `--ui-test-mode` so it does not load the user's Keychain item or saved workspace. Use fixtures or injected URLSession behavior for contract tests, retain secret-redaction cases, and distinguish local codec results from mocked API behavior.

For a new interface message, add matching English and Polish entries, retain printf placeholder types, and run the localization audit. Before publishing documentation, check relative links and verify that examples, screenshots, paths, and logs contain no account-specific information.

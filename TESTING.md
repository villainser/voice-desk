# Testing

Run the test suite from the repository root on an Apple Silicon Mac with macOS 14 or later and Apple's Command Line Tools:

```sh
./test.sh
```

The runner compiles each test executable separately against the application services and the vendored LAME library. It checks localization before compilation. URLSession protocol mocks intercept API requests; the tests do not read a personal API key or make live ElevenLabs requests. Audio fixtures are generated locally.

Native AAC/M4A tests need access to the macOS audio encoding service. A restricted shell sandbox may reject that service even when the app can use it; run the suite in a normal local Terminal session in that case. Do not replace an encoding failure with a successful build result.

## Automated coverage

The suites passed on 2026-10-12: 51 named API/core/integration/media/recording test groups, the localization harness, and the catalog audit. These results use mock transports and local fixtures, not live ElevenLabs generation. The current catalogs contain 415 matching English/Polish entries and cover 402 source keys.

| Suite | Verification | Result |
| --- | --- | --- |
| [CoreTests](Tests/CoreTests.swift) | 13 groups: Unicode segmentation, encodings, output names, API error stop, resumable segments, source changes, no overwrite, pagination, credential redaction, real MP3/M4A/WAV decoding and encoding, expression request parameters, Voice Changer multipart, typed text | Passed with mocks and synthetic audio |
| [APITests](Tests/APITests.swift) | 12 groups: model/language metadata, account allowance, voices and ownership, saved membership and pagination, shared search and add, edit/delete gating, cloning/design, Unicode TTS language parameters, transcription/isolation/effects, history, dubbing lifecycle and signed downloads, error and identifier handling | Passed with mocked responses |
| [MediaImportTests](Tests/MediaImportTests.swift) | 10 groups: encodings and multilingual content, SRT/VTT parsing, folder/multiple import, symlinks and limits, Finder item-provider decoding, WAV metadata, player load/seek/stop, permission denial, pending-permission cancellation | Passed with local fixtures and permission mocks |
| [IntegrationTests](Tests/IntegrationTests.swift) | 11 groups: credential-free initialization, missing-key handling, voice source filtering and selection, import without generation, deduplication, recoverable output collisions, preservation of invalid-source errors, independent interface/speech language, model capability mapping, Voice Changer source/output protection, cancellation, finalized microphone sample routing and generation guards | Passed with a local observable model and denied network transport |
| [RecordingTests](Tests/RecordingTests.swift) | 5 groups: named built-in/external/default input routing, permission and duplicate-start guards, meter updates, asynchronous finalization, automatic completion, unplug handling, cancellation, unavailable inputs and failed recordings | Passed with injected devices, capture callbacks, and synthetic WAV files |
| [LocalizationTests](Tests/LocalizationTests.swift) | English/Polish lookup, immediate switching, preference storage, speech-language independence, placeholder formatting, missing-key fallback | Passed against native strings catalogs |
| [Localization audit](Scripts/audit-localization.py) | Source-key coverage, matching catalogs, duplicate keys, and format argument consistency | Run by `test.sh` |

The icon build was separately checked by round-tripping the `.icns` asset and verifying all sizes from 16 through 1,024 pixels. A 128-pixel rendition was visually inspected against the supplied design.

The API tests validate the implemented request and response contracts. They do not establish that a particular account has access to a model or endpoint, that a real voice has the expected acoustic result, or that subscription billing matches a fixture.

## Live-service and hardware boundary

On 2026-10-12, the shipping application loaded its existing Keychain item and successfully fetched `/v1/models`, `/v2/voices`, and `/v1/user/subscription`. The UI displayed the returned models, voice metadata and subscription values. Downloading an existing voice preview succeeded, and the native player entered playback with a valid duration. No generation request was involved.


No billable live generation, cloning, voice design, transformation, transcription, isolation, sound-effect, or dubbing test was performed for this version's automated suite. Voice quality, cross-language pronunciation, retained delivery, and translated output therefore remain unverified against the live service.

The media and recording tests do not record from a physical microphone or confirm audible playback through speakers. They test input routing, permission, cancellation, and finalization with injected devices and callbacks, and playback loading/seeking with local audio. One existing remote preview was downloaded and entered playback in the native UI. Physical microphone selection, audible speaker output, and other preview URLs remain outside that check.

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

## Voice filtering regression — 2.0.1

API fixtures distinguish unsaved defaults, owned clones, saved community voices, and defaults explicitly saved to a collection. Tests cover saved pagination, merging newly saved voices, unknown membership in old caches, a failed saved lookup, and unchanged ownership restrictions. AppModel tests cover source changes in TTS, Voice Changer, and Batch Jobs, search/category filtering, empty lists, and selection alignment.

The updated shipping app also completed a read-only live refresh. Native UI checks confirmed separate saved and unsaved voice menus with no shared entries, matching My Voices and ElevenLabs workspaces, and a source selector that changes the selected voice to a visible entry. The previous voice was restored after verification. No paid generation was performed.

All 45 named groups and the localization harness passed. The catalog audit passed with 396 matching English/Polish entries. CoreAudio codec tests initially failed under the filesystem sandbox and passed when rerun with access to macOS audio services; those tests use synthetic local audio. The arm64 release build and code-signature validation passed.

## Microphone and settings changes — 2.0.2

The complete suite passed with 51 named groups. Recording tests were rerun after tightening capture-error handling and passed all five groups. The release build, code-signature check, and Info.plist validation passed; the updated shipping executable was confirmed running.

Native UI automation failed while connecting to the updated window with `Sky Computer Use native pipe closed before response`, including after resetting the automation session. The new panel layout and physical input-device menu were therefore not visually verified. No physical recording or live cloning request was made. Earlier UI observations above describe the preceding versions.

## Manual checks before a release

Use a test account and knowingly authorize any charged operation. Start with the smallest input needed to verify the workflow.

1. Build with `./build.sh build`, launch `build/Voice Desk.app`, and check the icon in Finder and the Dock.
2. Validate a key with the required scopes. Check partial connection failures by using a key without one optional scope. Replace and remove only the test key.
3. Generate short text, play it, and export each format. Repeat with a supported second language and mixed-language input. Changing the interface language must leave the selected speech language and original text unchanged.
4. Import and record a short Voice Changer source. Confirm permission denial, explicit recording start/stop, conversion, playback, and source preservation. In Instant Voice Clone, record separate samples using a built-in microphone and an external input. Check the level meter, Stop/finalization, preview, sample removal, device unplugging, and that no upload occurs until Create Voice Clone is pressed. In Voice settings, confirm supported parameters are visible and disabled until Override voice defaults is enabled.
5. Exercise voice previews, account and shared-library searches, creation, and ownership-gated actions with disposable voices. Confirm destructive dialogs before deletion.
6. Exercise transcription, effects, isolation, history, and dubbing only when the account permits them. For dubbing, check status refresh and an expired result URL without creating a second paid project.
7. Import TXT/SRT/VTT files and a folder; run, cancel, and retry a batch. Confirm output naming, collision handling, source-change errors, reuse of completed segments, and no automatic generation after import.
8. Check both interface languages, light and dark appearance, window resizing, keyboard focus and shortcuts, error messages, and loading/cancellation states.

## Contributing tests

Add a focused executable in `Tests` with a filename ending in `Tests.swift`; `test.sh` discovers it automatically. Service tests exclude App.swift and AppModel.swift. The integration target includes AppModel.swift and runs with `--ui-test-mode` so it does not load the user's Keychain item or saved workspace. Use fixtures or injected URLSession behavior for contract tests, retain secret-redaction cases, and distinguish local codec results from mocked API behavior.

For a new interface message, add matching English and Polish entries, retain printf placeholder types, and run the localization audit. Before publishing documentation, check relative links and verify that examples, screenshots, paths, and logs contain no account-specific information.

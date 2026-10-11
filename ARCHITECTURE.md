# Architecture

Voice Desk is a SwiftUI macOS application. ElevenLabs performs every AI operation. Local code prepares requests, manages files and credentials, and presents results. AVFoundation and LAME provide ordinary recording, playback, decoding, and encoding; there are no local speech models or alternative AI providers.

## Components

| Component | Responsibility |
| --- | --- |
| [App.swift](Sources/App.swift) | SwiftUI navigation, workflow screens, native dialogs, and app lifecycle |
| [AppModel.swift](Sources/AppModel.swift) | Observable workflow state, user-triggered operations, preferences, and local library indexing |
| [APIService.swift](Sources/APIService.swift) | Official ElevenLabs HTTP requests and response handling |
| [APIModels.swift](Sources/APIModels.swift) | Decodable voice, model, account, history, and tool responses |
| [Core.swift](Sources/Core.swift) | Generation settings, text segmentation, resumable processing, audio export, and Keychain access |
| [Imports.swift](Sources/Imports.swift) | File selection expansion, validation, subtitle parsing, and Finder drops |
| [Media.swift](Sources/Media.swift) | Audio playback and microphone recording |
| [Localization.swift](Sources/Localization.swift) | Runtime English/Polish catalog selection and format substitution |

The API contract and feature restrictions are maintained in [ELEVENLABS_API.md](ELEVENLABS_API.md). UI code must not infer ownership from a voice's category or from its presence in an account response. Model capabilities and language lists come from the model response rather than a fixed language menu.

## Generation and export

`GenerationSettings` captures the voice, model, supported language override, expression settings, noise removal, and export format for a job. Text segmentation preserves Unicode scalars and prefers paragraph, sentence, and whitespace boundaries. The request size is capped by the app and by the selected model's reported limit. Imported subtitle text is spoken in cue order; subtitle timestamps do not control the timing of generated audio.

`BatchProcessor` validates the source against its imported fingerprint before requesting audio. Downloaded segments are written atomically and decoded for validation. A failure preserves successful segments so a later explicit retry can resume. It does not automatically retry a billable request.

The cache identity includes the content fingerprint and generation settings. Output format is excluded because the same downloaded audio can be exported locally. Exports are assembled in a temporary file, validated, and moved into place. Existing output files are never overwritten by batch generation. A completed result in another supported format can be converted locally without a new API request.

For single-response tools and retrieved recordings, the original downloaded audio is indexed in the library before local format conversion. If conversion fails, that original remains available for export without repeating the API operation. Batch destinations are checked for collisions with source recordings and other queued output names.

The normal generation source is MP3 at 44.1 kHz and 128 kbps. A single MP3 segment can be copied without re-encoding. Multiple segments are decoded and encoded with LAME for MP3 output, AVFoundation for AAC/M4A, or uncompressed 16-bit PCM for WAV. A WAV export from this source does not restore information lost by MP3 compression.

Voice Changer submits recorded or imported speech to the Speech-to-Speech endpoint with the target voice. It does not replace the transcript with typed words. Typed words use Text to Speech. The source recording remains unchanged.

## Imports and media

`ImportService` expands folders one level deep, skips hidden items, and rejects symbolic links and application packages. Text import supports TXT, SRT, and VTT; UTF-8, BOM-marked UTF-16, and Windows-1250 text are accepted. Subtitle parsing removes cue numbers, timing lines, and supported formatting while retaining spoken text.

Text files are limited to 10 MB, audio files to 100 MB, and one import selection to 1,000 files. Voice Changer recordings are limited to five minutes. A filename extension is not sufficient validation: audio must also decode through macOS.

`AudioPlayerModel` uses AVPlayer for local results and HTTPS voice previews. Loading a preview does not generate speech. The player tracks loading, duration, seeking, completion, and playback failures.

`MicrophoneRecorder` asks for permission only after Record is pressed. It records mono 44.1 kHz, 16-bit PCM WAV, reports elapsed time and input level, and stops at five minutes. Cancellation deletes only the unfinished recording created by that recorder. Imported audio is never deleted by the recording flow.

## Credentials and local data

`KeyStore` uses a dedicated generic-password item in macOS Keychain, retaining the service identity from the earlier application so an update can find an existing saved key. Newly created items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. No API key is stored in UserDefaults or bundled resources.

The app retains non-secret preferences and cached model/voice metadata in UserDefaults. Cached metadata is not proof of a current connection or current account allowance. The `Voice Desk` Application Support directory contains `Audio` results, `Recordings` microphone captures, `Previews`, and `library.json`, which indexes local results by path, title, date, kind, and voice name. Batch output may remain in its chosen destination outside this directory.

Generation caches use a hidden `.folder-voice-cache` directory beside the source and are removed for a job after its export succeeds. Failed or cancelled jobs can leave reusable segments there. A selected output destination does not move this source-side cache, so imported sources must be in a writable directory when generation needs caching.

File content sent for a requested operation goes to ElevenLabs. Recorded audio and downloaded results also exist locally; removing an API key does not delete them. Local file permissions and disk encryption remain the responsibility of macOS and the user's account.

## Localization

`L` reads `interfaceLanguage` on each call and loads the matching native `.lproj/Localizable.strings` catalog. The explicit preference supports `en` and `pl`; without it, the first supported system preference is used, with English as a fallback. Missing keys fall back to their source string.

Interface language is separate from generation language. User text, model identifiers, voice names, and API metadata are not translated by the localization layer. Parameterized messages use printf-style placeholders so translated sentences can preserve their argument types. [The localization audit](Scripts/audit-localization.py) checks key coverage and placeholder consistency.

Localized `InfoPlist.strings` files provide the microphone purpose text for macOS permission dialogs. Those system dialogs follow the macOS application-language setting. Captured server error details and titles of already-created recordings retain their original text.

## Failures and cancellation

API, import, media, and export failures are surfaced to the current workflow. Account restrictions do not disable unrelated tools. Cancellation stops local work and cancels the active request when possible, but cannot guarantee reversal of work ElevenLabs has already accepted or billed. A retry is an explicit user action.

Tests inject URLSession protocol mocks and local media fixtures. They do not need access to a personal API key. See [TESTING.md](TESTING.md) for the verification boundary.

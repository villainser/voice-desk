import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    private let create: [WorkspacePage] = [.speech, .changer, .effects]
    private let voices: [WorkspacePage] = [.myVoices, .discover, .createVoice]
    private let tools: [WorkspacePage] = [.transcription, .isolation, .dubbing]
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSImage()).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice Desk").font(.title3.bold())
                        Text("ElevenLabs").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(18)
                List(selection: $model.page) {
                    Section(L("Create")) { ForEach(create) { nav($0) } }
                    Section(L("Voices")) { ForEach(voices) { nav($0) } }
                    Section(L("Tools")) { ForEach(tools) { nav($0) } }
                    Section(L("Library")) { nav(.library); nav(.batch) }
                    Section { nav(.settings) }
                }.listStyle(.sidebar).disabled(model.recorder.isBusy)
                HStack(spacing: 7) {
                    Circle().fill(model.hasKey ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(model.hasKey ? L("API key configured") : L("Set up ElevenLabs")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if !model.hasKey && model.page != .settings {
                    HStack {
                        Image(systemName: "key.fill")
                        Text(L("Connect your ElevenLabs account to generate audio."))
                        Spacer()
                        Button(L("Open Settings")) { model.page = .settings }
                    }.font(.callout).padding(12).background(Color.accentColor.opacity(0.08))
                }
                GeometryReader { bounds in
                    workspace.disabled(model.busy)
                        .frame(width: max(0, bounds.size.width - 48), height: max(0, bounds.size.height - 48), alignment: .topLeading)
                        .padding(24)
                }
                if let error = model.error { message(error, error: true) }
                if let notice = model.notice { message(notice, error: false) }
                if model.player.sourceURL != nil { AudioPlayerView(player: model.player, model: model).disabled(model.recorder.isBusy).padding(.horizontal, 24).padding(.bottom, 14) }
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(L(model.status)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let progress = model.progress { ProgressView(value: progress).frame(width: 140) }
                    Spacer()
                    if model.recorder.isRecording { Button(L("Stop Recording"), action: model.stopRecording).tint(.red) }
                    if model.busy { Button(L("Cancel"), action: model.cancel).keyboardShortcut(.cancelAction) }
                    Text("Voice Desk 2.0.2").font(.caption2).foregroundStyle(.tertiary)
                }.padding(12).background(.bar)
            }.navigationTitle(model.page.title)
            .toolbar {
                ToolbarItemGroup {
                    if model.page != .settings {
                        Button { model.page = .settings } label: { Image(systemName: "gearshape") }.help(L("Settings")).disabled(model.recorder.isBusy)
                    }
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.dropTargeted, perform: model.acceptDrop)
            .overlay { if model.dropTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 5])).padding(6).allowsHitTesting(false) } }
        }
        .frame(minWidth: 1060, minHeight: 760)
        .tint(.indigo)
        .environment(\.locale, Locale(identifier: model.interfaceLanguage))
        .onReceive(model.recorder.objectWillChange) { _ in model.objectWillChange.send() }
        .onReceive(model.player.objectWillChange) { _ in model.objectWillChange.send() }
        .onChange(of: model.interfaceLanguage) { _, _ in model.objectWillChange.send() }
        .onChange(of: model.modelID) { _, _ in model.modelChanged() }
        .onChange(of: model.conversionModelID) { _, _ in model.persistPreferences() }
        .onChange(of: model.voiceID) { _, _ in model.persistPreferences() }
        .onChange(of: model.recorder.selectedDeviceID) { _, _ in model.persistPreferences() }
        .onChange(of: model.speechLanguage) { _, _ in model.persistPreferences() }
        .onChange(of: model.format) { _, _ in model.persistPreferences(); model.refreshJobOutputs() }
        .onChange(of: model.expression) { _, _ in model.persistPreferences() }
        .sheet(item: $model.editingVoice) { _ in editVoiceSheet }
    }
    private func nav(_ page: WorkspacePage) -> some View { Label(page.title, systemImage: page.icon).tag(page) }
    @ViewBuilder private var workspace: some View {
        switch model.page {
        case .speech: speechView
        case .changer: changerView
        case .effects: effectsView
        case .myVoices: myVoicesView
        case .discover: discoverView
        case .createVoice: createVoiceView
        case .transcription: transcriptionView
        case .isolation: isolationView
        case .dubbing: dubbingView
        case .library: libraryView
        case .batch: batchView
        case .settings: SettingsView(model: model)
        }
    }
    private func heading(_ title: String, _ subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 25, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 48, height: 48).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 27, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }.padding(.bottom, 10)
    }
    private func message(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: error ? "exclamationmark.circle.fill" : "info.circle").foregroundStyle(error ? .red : .secondary)
            Text(text).font(.callout).textSelection(.enabled).lineLimit(5)
            Spacer()
            Button { if error { model.error = nil } else { model.notice = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("Dismiss message"))
        }.padding(12).background((error ? Color.red : Color.accentColor).opacity(0.07)).padding(.horizontal, 24).padding(.bottom, 12)
    }
    private var speechView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(L("Give your words a voice"), L("Type or paste your text. Choose a voice and a compatible model, then generate speech."), icon: "text.bubble")
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        TextField(L("Recording title (optional)"), text: $model.recordingTitle).textFieldStyle(.roundedBorder)
                        Button(L("Import Text…"), action: model.importText).help(L("Import TXT, SRT or VTT. Multiple files become batch jobs."))
                    }
                    TextEditor(text: $model.text).font(.system(size: 16)).padding(8)
                        .frame(minHeight: 230, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
                        .overlay(alignment: .topLeading) {
                            if model.text.isEmpty { Text(L("Enter the words you want to hear…")).foregroundStyle(.tertiary).padding(14).allowsHitTesting(false) }
                        }.accessibilityLabel(L("Speech text"))
                    HStack {
                        Text(L("%d characters", model.text.unicodeScalars.count)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(L("Original language preserved · no translation")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(L("Generating uses your ElevenLabs credits.")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: model.generateSpeech) { Label(L("Generate Speech"), systemImage: "waveform") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.canGenerate || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.disabled(model.busy)
                voiceControls.frame(width: 275)
            }
        }
    }
    private var voiceControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(L("Voice")).font(.headline); Spacer(); Button { model.page = .myVoices } label: { Image(systemName: "person.crop.rectangle.stack") }.help(L("Browse My Voices")) }
                        Picker(L("Voice source"), selection: Binding(get: { model.voiceSource }, set: model.setVoiceSource)) {
                            ForEach(VoiceSource.allCases) { Text($0.title).tag($0) }
                        }
                        Picker(L("Voice"), selection: $model.voiceID) {
                            if !model.pickerVoices.contains(where: { $0.id == model.voiceID }) { Text(L("Choose a voice")).tag(model.voiceID) }
                            ForEach(model.pickerVoices) { Text($0.name).tag($0.id) }
                        }.labelsHidden()
                        Text(L("%@ voices in this list", String(model.pickerVoices.count))).font(.caption).foregroundStyle(.secondary)
                        if model.pickerVoices.isEmpty || model.needsVoiceClassification {
                            Text(L("Refresh to load voices for this source, or choose another source.")).font(.caption).foregroundStyle(.secondary)
                            Button(L("Refresh"), action: model.refreshVoices)
                        }
                        if let voice = model.selectedVoice {
                            HStack {
                                Text(voice.languageSummary.isEmpty ? (voice.category ?? "") : voice.languageSummary).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { model.previewVoice(url: voice.preview_url) } label: { Label(L("Preview"), systemImage: "play.circle") }.disabled(voice.preview_url == nil)
                            }
                        } else { TextField(L("Voice ID"), text: $model.voiceID).textFieldStyle(.roundedBorder) }
                        Divider()
                        Text(L("Model")).font(.headline)
                        if model.page == .changer || (model.page == .batch && model.batchAudio) {
                            if model.conversionModels.isEmpty {
                                TextField(L("Model ID"), text: $model.conversionModelID).textFieldStyle(.roundedBorder)
                            } else {
                                Picker(L("Conversion model"), selection: $model.conversionModelID) { ForEach(model.conversionModels) { Text($0.displayName).tag($0.id) } }.labelsHidden()
                            }
                        } else {
                            if model.ttsModels.isEmpty {
                                TextField(L("Model ID"), text: $model.modelID).textFieldStyle(.roundedBorder)
                                Text(L("Validate the connection in Settings to load available models and languages.")).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Picker(L("Speech model"), selection: $model.modelID) { ForEach(model.ttsModels) { Text($0.displayName).tag($0.id) } }.labelsHidden()
                            }
                            Text(L("Speech language")).font(.headline)
                            if model.supportsExplicitLanguage {
                                Picker(L("Speech language"), selection: $model.speechLanguage) {
                                    Text(L("Auto-detect / mixed languages")).tag("")
                                    ForEach(model.availableLanguages) { language in
                                        Text(Locale(identifier: model.interfaceLanguage).localizedString(forLanguageCode: language.id) ?? language.name).tag(language.id)
                                    }
                                }.labelsHidden()
                            } else {
                                Text(L("Automatic from text")).font(.callout)
                                Text(L("This model uses the input text to determine the language. No language override is sent.")).font(.caption).foregroundStyle(.secondary)
                            }
                            if let ids = model.selectedVoice?.high_quality_base_model_ids, !ids.isEmpty, !ids.contains(model.modelID) {
                                Text(L("This voice does not list the selected model among its high-quality models. Availability and pronunciation are determined by ElevenLabs.")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(8)
                }
                formatControls
                GroupBox { expressionControls.padding(8) } label: { Text(L("Voice settings")).font(.headline) }
            }
        }.disabled(model.busy || model.recorder.isBusy)
    }
    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Output format")).font(.headline)
            Picker(L("Output format"), selection: $model.format) { ForEach(OutputFormat.allCases, id: \.self) { Text($0.label).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Text(model.format == .wav ? L("WAV is 16-bit PCM decoded from API MP3. It does not restore lost detail.") : L("API audio: MP3 128 kb/s. M4A and multi-part MP3 use local encoding."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var expressionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("Override voice defaults"), isOn: $model.expression.enabled)
            VStack(alignment: .leading, spacing: 12) {
                if model.expressionModel == "eleven_v3" {
                    Picker(L("Stability"), selection: $model.expression.stability) {
                        Text(L("Creative")).tag(0.0); Text(L("Natural")).tag(0.5); Text(L("Robust")).tag(1.0)
                    }
                } else {
                    slider(L("Stability"), value: $model.expression.stability)
                    Text(L("Lower stability allows more emotional variation.")).font(.caption2).foregroundStyle(.secondary)
                    slider(L("Similarity"), value: $model.expression.similarity)
                }
                if !model.expressiveModel {
                    if model.expressionCapabilities?.can_use_style == true { slider(L("Style exaggeration"), value: $model.expression.style) }
                    if !model.expressionModel.contains("sts") {
                        HStack { Text(L("Speed")); Spacer(); Text(String(format: "%.2f×", model.expression.speed)) }.font(.caption)
                        Slider(value: $model.expression.speed, in: 0.7...1.2, step: 0.05).accessibilityLabel(L("Speed"))
                    }
                    if model.expressionCapabilities?.can_use_speaker_boost == true { Toggle(L("Speaker boost"), isOn: $model.expression.speakerBoost).font(.caption) }
                } else {
                    Picker(L("Delivery"), selection: $model.expression.delivery) {
                        Text(L("From the text")).tag("")
                        Text(L("Whispering")).tag("whispers")
                        Text(L("Excited")).tag("excited")
                        Text(L("Curious")).tag("curious")
                        Text(L("Sad")).tag("sad")
                        Text(L("Angry")).tag("angry")
                        Text(L("Sarcastic")).tag("sarcastic")
                    }
                    Text(L("Delivery tags are prepended to each segment. Results depend on the selected voice.")).font(.caption2).foregroundStyle(.secondary)
                }
            }.disabled(!model.expression.enabled).opacity(model.expression.enabled ? 1 : 0.45)
        }
    }
    private func slider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit() }.font(.caption)
            Slider(value: value, in: 0...1, step: 0.05).accessibilityLabel(title)
        }
    }
    private var changerView: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(L("A new voice. Your performance."), L("Transform a recording while preserving its words, timing and expressive delivery. This does not translate speech."), icon: "person.wave.2")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    Label(L("1  Source recording"), systemImage: "waveform").font(.headline)
                    AudioSourceView(model: model, recordEnabled: true)
                    Toggle(L("Remove background noise"), isOn: $model.removeNoise)
                    Text(L("Voice Changer accepts up to 5 minutes per recording. The client upload limit is 100 MB.")).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Label(L("2  Choose the target voice on the right"), systemImage: "person.crop.circle").font(.headline)
                    Text(L("To speak new words with an existing or cloned voice, use Text to Speech. No source recording is required there.")).foregroundStyle(.secondary)
                    Spacer()
                    HStack {
                        Text(L("Conversion uses your ElevenLabs credits.")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: model.convertVoice) { Label(L("Convert Voice"), systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.canGenerate || model.sourceAudio == nil || model.recorder.isRecording)
                    }
                }.disabled(model.busy)
                voiceControls.frame(width: 275)
            }
        }
    }
    private var effectsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(L("Describe a sound"), L("Create sound effects through ElevenLabs. Describe the sound, its environment and how it changes over time."), icon: "waveform.path")
            TextEditor(text: $model.effectsPrompt).font(.body).frame(minHeight: 180).padding(8)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2))).accessibilityLabel(L("Sound effect description"))
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L("Automatic duration"), isOn: $model.effectAutomaticDuration)
                    if !model.effectAutomaticDuration {
                        Text(L("Duration: %.1f seconds", model.effectDuration)).monospacedDigit()
                        Slider(value: $model.effectDuration, in: 0.5...30, step: 0.5).accessibilityLabel(L("Effect duration"))
                    }
                    Toggle(L("Looping sound"), isOn: $model.effectLoop)
                    slider(L("Prompt influence"), value: $model.effectInfluence)
                }
                formatControls.frame(width: 280)
            }
            Spacer()
            HStack { Text(L("Generating uses your ElevenLabs credits.")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L("Generate Sound"), action: model.generateEffect).buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.hasKey || model.effectsPrompt.isEmpty) }
        }.disabled(model.busy)
    }
    private var myVoicesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(L("My Voices"), L("Voices saved, cloned or created in your account. Unsaved ElevenLabs defaults appear separately."), icon: "person.crop.rectangle.stack")
            HStack {
                TextField(L("Search voices"), text: $model.voiceSearch).textFieldStyle(.roundedBorder)
                Picker(L("Category"), selection: $model.voiceCategory) { Text(L("All categories")).tag(""); ForEach(model.voiceCategories, id: \.self) { Text($0).tag($0) } }.frame(width: 170)
                Button(L("Refresh"), action: model.refreshVoices).disabled(model.busy)
            }
            if model.visibleVoices.isEmpty { empty(L("No voices to show"), L("Refresh your account voices, change the search, or add a voice from ElevenLabs Voices."), "person.crop.circle.badge.plus") }
            else { accountVoiceRows(model.visibleVoices) }
        }
    }
    private func accountVoiceRows(_ voices: [Voice]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) { ForEach(voices) { voice in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(voice.name).font(.headline)
                            Text([voice.category, voice.languageSummary.isEmpty ? nil : voice.languageSummary].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.previewVoice(url: voice.preview_url) } label: { Image(systemName: "play.circle") }.help(L("Play existing voice preview")).disabled(voice.preview_url == nil)
                        Button(model.voiceID == voice.id ? L("Selected") : L("Select")) { model.chooseVoice(voice) }.disabled(model.voiceID == voice.id)
                        if voice.canEdit {
                            Menu {
                                Button(L("Edit Metadata")) { model.editName = voice.name; model.editDescription = voice.description ?? ""; model.editingVoice = voice }
                                Button(L("Delete Voice"), role: .destructive) { model.deleteVoice(voice) }
                            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                        }
                    }
                    if let description = voice.description, !description.isEmpty { Text(description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    if voice.is_owner == true { Text(L("Ownership confirmed by ElevenLabs")).font(.caption2).foregroundStyle(.secondary) }
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } }
        }.disabled(model.busy)
    }
    private var discoverView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(L("Find a voice on ElevenLabs"), L("Choose an available voice or browse the shared library to save more voices to your account."), icon: "globe")
            Picker(L("Browse voices"), selection: $model.discoverLibrary) {
                Text(L("Available ElevenLabs voices")).tag(false)
                Text(L("Shared voice library")).tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if !model.discoverLibrary {
                HStack {
                    TextField(L("Search voices"), text: $model.sharedSearch).textFieldStyle(.roundedBorder)
                    Button(L("Refresh"), action: model.refreshVoices).disabled(model.busy)
                }
                Text(L("Available ElevenLabs voices not saved to My Voices.")).font(.caption).foregroundStyle(.secondary)
                if model.visibleElevenLabsVoices.isEmpty {
                    empty(L("No voices to show"), L("Refresh to load voices for this source, or choose another source."), "globe")
                } else { accountVoiceRows(model.visibleElevenLabsVoices) }
            } else {
                HStack {
                    TextField(L("Search the voice library"), text: $model.sharedSearch).textFieldStyle(.roundedBorder).onSubmit { model.searchShared() }
                    TextField(L("Language filter (optional)"), text: $model.sharedLanguage).textFieldStyle(.roundedBorder).frame(width: 160)
                    Button(L("Search")) { model.searchShared() }.buttonStyle(.borderedProminent).disabled(model.busy)
                }
                if model.sharedVoices.isEmpty { empty(L("Explore the voice library"), L("Search to load voices from ElevenLabs. Voice availability and rates depend on your account and the voice."), "globe") }
                else {
                    ScrollView { LazyVStack(spacing: 10) { ForEach(model.sharedVoices) { voice in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(voice.name).font(.headline)
                                    Text([voice.language, voice.accent, voice.gender, voice.category].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { model.previewVoice(url: voice.preview_url) } label: { Label(L("Preview"), systemImage: "play.circle") }.disabled(voice.preview_url == nil)
                                Button(voice.canAdd ? L("Add to My Voices") : L("Added")) { model.addShared(voice) }.disabled(!voice.canAdd)
                            }
                            if let description = voice.description { Text(description).font(.callout).foregroundStyle(.secondary) }
                            if voice.free_users_allowed == false { Text(L("This voice is unavailable to free accounts.")).font(.caption).foregroundStyle(.secondary) }
                            if let rate = voice.rate { Text(L("API-reported voice rate: %@", String(rate))).font(.caption2).foregroundStyle(.secondary) }
                        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    } } }.disabled(model.busy)
                    if model.sharedMore { Button(L("Load More")) { model.searchShared(more: true) }.disabled(model.busy) }
                }
            }
        }
    }
    private var createVoiceView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading(L("Create a voice for your library"), L("Voice Design creates a synthetic voice. Instant Voice Cloning creates a voice from recordings you have permission to use."), icon: "person.badge.plus")
                Picker(L("Creation method"), selection: $model.voiceCreationMode) { Text(L("Voice Design")).tag("design"); Text(L("Instant Voice Clone")).tag("clone") }.pickerStyle(.segmented).disabled(model.recorder.isBusy)
                TextField(L("Voice name"), text: $model.voiceName).textFieldStyle(.roundedBorder)
                Text(L("Voice description")).font(.headline)
                TextEditor(text: $model.voiceDescription).frame(height: 100).padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                if model.voiceCreationMode == "design" {
                    Text(L("Describe age, accent, tone and delivery. Designing previews uses ElevenLabs credits.")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("Preview text (optional, 100–1000 characters)"), text: $model.designText, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...6)
                    Button(L("Generate Voice Previews"), action: model.designVoice).buttonStyle(.borderedProminent).disabled(!model.hasKey || model.voiceDescription.isEmpty)
                    ForEach(model.designPreviews) { preview in
                        HStack {
                            Button { model.playDesign(preview) } label: { Label(L("Play Preview"), systemImage: "play.circle") }
                            Text(preview.language ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Button(model.selectedDesign == preview.id ? L("Selected") : L("Select")) { model.selectedDesign = preview.id }
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !model.designPreviews.isEmpty { Button(L("Save Selected Voice"), action: model.saveDesign).disabled(model.voiceName.isEmpty).buttonStyle(.borderedProminent) }
                } else {
                    MicrophoneControls(recorder: model.recorder, record: model.recordCloneSample)
                    Text(L("Record one or more samples, or add audio files. Samples stay on this Mac until you press Create Voice Clone.")).font(.caption).foregroundStyle(.secondary)
                    Button(L("Choose Voice Samples…"), action: model.pickCloneSamples).disabled(model.recorder.isBusy)
                    ForEach(model.cloneSamples, id: \.path) { url in
                        HStack {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.previewCloneSample(url) } label: { Label(L("Play Preview"), systemImage: "play.circle") }
                            Button { model.removeCloneSample(url) } label: { Image(systemName: "xmark.circle") }.help(L("Remove sample from this list"))
                        }.font(.callout).disabled(model.recorder.isBusy)
                    }
                    Toggle(L("Remove background noise"), isOn: $model.removeNoise)
                    Toggle(L("I have the right and consent to clone the voice in these recordings."), isOn: $model.cloneConsent)
                    if model.account?.can_use_instant_voice_cloning == false { Text(L("Your subscription reports that Instant Voice Cloning is unavailable.")).foregroundStyle(.secondary) }
                    Button(L("Create Voice Clone"), action: model.cloneVoice).buttonStyle(.borderedProminent)
                        .disabled(!model.hasKey || model.voiceName.isEmpty || model.cloneSamples.isEmpty || !model.cloneConsent || model.recorder.isBusy || model.account?.can_use_instant_voice_cloning == false)
                    Text(L("ElevenLabs may require additional verification. Voice creation and Text to Speech are separate operations.")).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.busy)
        }
    }
    private var transcriptionView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading(L("Turn a recording into text"), L("Transcribe with ElevenLabs Scribe. This preserves the spoken language; it does not translate the recording."), icon: "text.quote")
            AudioSourceView(model: model, recordEnabled: false)
            HStack {
                TextField(L("Language code (optional; automatic when empty)"), text: $model.transcriptLanguage).textFieldStyle(.roundedBorder)
                Toggle(L("Detect speakers"), isOn: $model.diarize)
                Button(L("Transcribe"), action: model.transcribe).buttonStyle(.borderedProminent).disabled(!model.hasKey || model.sourceAudio == nil)
            }
            TextEditor(text: $model.transcript).font(.body).padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2))).accessibilityLabel(L("Transcription"))
            HStack { Text(L("Scribe v2 · transcription uses your account quota")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L("Export Text…"), action: model.exportTranscript).disabled(model.transcript.isEmpty) }
        }.disabled(model.busy)
    }
    private var isolationView: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(L("Bring speech into focus"), L("ElevenLabs Audio Isolation removes background sounds from an existing recording. It does not change the speaker or the words."), icon: "waveform.badge.mic")
            AudioSourceView(model: model, recordEnabled: false)
            formatControls.frame(maxWidth: 400)
            Spacer()
            HStack { Text(L("Processing uses your ElevenLabs credits.")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L("Isolate Speech"), action: model.isolate).buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.hasKey || model.sourceAudio == nil) }
        }.disabled(model.busy)
    }
    private var dubbingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading(L("Translate and dub audio"), L("Dubbing creates translated speech in a target language. It is separate from Voice Changer and multilingual Text to Speech."), icon: "captions.bubble")
                AudioSourceView(model: model, recordEnabled: false)
                HStack {
                    TextField(L("Source language code (empty = automatic)"), text: $model.dubbingSourceLanguage).textFieldStyle(.roundedBorder)
                    TextField(L("Target language code, e.g. en, pl, ja"), text: $model.dubbingTargetLanguage).textFieldStyle(.roundedBorder)
                }
                Text(L("Language support and project access are validated by ElevenLabs. Creating a project starts a billable server job; closing this app does not cancel it.")).font(.caption).foregroundStyle(.secondary)
                Button(L("Create Dubbing Project"), action: model.createDubbing).buttonStyle(.borderedProminent).disabled(!model.hasKey || model.sourceAudio == nil || model.dubbingTargetLanguage.isEmpty)
                Divider()
                HStack {
                    TextField(L("Dubbing project ID"), text: $model.dubbingProjectID).textFieldStyle(.roundedBorder)
                    Button(L("Refresh Status"), action: model.refreshDubbing).disabled(model.dubbingProjectID.isEmpty)
                }
                if let project = model.dubbingProject {
                    LabeledContent(L("Project status"), value: project.status)
                    if let error = project.error { Text(error.error).foregroundStyle(.red) }
                }
                if let target = model.dubbingTarget {
                    LabeledContent(L("Target language"), value: target.target_language)
                    LabeledContent(L("Target status"), value: target.status)
                    if let error = target.error { Text(error.error).foregroundStyle(.red) }
                    ForEach(target.warnings ?? [], id: \.message) { Text($0.message).foregroundStyle(.secondary) }
                    if target.outputs?.lossless_audio != nil { Button(L("Download Dubbed Audio"), action: model.downloadDubbing).buttonStyle(.borderedProminent) }
                }
                formatControls.frame(maxWidth: 350)
            }.disabled(model.busy)
        }
    }
    private var libraryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading(L("Your audio, ready to use"), L("Local recordings remain on this Mac. ElevenLabs history is loaded separately using your API permissions."), icon: "music.note.list")
                Text(L("On this Mac")).font(.title3.bold())
                if model.localRecordings.isEmpty { Text(L("Your generated recordings will appear here.")).foregroundStyle(.secondary) }
                ForEach(model.localRecordings) { recording in
                    HStack {
                        Image(systemName: "waveform").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recording.title).font(.headline)
                            Text(L(recording.kind) + " · " + recording.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.play(recording) } label: { Image(systemName: "play.circle") }.help(L("Play recording"))
                        Button { model.exportAudio(recording) } label: { Image(systemName: "square.and.arrow.up") }.help(L("Save audio to another location"))
                        Button { NSWorkspace.shared.activateFileViewerSelecting([recording.url]) } label: { Image(systemName: "folder") }.help(L("Reveal in Finder"))
                    }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                HStack { Text(L("ElevenLabs History")).font(.title3.bold()); Spacer(); Button(L("Load History")) { model.refreshHistory() }.disabled(model.busy) }
                ForEach(model.historyItems) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.voice_name ?? item.source ?? L("Recording")).font(.headline)
                            Text(item.text ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Text(Date(timeIntervalSince1970: TimeInterval(item.date_unix)).formatted()).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Download")) { model.downloadHistory(item) }.disabled(model.busy)
                    }.padding(10)
                    Divider()
                }
                if model.historyMore { Button(L("Load More")) { model.refreshHistory(more: true) }.disabled(model.busy) }
            }
        }
    }
    private var batchView: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L("Process a collection"), L("Import files or drop a folder. Nothing is generated until you start the queue."), icon: "square.stack.3d.up")
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Picker(L("Batch input"), selection: $model.batchAudio) { Text(L("Text / subtitles")).tag(false); Text(L("Audio / Voice Changer")).tag(true) }.pickerStyle(.segmented).labelsHidden()
                            .disabled(!model.jobs.isEmpty).frame(maxWidth: 360)
                        Button(L("Import…"), action: model.chooseBatchFiles)
                        Button(L("Clear Queue")) { model.jobs = [] }.disabled(model.jobs.isEmpty)
                    }.disabled(model.busy)
                    HStack {
                        Image(systemName: "folder")
                        Text(model.batchDestination?.path ?? L("Save next to each source file")).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L("Destination…"), action: model.chooseBatchDestination)
                        if model.batchDestination != nil { Button(L("Reset")) { model.batchDestination = nil; model.refreshJobOutputs() } }
                    }.disabled(model.busy)
                    if model.jobs.isEmpty { empty(L("Drop your files here"), L("TXT, SRT and VTT are supported. Subtitle timing is ignored. Folders are scanned without subfolders."), "doc.on.doc") }
                    else {
                        List(model.jobs) { item in
                            HStack {
                                Image(systemName: item.state == .done || item.state == .existing ? "checkmark.circle" : item.state == .failed || item.state == .invalid ? "exclamationmark.circle" : "doc")
                                    .foregroundStyle(item.state == .failed || item.state == .invalid ? Color.red : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.url.lastPathComponent).fontWeight(.medium)
                                    Text(L(item.detail)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if item.state == .done { Button { model.play(LocalRecording(title: item.url.deletingPathExtension().lastPathComponent, path: item.output(model.format).path, kind: "Batch Jobs")) } label: { Image(systemName: "play.circle") } }
                            }.padding(.vertical, 5)
                        }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text(L("Existing results are never overwritten. Another existing format is converted locally without regenerating voice or expression; rename the source for a new performance.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(L("%d jobs ready", model.readyJobs.count)).font(.caption)
                        Spacer()
                        Button(L("Start Batch"), action: model.startBatch).buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.readyJobs.isEmpty)
                    }
                }
                voiceControls.frame(width: 265)
            }
        }
    }
    private func empty(_ title: String, _ description: String, _ image: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: image).font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(description).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
    private var editVoiceSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Edit Voice Metadata")).font(.title2.bold())
            TextField(L("Voice name"), text: $model.editName).textFieldStyle(.roundedBorder)
            TextField(L("Voice description"), text: $model.editDescription, axis: .vertical).lineLimit(4...8).textFieldStyle(.roundedBorder)
            HStack { Button(L("Cancel")) { model.editingVoice = nil }; Spacer(); Button(L("Save"), action: model.saveVoiceMetadata).buttonStyle(.borderedProminent).disabled(model.editName.isEmpty || model.busy) }
        }.padding(24).frame(width: 460)
    }
}

struct AudioSourceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: MicrophoneRecorder
    let recordEnabled: Bool
    init(model: AppModel, recordEnabled: Bool) { self.model = model; self.recorder = model.recorder; self.recordEnabled = recordEnabled }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.sourceAudio?.lastPathComponent ?? L("Import a source recording")).font(.headline).lineLimit(2)
                    Text(L("MP3, WAV, M4A or FLAC · drag and drop supported")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Import Audio…"), action: model.importAudio).disabled(recorder.isBusy)
            }
            if recordEnabled { MicrophoneControls(recorder: recorder, record: model.record) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MicrophoneControls: View {
    @ObservedObject var recorder: MicrophoneRecorder
    let record: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if recorder.devices.isEmpty {
                    Label(L("No microphones available"), systemImage: "mic.slash").foregroundStyle(.secondary)
                } else {
                    Picker(L("Microphone"), selection: $recorder.selectedDeviceID) {
                        Text(L("System default input")).tag("")
                        if !recorder.selectedDeviceID.isEmpty && !recorder.selectedInputAvailable {
                            Text(L("Disconnected microphone")).tag(recorder.selectedDeviceID)
                        }
                        ForEach(recorder.devices) { Text($0.name).tag($0.id) }
                    }.disabled(recorder.isBusy)
                }
                Button { recorder.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("Refresh microphones")).disabled(recorder.isBusy)
            }
            HStack {
                Button(action: record) {
                    Label(recorder.isRecording ? L("Stop Recording") : L("Record Microphone"), systemImage: recorder.isRecording ? "stop.circle.fill" : "mic")
                }.disabled(recorder.isFinishing || recorder.isRequestingPermission || (!recorder.isRecording && !recorder.selectedInputAvailable))
                if recorder.isRequestingPermission || recorder.isFinishing {
                    ProgressView().controlSize(.small)
                    Text(recorder.isFinishing ? L("Saving recording…") : L("Preparing microphone…")).font(.caption)
                }
                if recorder.isRequestingPermission { Button(L("Cancel")) { recorder.cancel() } }
                if recorder.isRecording {
                    Text(L("Recording %.0f s", recorder.elapsed)).monospacedDigit().foregroundStyle(.red)
                    ProgressView(value: recorder.level).frame(width: 100).accessibilityLabel(L("Microphone level"))
                }
            }
            Text(L("Built-in and external microphones supported · up to 5 minutes per sample")).font(.caption).foregroundStyle(.secondary)
            if let error = recorder.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.onAppear { recorder.refreshDevices() }
    }
}

struct AudioPlayerView: View {
    @ObservedObject var player: AudioPlayerModel
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: player.togglePlayback) { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 29)) }.buttonStyle(.plain).accessibilityLabel(player.isPlaying ? L("Pause") : L("Play"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.sourceURL == model.result?.url ? (model.result?.title ?? L("Recording")) : L("Audio preview")).font(.headline)
                    Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...max(0.1, player.duration)).accessibilityLabel(L("Playback position"))
                }
                Text(String(format: "%d:%02d / %d:%02d", Int(player.currentTime) / 60, Int(player.currentTime) % 60, Int(player.duration) / 60, Int(player.duration) % 60)).font(.caption.monospacedDigit())
                if player.sourceURL == model.result?.url { Button(L("Save Audio…")) { model.exportAudio() } }
                Button(action: player.clear) { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("Close player"))
            }
            if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(14).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Text("Voice Desk").font(.largeTitle.bold())
                Text(L("A native macOS client for the official ElevenLabs API. This is an independent application, not an official ElevenLabs product.")).foregroundStyle(.secondary)
            }
            Section(L("ElevenLabs API")) {
                SecureField(L("API key"), text: $model.keyDraft).textFieldStyle(.roundedBorder).accessibilityLabel(L("ElevenLabs API key"))
                HStack {
                    Button(model.hasKey ? L("Replace Key") : L("Save Key"), action: model.saveKey).disabled(model.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L("Validate Connection"), action: model.validateConnection).disabled(!model.hasKey)
                    Spacer()
                    Button(L("Remove Key"), role: .destructive, action: model.removeKey).disabled(!model.hasKey)
                }
                LabeledContent(L("Connection"), value: L(model.connection))
                Text(L("Keys are stored only in macOS Keychain. Each API feature needs its own permission. Missing permissions do not disable unrelated features.")).font(.caption).foregroundStyle(.secondary)
                Link(L("Manage API keys on ElevenLabs"), destination: URL(string: "https://elevenlabs.io/app/developers/api-keys")!)
            }.disabled(model.busy)
            Section(L("Account usage")) {
                if let account = model.account {
                    LabeledContent(L("Plan"), value: account.tier)
                    LabeledContent(L("Used / period allowance"), value: "\(account.character_count.formatted()) / \(account.character_limit.formatted())")
                    LabeledContent(L("Remaining period allowance"), value: account.remainingCharacters.formatted())
                    if let reset = account.next_character_count_reset_unix { LabeledContent(L("Next reset"), value: Date(timeIntervalSince1970: TimeInterval(reset)).formatted()) }
                    if let date = model.accountDate { Text(L("Last fetched: %@", date.formatted())).font(.caption).foregroundStyle(.secondary) }
                    Text(L("These values come from the subscription endpoint. They are not a quote for the next generation or a promise of feature access.")).font(.caption).foregroundStyle(.secondary)
                } else { Text(L("Validate the connection to fetch current subscription usage. The key must allow access to user information.")).foregroundStyle(.secondary) }
            }
            Section(L("Application")) {
                Picker(L("Interface language"), selection: $model.interfaceLanguage) { Text("English").tag("en"); Text("Polski").tag("pl") }
                Text(L("Changing the interface language never changes the language of generated speech.")).font(.caption).foregroundStyle(.secondary)
                Picker(L("Default output format"), selection: $model.format) { ForEach(OutputFormat.allCases, id: \.self) { Text($0.label).tag($0) } }
                Text(L("Voice, model and speech-language choices are saved from the generation screen. Audio is kept locally until you export it.")).font(.caption).foregroundStyle(.secondary)
                Button(L("Open Local Audio Folder")) { if let folder = try? AppStorageFiles.directory("Audio") { NSWorkspace.shared.open(folder) } }
            }
            Section(L("About")) {
                Text(L("Voice Desk 2.0 · macOS 14 or later · Apple Silicon"))
                Text(L("MP3 encoding uses LAME under LGPL 2.0 or later. The source distribution includes LAME sources and build instructions.")).font(.caption).foregroundStyle(.secondary)
                Link(L("ElevenLabs API documentation"), destination: URL(string: "https://elevenlabs.io/docs/api-reference")!)
            }
        }.formStyle(.grouped)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.persistPreferences()
        guard let model, model.busy || model.recorder.isBusy else { return .terminateNow }
        if model.confirm(title: L("Stop the current operation and quit?"), message: L("Completed files are kept. A request already sent to ElevenLabs may still use credits. Server-side dubbing jobs keep running."), action: L("Quit")) {
            model.cancel()
            guard model.recorder.isBusy else { return .terminateNow }
            model.recorder.stop()
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(15)
                while model.recorder.isBusy && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                if model.recorder.isBusy { model.error = L("The recording is still being saved. Try quitting again when it finishes.") }
                sender.reply(toApplicationShouldTerminate: !model.recorder.isBusy)
            }
            return .terminateLater
        }
        return .terminateCancel
    }
}

@main
struct VoiceDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Voice Desk", id: "main") {
            ContentView(model: model).onAppear { delegate.model = model }
        }.defaultSize(width: 1260, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Import Text…"), action: model.importText).keyboardShortcut("o").disabled(model.busy || model.recorder.isBusy)
                Button(L("Import Audio…"), action: model.importAudio).keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy || model.recorder.isBusy)
            }
            CommandGroup(replacing: .appSettings) { Button(L("Settings")) { model.page = .settings }.keyboardShortcut(",") }
            CommandMenu(L("Audio")) {
                Button(L("Generate Speech"), action: model.generateSpeech).keyboardShortcut(.return, modifiers: .command).disabled(model.page != .speech || !model.canGenerate || model.text.isEmpty || model.recorder.isBusy)
                Button(L("Play / Pause"), action: model.player.togglePlayback).keyboardShortcut("p", modifiers: [.command, .shift])
                Button(L("Save Audio…")) { model.exportAudio() }.keyboardShortcut("s").disabled(model.result == nil)
            }
        }
    }
}

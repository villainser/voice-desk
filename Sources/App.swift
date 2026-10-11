import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class FolderModel: ObservableObject {
    @Published var folder: URL?
    @Published var items: [FileItem] = []
    @Published var key = ""
    @Published var rememberKey = true
    @Published var voices: [Voice] = []
    @Published var voiceID = ""
    @Published var modelID = "eleven_multilingual_v2"
    @Published var mode: InputMode = .folder
    @Published var format: OutputFormat = .m4a
    @Published var expression = ExpressionSettings()
    @Published var removeNoise = false
    @Published var draftText = ""
    @Published var draftName = "nagranie"
    @Published var fetching = false
    @Published var scanning = false
    @Published var running = false
    @Published var status = "Wybierz folder z tekstami."
    @Published var connection = ""
    @Published var error: String?
    @Published var fraction: Double = 0
    @Published var folderDropTargeted = false
    private var job: Task<Void, Never>?
    private var scanID = UUID()
    var ready: [FileItem] {
        if mode == .text { return draftItem.map { [$0] } ?? [] }
        return items.filter { $0.state == .ready || $0.state == .failed }
    }
    var draftItem: FileItem? {
        guard let folder, !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draftName.contains("/"), !draftName.contains(":"), !draftName.hasPrefix("."),
              draftName.utf8.count <= 180, draftName.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = folder.appendingPathComponent(draftName + ".txt")
        return FileItem(url: url, characters: text.unicodeScalars.count,
            parts: TextFiles.chunks(text).count, fingerprint: TextFiles.digest(text), inlineText: text)
    }
    var characterCount: Int { ready.reduce(0) { $0 + (mode == .text || $1.existingAudio(except: format) == nil ? $1.characters : 0) } }
    var completed: Int { items.filter { $0.state == .done || $0.state == .existing }.count }
    var cleanKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanVoice: String { voiceID.trimmingCharacters(in: .whitespacesAndNewlines) }
    var needsAPI: Bool { mode == .text || ready.contains { $0.existingAudio(except: format) == nil } }
    var canStart: Bool { !running && !fetching && !scanning && !ready.isEmpty && (!needsAPI || (!cleanKey.isEmpty && !cleanVoice.isEmpty)) }
    var activeModel: String { mode == .changer ? "eleven_multilingual_sts_v2" : modelID }
    var isExpressiveModel: Bool { modelID == "eleven_v3" || modelID.hasPrefix("eleven_v4") }

    init() {
        key = KeyStore.read() ?? ""
        if !key.isEmpty { connection = "Klucz wczytany z pęku kluczy" }
        voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? ""
        modelID = UserDefaults.standard.string(forKey: "modelID") ?? "eleven_multilingual_v2"
        format = OutputFormat(rawValue: UserDefaults.standard.string(forKey: "format") ?? "m4a") ?? .m4a
        if let data = UserDefaults.standard.data(forKey: "expression"), let value = try? JSONDecoder().decode(ExpressionSettings.self, from: data) { expression = value }
        if let data = UserDefaults.standard.data(forKey: "voices"), let value = try? JSONDecoder().decode([Voice].self, from: data) { voices = value }
        if let path = UserDefaults.standard.string(forKey: "folder"), FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
            Task { await rescan() }
        }
    }
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = mode == .text ? "Wybierz folder zapisu" : "Wybierz folder z plikami"
        panel.message = mode == .changer ? "Wyniki trafią do podfolderu Voice Changer." : "Nagrania trafią do wybranego folderu."
        panel.prompt = "Wybierz folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { setFolder(url) }
    }
    func setFolder(_ url: URL) {
        guard !running, !scanning else { return }
        do {
            guard url.isFileURL else { throw AppFailure("Przeciągnij folder z Findera.") }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true else {
                throw AppFailure("Przeciągnij zwykły folder z Findera.")
            }
            folder = url.standardizedFileURL
            UserDefaults.standard.set(folder!.path, forKey: "folder")
            // Block Start immediately, before the asynchronous scan begins.
            items = []; scanning = true; error = nil
            Task { await rescan() }
        } catch { self.error = error.localizedDescription }
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !running, !scanning else { return false }
        guard providers.count == 1,
              let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            error = "Przeciągnij jeden folder."
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
            let url: URL?
            if let value = item as? URL { url = value }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else if let text = item as? String { url = URL(string: text) }
            else { url = nil }
            Task { @MainActor [weak self] in
                guard let self, !self.running, !self.scanning else { return }
                guard error == nil, let url else {
                    self.error = "Nie udało się odczytać folderu. Przeciągnij go ponownie lub użyj przycisku Wybierz folder."
                    return
                }
                self.setFolder(url)
            }
        }
        return true
    }
    func rescan() async {
        guard let folder, !running else { return }
        let token = UUID(); scanID = token
        if mode == .text { scanning = false; error = nil; fraction = 0; status = "Wpisz tekst i nazwę nagrania. Generowanie rozpocznie się po kliknięciu Start."; return }
        let inputMode = mode, selectedFormat = format
        scanning = true; error = nil; fraction = 0
        status = "Wczytuję pliki…"
        do {
            let list = try await Task.detached {
                try inputMode == .changer ? AudioSources.scan(folder, format: selectedFormat) : TextFiles.scan(folder, format: selectedFormat)
            }.value
            guard scanID == token else { return }
            items = list
            status = list.isEmpty ? "W tym folderze nie ma pasujących plików." : "\(ready.count) plików do przetworzenia · \(completed) nagrań już istnieje"
        } catch {
            guard scanID == token else { return }
            items = []; self.error = error.localizedDescription; status = "Nie udało się wczytać folderu."
        }
        scanning = false
    }
    func persistSettings() throws {
        if rememberKey && !cleanKey.isEmpty { try KeyStore.save(cleanKey) } else if !rememberKey { KeyStore.delete() }
        savePreferences()
    }
    func savePreferences() {
        UserDefaults.standard.set(cleanVoice, forKey: "voiceID")
        UserDefaults.standard.set(modelID, forKey: "modelID")
        UserDefaults.standard.set(format.rawValue, forKey: "format")
        UserDefaults.standard.set(try? JSONEncoder().encode(expression), forKey: "expression")
        UserDefaults.standard.set(try? JSONEncoder().encode(voices), forKey: "voices")
    }
    func sourceChanged() {
        guard !running else { return }
        items = []; fraction = 0
        if folder != nil { scanning = true; Task { await rescan() } }
        savePreferences()
    }
    func fetchVoices() {
        guard !cleanKey.isEmpty, !running, !fetching else { return }
        error = nil; fetching = true; connection = "Łączę z ElevenLabs…"
        let client = ElevenClient(key: cleanKey)
        Task {
            defer { fetching = false }
            do {
                let list = try await client.voices()
                voices = list
                if voiceID.isEmpty, let first = list.first { voiceID = first.id }
                try persistSettings()
                connection = "Połączono · \(list.count) głosów"
            } catch { self.error = error.localizedDescription; connection = "Nie udało się połączyć" }
        }
    }
    func forgetKey() {
        KeyStore.delete(); key = ""; voices = []; connection = "Klucz usunięty z aplikacji"
    }
    func update(_ id: String, state: FileState, detail: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].state = state; items[index].detail = detail }
    }
    func report(_ id: String, part: Int, total: Int, done: Int, batchTotal: Int, message: String) {
        update(id, state: .working, detail: message)
        if mode == .text { status = message }
        fraction = min(1, Double(done + part) / Double(max(batchTotal, 1)))
    }
    func start() {
        guard canStart else { return }
        do { try persistSettings() } catch { self.error = error.localizedDescription; return }
        let queue = ready
        if mode == .text, let item = queue.first,
           OutputFormat.allCases.contains(where: { FileManager.default.fileExists(atPath: item.output($0).path) }) {
            error = "Nagranie o tej nazwie już istnieje. Wpisz nową nazwę, aby wygenerować nowy tekst lub inną ekspresję."; return
        }
        let client = ElevenClient(key: cleanKey)
        let settings = GenerationSettings(voiceID: cleanVoice, modelID: activeModel, format: format, expression: expression, removeNoise: mode == .changer && removeNoise)
        running = true; error = nil; fraction = 0
        status = "Rozpoczynam generowanie…"
        let total = queue.reduce(0) { $0 + $1.parts }
        job = Task.detached { [weak self] in
            var done = 0, files = 0
            for item in queue {
                if Task.isCancelled { break }
                await self?.setStatus("\(files + 1)/\(queue.count) · \(item.url.lastPathComponent)")
                await self?.update(item.id, state: .working, detail: "Przygotowuję…")
                do {
                    let completedParts = done
                    let generated = try await BatchProcessor.process(item, settings: settings, client: client) { [weak self] part, count, message in
                        await self?.report(item.id, part: part, total: count, done: completedParts, batchTotal: total, message: message)
                    }
                    await self?.update(item.id, state: generated ? .done : .existing,
                        detail: generated ? item.output(settings.format).lastPathComponent : "Nagranie już istnieje — pomijam")
                    done += item.parts; files += 1
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        await self?.update(item.id, state: .ready, detail: "Zatrzymano — można wznowić")
                    } else {
                        await self?.update(item.id, state: .failed, detail: "Błąd — szczegóły poniżej")
                        await self?.setError(item.url.lastPathComponent + ": " + error.localizedDescription)
                    }
                    break
                }
            }
            await self?.finish(files: files, total: queue.count, stopped: Task.isCancelled)
        }
    }
    private func setStatus(_ text: String) { status = text }
    private func setError(_ text: String) { error = text }
    private func finish(files: Int, total: Int, stopped: Bool) {
        running = false; job = nil
        if stopped { status = "Zatrzymano. Zapisane części zostaną użyte przy wznowieniu." }
        else if error != nil { status = "Przerwano po błędzie. Gotowe nagrania i pobrane części są zachowane." }
        else { status = "Gotowe · przetworzono \(files) z \(total) plików"; fraction = 1 }
    }
    func stop() { status = "Zatrzymuję…"; job?.cancel() }
    func showFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}

struct ContentView: View {
    @ObservedObject var model: FolderModel
    private let accent = Color(red: 0.82, green: 0.30, blue: 0.13)
    var body: some View {
        HStack(spacing: 0) {
            settingsPanel.frame(width: 300)
            Divider()
            mainPanel
        }
        .onChange(of: model.mode) { _, _ in model.sourceChanged() }
        .onChange(of: model.format) { _, _ in model.sourceChanged() }
        .onChange(of: model.voiceID) { _, _ in model.savePreferences() }
        .onChange(of: model.modelID) { _, _ in model.savePreferences() }
        .onChange(of: model.expression) { _, _ in model.savePreferences() }
        .tint(accent)
        .frame(minWidth: 980, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.folderDropTargeted) { providers in
            model.acceptDrop(providers)
        }
        .overlay {
            if model.folderDropTargeted && !model.running && !model.scanning {
                RoundedRectangle(cornerRadius: 12)
                    .fill(accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6])))
                    .overlay(alignment: .top) {
                        Label("Upuść folder, aby go wybrać", systemImage: "folder.badge.plus")
                            .font(.headline).padding(14)
                            .background(.regularMaterial, in: Capsule()).padding(.top, 18)
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }
    private var settingsPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 24, weight: .medium)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder → Głos").font(.system(size: 20, weight: .semibold))
                    Text("TWÓJ TEKST. TWÓJ GŁOS.").font(.system(size: 9, weight: .medium)).tracking(1.1).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 10) {
                Text("Konto ElevenLabs").font(.headline)
                SecureField("Wklej klucz API", text: $model.key)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Klucz API ElevenLabs")
                Toggle("Zapamiętaj w pęku kluczy", isOn: $model.rememberKey).font(.caption)
                HStack {
                    Button(action: model.fetchVoices) {
                        if model.fetching { ProgressView().controlSize(.small) }
                        else { Text("Pobierz głosy") }
                    }.disabled(model.cleanKey.isEmpty || model.fetching)
                    Spacer()
                    Button("Usuń klucz", action: model.forgetKey).buttonStyle(.link).font(.caption).disabled(model.cleanKey.isEmpty || model.fetching)
                }
                if !model.connection.isEmpty { Text(model.connection).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Głos i model").font(.headline)
                if !model.voices.isEmpty {
                    Picker("Głos", selection: $model.voiceID) {
                        if !model.voices.contains(where: { $0.id == model.voiceID }) { Text("Własny Voice ID").tag(model.voiceID) }
                        ForEach(model.voices) { Text($0.name).tag($0.id) }
                    }.labelsHidden().accessibilityLabel("Głos ElevenLabs")
                }
                TextField("Voice ID", text: $model.voiceID).textFieldStyle(.roundedBorder)
                    .help("Możesz wkleić Voice ID ręcznie, jeśli klucz nie ma uprawnienia Voices: Read.")
                if model.mode != .changer {
                Picker("Model", selection: $model.modelID) {
                    Text("Multilingual v2 · narracja").tag("eleven_multilingual_v2")
                    Text("Flash v2.5 · szybki").tag("eleven_flash_v2_5")
                    Text("Eleven v3 · ekspresyjny").tag("eleven_v3")
                    Text("Eleven v4").tag("eleven_v4")
                }.labelsHidden().accessibilityLabel("Model ElevenLabs")
                } else { Text("Voice Changer · Multilingual v2").font(.caption).foregroundStyle(.secondary) }
                Text("Wybierz głos obsługujący język Twoich tekstów.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Format zapisu").font(.headline)
                Picker("Format audio", selection: $model.format) {
                    ForEach(OutputFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Text(model.format == .wav ? "WAV PCM 16-bit. Źródłem jest MP3 128 kb/s z API — zapis WAV nie podnosi jakości źródła." : "MP3 128 kb/s lub M4A / AAC 128 kb/s.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            expressionPanel
            Divider()
            Text("Start wysyła tekst lub audio bezpośrednio do ElevenLabs i zużywa kredyty Twojego konta. Gotowe pliki nie są nadpisywane.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Ustawienia kluczy ElevenLabs ↗", destination: URL(string: "https://elevenlabs.io/app/developers/api-keys")!).font(.caption)
        }
        .padding(22)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .disabled(model.running)
    }
    private var expressionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Własna ekspresja", isOn: $model.expression.enabled).font(.headline)
            if model.expression.enabled {
                if model.mode != .changer && model.modelID == "eleven_v3" {
                    Picker("Stabilność", selection: $model.expression.stability) {
                        Text("Kreatywna").tag(0.0)
                        Text("Naturalna").tag(0.5)
                        Text("Stabilna").tag(1.0)
                    }
                    .onAppear { model.expression.stability = (model.expression.stability * 2).rounded() / 2 }
                } else {
                    settingSlider("Stabilność", value: $model.expression.stability)
                    Text("Mniej = większa zmienność i emocje.").font(.caption2).foregroundStyle(.secondary)
                    settingSlider("Podobieństwo głosu", value: $model.expression.similarity)
                }
                if model.mode == .changer || !model.isExpressiveModel {
                    settingSlider("Wzmocnienie stylu", value: $model.expression.style)
                    if model.mode != .changer {
                        HStack { Text("Tempo"); Spacer(); Text(String(format: "%.2f×", model.expression.speed)).monospacedDigit() }.font(.caption)
                        Slider(value: $model.expression.speed, in: 0.7...1.2, step: 0.05).accessibilityLabel("Tempo mowy")
                    }
                    Toggle("Wzmocnij podobieństwo", isOn: $model.expression.speakerBoost).font(.caption)
                }
                if model.mode != .changer && model.isExpressiveModel {
                    Picker("Sposób mówienia", selection: $model.expression.delivery) {
                        Text("Z tekstu / bez dodatku").tag("")
                        Text("Szept").tag("whispers")
                        Text("Podekscytowanie").tag("excited")
                        Text("Ciekawość").tag("curious")
                        Text("Smutek").tag("sad")
                        Text("Złość").tag("angry")
                        Text("Sarkazm").tag("sarcastic")
                    }
                    Text("Wybrana wskazówka zostanie dodana przed każdą częścią tekstu. Efekt zależy od głosu; możesz też używać znaczników [whispers] w tekście.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Użyj ustawień zapisanych przy głosie w ElevenLabs.").font(.caption).foregroundStyle(.secondary)
            }
            if model.mode == .changer {
                Toggle("Usuń szum tła", isOn: $model.removeNoise).font(.caption)
                Text("Słowa, tempo i emocje pochodzą z nagrania wejściowego.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func settingSlider(_ label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 4) {
            HStack { Text(label); Spacer(); Text("\(Int(value.wrappedValue * 100))%").monospacedDigit() }.font(.caption)
            Slider(value: value, in: 0...1, step: 0.05).accessibilityLabel(label)
        }
    }
    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.mode == .text ? "Twój tekst, wybrany głos" : model.mode == .changer ? "Zmień głos nagrania" : "Z folderu do nagrania").font(.system(size: 26, weight: .semibold))
                    Text(model.mode == .changer ? "Audio → wybrany głos. Maksymalnie 5 minut na plik." : model.mode == .text ? "Wpisz tekst. Wybierz głos. Zapisz gotowe audio." : "Przeciągnij folder tutaj. Wybierz głos. Kliknij Start.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.format.label).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(accent.opacity(0.10), in: Capsule()).foregroundStyle(accent)
            }
            Picker("Źródło", selection: $model.mode) {
                ForEach(InputMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().disabled(model.running || model.scanning)
            folderCard
            if model.mode == .text {
                textEditor
            } else {
            HStack(spacing: 28) {
                metric("\(model.items.count)", model.mode == .changer ? "PLIKI AUDIO" : "PLIKI TXT")
                if model.mode == .changer {
                    metric(String(format: "%.1f", model.ready.reduce(0) { $0 + $1.duration } / 60), "MINUTY AUDIO")
                } else {
                    metric(model.characterCount.formatted(.number.locale(Locale(identifier: "pl_PL"))), "ZNAKI DO WYSŁANIA")
                }
                metric("\(model.completed)", "GOTOWE / POMINIĘTE")
                Spacer()
            }.padding(.vertical, 3)
            queueView
            Text(model.mode == .changer ? "Wyniki: podfolder Voice Changer, nazwa jak plik wejściowy." : "Istniejące nagranie w innym formacie jest konwertowane bez API, bez zmiany głosu i ekspresji. Dla nowej wersji użyj nowej nazwy TXT.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(error).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Zamknij komunikat")
                }.padding(12).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 9) {
                if model.running || model.fraction > 0 { ProgressView(value: model.fraction) }
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.status).font(.caption).fixedSize(horizontal: false, vertical: true)
                        if !model.running && model.mode != .text { Text("Podfoldery nie są przetwarzane.").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 10)
                    if model.running {
                        Button("Zatrzymaj", action: model.stop).controlSize(.large)
                            .help("Przerywa kolejkę. Rozpoczęte żądanie może już zużyć kredyty.")
                    } else {
                        Button(action: model.start) { Label(model.mode == .text ? "Generuj i zapisz" : "Start · \(model.ready.count) plików", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canStart)
                    }
                }
            }
        }.padding(28)
    }
    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Nazwa nagrania", text: $model.draftName).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Nazwa nagrania bez rozszerzenia")
                Text(".\(model.format.rawValue)").foregroundStyle(.secondary)
            }
            TextEditor(text: $model.draftText).font(.system(size: 15))
                .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                .accessibilityLabel("Tekst do wygenerowania")
            HStack {
                Text("\(model.draftText.unicodeScalars.count.formatted()) znaków")
                Spacer()
                Text("Pełne nagranie bez etapu podglądu")
            }.font(.caption).foregroundStyle(.secondary)
            Text("Nowy tekst generujesz wybranym głosem przez Text to Speech. Voice Changer służy do zmiany głosu w istniejącym audio.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(model.running).frame(maxHeight: .infinity)
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
        }
    }
    private var folderCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill").font(.system(size: 27)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.folder?.lastPathComponent ?? (model.mode == .text ? "Wybierz folder zapisu" : "Przeciągnij folder z plikami")).font(.headline)
                Text(model.folder?.path ?? "rozdzial-01.txt → rozdzial-01.\(model.format.rawValue)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.folder?.path ?? "Nagrania będą zapisane obok tekstów.")
            }
            Spacer(minLength: 6)
            if model.folder != nil {
                Button { Task { await model.rescan() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Odśwież listę plików").accessibilityLabel("Odśwież").disabled(model.running || model.scanning)
                Button(action: model.showFolder) { Image(systemName: "arrow.up.forward.square") }.help("Otwórz folder w Finderze").accessibilityLabel("Otwórz folder w Finderze")
            }
            Button(model.folder == nil ? "Wybierz folder…" : "Zmień…", action: model.selectFolder).disabled(model.running || model.scanning)
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
    private var queueView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PLIK ŹRÓDŁOWY"); Spacer(); Text("POSTĘP")
            }.font(.system(size: 10, weight: .medium)).tracking(0.7).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if model.scanning {
                Spacer(); ProgressView("Wczytuję pliki…"); Spacer()
            } else if model.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text").font(.system(size: 36, weight: .light)).foregroundStyle(accent.opacity(0.8))
                    Text(model.folder == nil ? "Twoje pliki pojawią się tutaj" : "Brak pasujących plików").font(.headline)
                    Text(model.mode == .changer ? "Wybierz folder z MP3, WAV, M4A, FLAC lub AIFF.\nChcesz nowe słowa? Przejdź do Wpisz tekst." : "Każdy tekst stanie się osobnym nagraniem.\nDługie pliki są dzielone i łączone automatycznie.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            HStack(spacing: 12) {
                                Image(systemName: icon(item.state)).foregroundStyle(color(item.state)).frame(width: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).help(item.url.lastPathComponent)
                                    Text(item.isAudio ? String(format: "%.1f s · %@", item.duration, item.url.pathExtension.uppercased()) : "\(item.characters.formatted()) znaków · \(item.parts) części").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                Text(item.detail).font(.caption).foregroundStyle(color(item.state)).lineLimit(2).multilineTextAlignment(.trailing).frame(maxWidth: 250, alignment: .trailing).help(item.detail)
                            }.padding(.horizontal, 16).padding(.vertical, 13)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 170, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
    private func icon(_ state: FileState) -> String {
        switch state {
        case .ready: return "doc.text"
        case .working: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .existing: return "checkmark.circle"
        case .invalid, .failed: return "exclamationmark.circle"
        }
    }
    private func color(_ state: FileState) -> Color {
        switch state {
        case .working: return accent
        case .done: return .green
        case .invalid, .failed: return .red
        default: return .secondary
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: FolderModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.savePreferences()
        guard let model, model.running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Trwa generowanie nagrania"
        alert.informativeText = "Zakończenie przerwie kolejkę. Pobrane części pozostaną do wznowienia. Rozpoczęte żądanie może już zużyć kredyty."
        alert.addButton(withTitle: "Kontynuuj pracę")
        alert.addButton(withTitle: "Zatrzymaj i zakończ")
        if alert.runModal() == .alertSecondButtonReturn { model.stop(); return .terminateNow }
        return .terminateCancel
    }
}

@main
struct FolderVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = FolderModel()
    var body: some Scene {
        Window("Folder → Głos", id: "main") {
            ContentView(model: model).onAppear { delegate.model = model }
        }
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Wybierz folder…", action: model.selectFolder).keyboardShortcut("o").disabled(model.running)
                Button("Odśwież pliki") { Task { await model.rescan() } }.keyboardShortcut("r").disabled(model.running || model.folder == nil)
            }
        }
    }
}

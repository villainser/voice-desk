import Foundation

@main
struct LocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
        Localizer.resourceRoot = root
        let previous = UserDefaults.standard.object(forKey: Localizer.preferenceKey)
        let previousSpeechLanguage = UserDefaults.standard.object(forKey: "speechLanguage")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: Localizer.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: Localizer.preferenceKey) }
            if let previousSpeechLanguage { UserDefaults.standard.set(previousSpeechLanguage, forKey: "speechLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "speechLanguage") }
        }

        UserDefaults.standard.set("ja", forKey: "speechLanguage")
        UserDefaults.standard.set("en", forKey: Localizer.preferenceKey)
        precondition(L("Settings") == "Settings")
        UserDefaults.standard.set("pl", forKey: Localizer.preferenceKey)
        precondition(L("Settings") == "Ustawienia")
        precondition(L("%@ characters", "120") == "Liczba znaków: 120")
        precondition(L("Unknown localization test key") == "Unknown localization test key")
        UserDefaults.standard.set("en", forKey: Localizer.preferenceKey)
        precondition(L("%@ characters", "120") == "120 characters")
        precondition(L("Settings") == "Settings")
        precondition(UserDefaults.standard.string(forKey: Localizer.preferenceKey) == "en")
        precondition(UserDefaults.standard.string(forKey: "speechLanguage") == "ja")
        print("PASS: English/Polish catalogs, immediate switching, persistence, independent speech language, formatting, fallback")
    }
}

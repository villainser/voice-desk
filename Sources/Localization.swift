import Foundation

enum Localizer {
    static let preferenceKey = "interfaceLanguage"
    static let supportedLanguages = ["en", "pl"]

    // Tests use the same native strings catalogs without constructing an app bundle.
    static var resourceRoot: URL?

    static var language: String {
        if let selected = UserDefaults.standard.string(forKey: preferenceKey), supportedLanguages.contains(selected) {
            return selected
        }
        for preferred in Locale.preferredLanguages {
            let code = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if supportedLanguages.contains(code) { return code }
        }
        return "en"
    }

    static func string(_ key: String, arguments: [CVarArg] = []) -> String {
        let selected = language
        let root = resourceRoot ?? Bundle.main.resourceURL
        let languageBundle = root.flatMap { Bundle(url: $0.appendingPathComponent("\(selected).lproj", isDirectory: true)) }
        let format = languageBundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: selected), arguments: arguments)
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localizer.string(key, arguments: arguments)
}

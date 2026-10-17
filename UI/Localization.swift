import Foundation

enum L10n {
    static func text(_ key: String, language: UILanguage = .system) -> String {
        let code = language.localeIdentifier
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}

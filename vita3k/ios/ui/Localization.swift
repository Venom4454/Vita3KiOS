import Foundation

/// The text in the player's language (Localizable.strings in es.lproj, fr.lproj, ...): for strings
/// that aren't SwiftUI literals (which SwiftUI looks up by itself), such as UIKit menus and titles
/// kept in data. Text with no translation stays English.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

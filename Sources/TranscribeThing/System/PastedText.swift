import Foundation

/// What the app pastes, shaped by General → Pasting: a dictation's paste, Paste Last and a card's Paste Here. History,
/// the cards and every Copy keep the text as the model wrote it.
enum PastedText {
    /// `removesFinalPeriod`: a text that ends in exactly one period loses it ("Hello." → "Hello"). An ellipsis ("...",
    /// "…"), "?", "!", a closing quote or bracket after the period, and a lone "." stay as they are.
    /// `addsSpace`: then one space goes after any text, so what is said next doesn't run into it.
    static func prepare(_ text: String, addsSpace: Bool, removesFinalPeriod: Bool) -> String {
        var result = text
        if removesFinalPeriod, result.count > 1, result.hasSuffix("."), !result.hasSuffix("..") {
            result.removeLast()
        }
        if addsSpace, !result.isEmpty { result += " " }
        return result
    }
}

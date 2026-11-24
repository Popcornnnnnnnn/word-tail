public enum BilingualSpacingGuard {
    // Mirrors WordCompleter's private leading boundary set.
    private static let standardLeadingBoundaries = Set(" \t([{\"'“‘")
    private static let cjkPunctuation = Set("，。！？；：、（）【】《》「」『』“”‘’・〜")

    public static func isCJKCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF,
             0x3040...0x309F, 0x30A0...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    public static func isCJKPunctuation(_ ch: Character) -> Bool {
        if cjkPunctuation.contains(ch) { return true }
        guard let scalar = ch.unicodeScalars.first?.value else { return false }
        switch scalar {
        case 0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF60:
            return true
        default:
            return false
        }
    }

    public static func shouldAllowLeadingBoundary(_ boundary: Character, bilingualEnabled: Bool) -> Bool {
        standardLeadingBoundaries.contains(boundary)
            || (bilingualEnabled && (isCJKCharacter(boundary) || isCJKPunctuation(boundary)))
    }

    public static func shouldAllowTrailingBoundary(_ boundary: Character, bilingualEnabled: Bool) -> Bool {
        bilingualEnabled && (isCJKCharacter(boundary) || isCJKPunctuation(boundary))
    }

    public static func needsLeadingSpace(
        beforeWordStartBoundary boundary: Character?,
        bilingualSpacingEnabled: Bool
    ) -> Bool {
        guard bilingualSpacingEnabled, let boundary else { return false }
        return isCJKCharacter(boundary) && !isCJKPunctuation(boundary)
    }

    public static func needsTrailingSpace(
        charAfterCursor after: Character?,
        appendSpacePreference: Bool,
        bilingualSpacingEnabled: Bool
    ) -> Bool {
        if let after {
            if isCJKPunctuation(after) { return false }
            if bilingualSpacingEnabled && isCJKCharacter(after) { return true }
        }
        return WordCompleter.shouldAppendSpaceOnTab(
            charAfterCursor: after,
            appendSpacePreference: appendSpacePreference
        )
    }
}

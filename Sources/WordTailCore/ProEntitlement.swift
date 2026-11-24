import Foundation

public enum WordTailProFeature: String, CaseIterable, Identifiable, Codable, Sendable {
    case domainLexiconPacks
    case snippetStudio
    case appWritingProfiles
    case bilingualSpacing
    case wrappedAndReports

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .domainLexiconPacks: return "Domain Vocabulary Packs"
        case .snippetStudio: return "Parameterized Snippets & Macros"
        case .appWritingProfiles: return "Per-App Writing Profiles"
        case .bilingualSpacing: return "Bilingual CJK–English Smart Spacing"
        case .wrappedAndReports: return "Typing Wrapped Posters & CSV/MD Export"
        }
    }

    public var subtitle: String {
        switch self {
        case .domainLexiconPacks:
            return "Six curated domain packs plus custom .wordtailpack JSON import & export."
        case .snippetStudio:
            return "Explicit prefix triggers with {date}, {time}, {iso}, {clipboard}, and {cursor} macros."
        case .appWritingProfiles:
            return "Override capitalization, auto-correct, bilingual spacing, and packs per app."
        case .bilingualSpacing:
            return "Mixed CJK–English completion boundaries and smart spacing while keeping IMEs quiet."
        case .wrappedAndReports:
            return "High-res Light/Dark 3:4 & 16:9 Typing Wrapped posters plus CSV and Markdown exports."
        }
    }

    public var symbol: String {
        switch self {
        case .domainLexiconPacks: return "books.vertical"
        case .snippetStudio: return "text.insert"
        case .appWritingProfiles: return "macwindow.on.rectangle"
        case .bilingualSpacing: return "character.bubble"
        case .wrappedAndReports: return "doc.richtext"
        }
    }
}

public struct ProLicensePayload: Codable, Equatable, Sendable {
    public var version: Int
    public var tier: String
    public var plan: String
    public var email: String
    public var issuedAt: Int64
    public var licenseID: String

    public init(
        version: Int = 1,
        tier: String = "pro",
        plan: String = "lifetime",
        email: String,
        issuedAt: Int64,
        licenseID: String
    ) {
        self.version = version
        self.tier = tier
        self.plan = plan
        self.email = email
        self.issuedAt = issuedAt
        self.licenseID = licenseID
    }
}

public enum ProEntitlementState: Equatable, Sendable {
    case free
    case trial(daysRemaining: Int, expiresAt: Date)
    case licensed(ProLicensePayload)
}

public protocol ProEntitlementProviding: AnyObject {
    var entitlementState: ProEntitlementState { get }
    var isProUnlocked: Bool { get }
    func isUnlocked(_ feature: WordTailProFeature) -> Bool
}

public extension ProEntitlementProviding {
    var isProUnlocked: Bool {
        switch entitlementState {
        case .free:
            return false
        case .trial, .licensed:
            return true
        }
    }

    func isUnlocked(_ feature: WordTailProFeature) -> Bool {
        isProUnlocked
    }
}

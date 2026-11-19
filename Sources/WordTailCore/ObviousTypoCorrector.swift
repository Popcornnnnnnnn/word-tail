import AppKit
import Foundation

public struct MinimalDiffEdit: Equatable, Sendable {
    public let deleteCount: Int
    public let insertText: String

    public init(deleteCount: Int, insertText: String) {
        self.deleteCount = deleteCount
        self.insertText = insertText
    }
}

public enum CorrectionRuleSource: String, Codable, Equatable, Sendable {
    case custom = "Custom"
    case learned = "Learned"
    case muted = "Muted"
}

public struct CorrectionRuleEntry: Identifiable, Equatable, Sendable {
    public var id: String { "\(source.rawValue):\(trigger)" }
    public let trigger: String
    public let replacement: String
    public let count: Int
    public let source: CorrectionRuleSource

    public init(trigger: String, replacement: String, count: Int, source: CorrectionRuleSource) {
        self.trigger = trigger
        self.replacement = replacement
        self.count = count
        self.source = source
    }
}

/// Persistent, self-learning store for user shorthand rules, auto-learned typo pairs, and undo-muted triggers.
public final class AdaptiveCorrectionStore {
    private struct PersistedData: Codable {
        var customRules: [String: String] = [:]          // user-defined trigger -> replacement
        var candidatePairs: [String: [String: Int]] = [:] // observed mistype -> target -> count (graduates at >= 2)
        var undoCounts: [String: Int] = [:]               // trigger -> number of Backspace undos (mutes at >= 2)
        var mutedTriggers: Set<String> = []
    }

    public static let graduationThreshold = 2
    public static let muteUndoThreshold = 2

    private let fileURL: URL
    private let queue = DispatchQueue(label: "app.wordtail.macos.corrections", qos: .utility)
    private var state = PersistedData()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("WordTail", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("adaptive_corrections.json")
        }
        loadSynchronously()
    }

    private func loadSynchronously() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PersistedData.self, from: data) else {
            return
        }
        state = decoded
    }

    public func isMuted(_ rawTrigger: String) -> Bool {
        let key = rawTrigger.lowercased()
        return queue.sync { state.mutedTriggers.contains(key) }
    }

    public func customOrLearnedReplacement(for rawTrigger: String) -> String? {
        let key = rawTrigger.lowercased()
        return queue.sync {
            if let custom = state.customRules[key] {
                return custom
            }
            if state.mutedTriggers.contains(key) {
                return nil
            }
            if let targets = state.candidatePairs[key],
               let best = targets.max(by: { $0.value < $1.value }),
               best.value >= Self.graduationThreshold {
                return best.key
            }
            return nil
        }
    }

    /// Returns a matching custom or learned rule when `typedPrefix` matches either the full trigger or a `>= 4`-char prefix of a mistype.
    public func inlineCandidate(forTypedPrefix rawPrefix: String) -> String? {
        let lower = rawPrefix.lowercased()
        return queue.sync {
            if let custom = state.customRules[lower] {
                return custom
            }
            guard !state.mutedTriggers.contains(lower) else { return nil }
            if let targets = state.candidatePairs[lower],
               let best = targets.max(by: { $0.value < $1.value }),
               best.value >= 1 {
                return best.key
            }
            guard lower.count >= 4 else { return nil }
            var foundTargets = Set<String>()
            for (mistype, targetMap) in state.candidatePairs where mistype.hasPrefix(lower) && !state.mutedTriggers.contains(mistype) {
                if let best = targetMap.max(by: { $0.value < $1.value }), best.value >= 1, !best.key.lowercased().hasPrefix(lower) {
                    foundTargets.insert(best.key)
                }
            }
            return foundTargets.count == 1 ? foundTargets.first : nil
        }
    }

    /// Records a user correction observation (from Backspace repair or explicit `Tab` on a typo fix).
    /// Once observed `>= 2` times, it automatically activates on `Space`!
    public func recordObservedCorrection(mistype rawMistype: String, corrected rawCorrected: String, persistAsync: Bool = true) {
        let mistype = rawMistype.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let corrected = rawCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mistype.count >= 2, mistype.count <= 24,
              corrected.count >= 2, corrected.count <= 32,
              mistype != corrected.lowercased(),
              !ObviousTypoCorrector.developerSafeWords.contains(mistype),
              !TypingHabitTracker.defaultValidEnglishWordCheck(mistype) else {
            return
        }

        let work = {
            guard !self.state.mutedTriggers.contains(mistype) else { return }
            var map = self.state.candidatePairs[mistype] ?? [:]
            map[corrected, default: 0] += 1
            self.state.candidatePairs[mistype] = map
            if self.state.candidatePairs.count > 250 {
                let sorted = self.state.candidatePairs.sorted {
                    ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0)
                }.prefix(180)
                self.state.candidatePairs = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
            }
            self.persistLocked()
        }
        if persistAsync { queue.async(execute: work) } else { queue.sync(execute: work) }
    }

    /// Records that the user pressed `Backspace` right after `Space` auto-corrected `rawTrigger`.
    /// After `2` undos, `rawTrigger` is automatically muted so WordTail never re-corrects it behind the user's back!
    @discardableResult
    public func recordUndo(forTrigger rawTrigger: String, persistAsync: Bool = true) -> Bool {
        let key = rawTrigger.lowercased()
        return queue.sync {
            state.undoCounts[key, default: 0] += 1
            let nowMuted = state.undoCounts[key, default: 0] >= Self.muteUndoThreshold
            if nowMuted {
                state.mutedTriggers.insert(key)
            }
            if persistAsync {
                let snap = state
                queue.async { [weak self] in self?.writeSnapshot(snap) }
            } else {
                persistLocked()
            }
            return nowMuted
        }
    }

    @discardableResult
    public func addCustomRule(trigger rawTrigger: String, replacement rawReplacement: String, persistAsync: Bool = true) -> Bool {
        let trigger = rawTrigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replacement = rawReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trigger.count >= 2, trigger.count <= 24,
              replacement.count >= 1, replacement.count <= 48,
              trigger != replacement.lowercased(),
              trigger.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) else {
            return false
        }
        let work = {
            self.state.mutedTriggers.remove(trigger)
            self.state.undoCounts.removeValue(forKey: trigger)
            self.state.customRules[trigger] = replacement
            self.persistLocked()
        }
        if persistAsync { queue.async(execute: work) } else { queue.sync(execute: work) }
        return true
    }

    public func removeRuleOrUnmute(trigger rawTrigger: String) {
        let key = rawTrigger.lowercased()
        queue.sync {
            state.customRules.removeValue(forKey: key)
            state.candidatePairs.removeValue(forKey: key)
            state.mutedTriggers.remove(key)
            state.undoCounts.removeValue(forKey: key)
            persistLocked()
        }
    }

    public func allEntries() -> [CorrectionRuleEntry] {
        queue.sync {
            var list: [CorrectionRuleEntry] = []
            for (trig, rep) in state.customRules {
                list.append(CorrectionRuleEntry(trigger: trig, replacement: rep, count: 0, source: .custom))
            }
            for (trig, targetMap) in state.candidatePairs where state.customRules[trig] == nil && !state.mutedTriggers.contains(trig) {
                if let best = targetMap.max(by: { $0.value < $1.value }), best.value >= Self.graduationThreshold {
                    list.append(CorrectionRuleEntry(trigger: trig, replacement: best.key, count: best.value, source: .learned))
                }
            }
            for muted in state.mutedTriggers where state.customRules[muted] == nil {
                let origTarget = ObviousTypoCorrector.unambiguousTypos[muted]
                    ?? state.candidatePairs[muted]?.max(by: { $0.value < $1.value })?.key
                    ?? "auto-fix"
                list.append(CorrectionRuleEntry(trigger: muted, replacement: origTarget, count: state.undoCounts[muted, default: 2], source: .muted))
            }
            return list.sorted { lhs, rhs in
                if lhs.source != rhs.source {
                    let order: [CorrectionRuleSource: Int] = [.custom: 0, .learned: 1, .muted: 2]
                    return (order[lhs.source] ?? 9) < (order[rhs.source] ?? 9)
                }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.trigger < rhs.trigger
            }
        }
    }

    public func clearAll() {
        queue.sync {
            state = PersistedData()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func persistLocked() {
        writeSnapshot(state)
    }

    private func writeSnapshot(_ snap: PersistedData) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

public enum ObviousTypoCorrector {
    /// Non-English developer identifiers, CLI binaries, and file formats that should never be auto-corrected or capitalized.
    public static let developerSafeWords: Set<String> = [
        "repo", "repos", "init", "inits", "config", "configs", "cfg", "env", "envs",
        "arg", "args", "kwarg", "kwargs", "param", "params", "async", "impl", "impls",
        "util", "utils", "auth", "authn", "authz", "oauth", "jwt", "sso", "rbac", "cors",
        "kubectl", "helm", "docker", "podman", "orbstack", "pytest", "pydantic", "fastapi",
        "uvicorn", "gunicorn", "celery", "numpy", "scipy", "pandas", "polars",
        "vite", "pnpm", "npm", "npx", "deno", "esbuild", "webpack", "eslint",
        "nvim", "vim", "neovim", "tmux", "zellij", "zsh", "bash", "ghostty", "iterm",
        "macos", "ios", "ipados", "watchos", "tvos", "xcode", "swiftc", "swiftui", "appkit",
        "uikit", "webkit", "coretext", "coregraphics", "avfoundation", "xctest",
        "wechat", "feishu", "lark", "dingtalk", "doubao", "bilibili", "xiaohongshu", "taobao",
        "raycast", "alfred", "codex", "claude", "gemini", "chatgpt", "deepseek", "qwen", "llama",
        "llm", "llms", "vlm", "rag", "lora", "qlora", "gguf", "mlx", "cuda", "mps",
        "gpu", "gpus", "cpu", "cpus", "npu", "tpu", "ram", "vram", "ssd", "nvme",
        "api", "apis", "rpc", "grpc", "graphql", "url", "urls", "uri", "uris",
        "json", "jsonl", "yaml", "yml", "toml", "xml", "csv", "tsv", "parquet", "protobuf",
        "sql", "nosql", "sqlite", "postgres", "mysql", "redis", "kafka", "clickhouse", "supabase",
        "cli", "sdk", "sdks", "ide", "ides", "gui", "tui", "ui", "ux", "dx", "id", "ids",
        "pr", "prs", "mr", "mrs", "ci", "cd", "cicd", "devops", "sre",
        "ssh", "tls", "mtls", "ssl", "http", "https", "tcp", "udp", "quic", "dns", "ip", "vpc",
        "aws", "gcp", "azure", "cloudflare", "vercel", "netlify", "railway", "k8s",
        "wasm", "wasi", "simd", "rgba", "srgb", "utf", "ascii", "regex", "regexp", "cron",
        "sudo", "chmod", "chown", "grep", "ripgrep", "awk", "sed", "curl", "wget", "jq", "yq",
        "brew", "git", "diffs", "worktree", "subagent", "subagents",
        "ls", "cp", "mv", "rm", "mkdir", "cmake", "python", "python3", "cargo", "gh",
        "todo", "todos", "fixme", "noop", "bool", "int", "uint", "str", "dict", "vec",
        "idx", "len", "prev", "curr", "src", "dst", "tmp", "temp", "dir", "dirs", "pkg", "pkgs",
        "dev", "devs", "prod", "stg", "qa", "perf", "spec", "specs", "docs", "readme",
        "wip", "poc", "mvp", "kpi", "okr", "eta", "fyi", "tbh", "imo", "imho", "afaik", "lgtm",
        "pls", "plz", "thx", "nvm", "idk", "ikr", "smh", "lmao", "hodl", "saas", "paas", "iaas",
        "onnx", "uuid", "uids", "conf", "confs", "sync", "awesun", "todesk", "rustdesk", "anydesk", "tailscale",
        "keystat", "keystats", "wordtail", "nihao", "xie", "xiexie", "shanghai", "beijing", "shenzhen",
        "iphone", "ipad", "airpods", "imac", "macbook", "ebay"
    ]

    /// Valid 1- and 2-letter English words (rejected by `>= 3`-char spellcheckers, but valid sentence starters & standalone words).
    public static let validShortEnglishWords: Set<String> = [
        "a", "i", "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi",
        "if", "in", "is", "it", "me", "my", "no", "of", "oh", "ok", "on", "or",
        "so", "to", "up", "us", "we"
    ]

    private static let nonSentenceEndingAbbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "prof", "sr", "jr",
        "st", "ave", "inc", "ltd", "co", "corp", "fig", "eq", "vol", "no", "ch", "cf", "al"
    ]

    /// Comprehensive built-in dictionary of contractions, joined-word slips, transpositions, and misspellings.
    public static let unambiguousTypos: [String: String] = [
        // First-person contractions & capitalization patterns ("im" -> "I'm", "ive" -> "I've", "i'll" -> "I'll")
        "im": "I'm",
        "i'm": "I'm",
        "ive": "I've",
        "i've": "I've",
        "i'll": "I'll",
        "i'd": "I'd",
        "id'": "I'd",

        // High-frequency apostrophe contractions
        "dont": "don't",
        "doesnt": "doesn't",
        "didnt": "didn't",
        "isnt": "isn't",
        "arent": "aren't",
        "wasnt": "wasn't",
        "werent": "weren't",
        "wont": "won't",
        "cant": "can't",
        "couldnt": "couldn't",
        "wouldnt": "wouldn't",
        "shouldnt": "shouldn't",
        "mustnt": "mustn't",
        "havent": "haven't",
        "hasnt": "hasn't",
        "hadnt": "hadn't",
        "thats": "that's",
        "whats": "what's",
        "whos": "who's",
        "wheres": "where's",
        "heres": "here's",
        "theres": "there's",
        "hows": "how's",
        "whens": "when's",
        "whys": "why's",
        "youre": "you're",
        "youve": "you've",
        "youll": "you'll",
        "youd": "you'd",
        "theyre": "they're",
        "theyve": "they've",
        "theyll": "they'll",
        "theyd": "they'd",
        "weve": "we've",
        "hes": "he's",
        "shes": "she's",
        "itll": "it'll",
        "aint": "ain't",
        "yall": "y'all",

        // Joined two-word slips ("alot" -> "a lot", "thankyou" -> "thank you")
        "alot": "a lot",
        "atleast": "at least",
        "aswell": "as well",
        "infact": "in fact",
        "incase": "in case",
        "noone": "no one",
        "thankyou": "thank you",
        "eachother": "each other",
        "evenif": "even if",
        "ofcourse": "of course",
        "bytheway": "by the way",

        // High-frequency transpositions & fast-typing slips
        "aslo": "also", "alos": "also",
        "similat": "similar", "similiar": "similar", "simlar": "similar",
        "teh": "the", "hte": "the", "thge": "the",
        "taht": "that", "thta": "that",
        "adn": "and", "nad": "and", "anbd": "and", "cna": "can",
        "wiht": "with", "iwth": "with", "wtih": "with",
        "thier": "their", "theri": "their",
        "abotu": "about", "baout": "about", "abuot": "about",
        "knwo": "know", "konw": "know", "kno": "know", "nkow": "know",
        "jsut": "just", "jstu": "just",
        "liek": "like", "liuke": "like",
        "tahn": "than", "thna": "than",
        "chekc": "check", "chek": "check", "checkign": "checking",
        "yuo": "you", "yoru": "your", "yuor": "your",
        "waht": "what", "hwat": "what",
        "whcih": "which", "whihc": "which", "wich": "which",
        "woudl": "would", "owuld": "would",
        "coudl": "could", "oculd": "could",
        "shoudl": "should", "shuold": "should", "shoud": "should",
        "firts": "first", "fisrt": "first",
        "agian": "again", "agin": "again",
        "beacuse": "because", "becuase": "because", "becasue": "because", "beause": "because", "cuz": "because",
        "ahve": "have", "hvae": "have", "haev": "have",
        "tihs": "this", "htis": "this",
        "fomr": "from", "frmo": "from",
        "peopel": "people", "poeple": "people",
        "workd": "world", "wolrd": "world", "worls": "world",
        "thign": "thing", "hting": "thing", "thigns": "things", "tihngs": "things",
        "otehr": "other", "ohter": "other",
        "verison": "version", "vresion": "version",
        "probelm": "problem", "porblem": "problem", "problme": "problem", "problms": "problems", "probelms": "problems",
        "sentance": "sentence", "sentances": "sentences",
        "pattren": "pattern", "parttern": "pattern", "partterns": "patterns",
        "slef": "self", "esle": "else", "ture": "true", "flase": "false", "fasle": "false",
        "retrun": "return", "reutrn": "return",
        "chnage": "change", "chaneg": "change", "chnages": "changes",
        "updateing": "updating", "createing": "creating", "deleteing": "deleting",
        "makeing": "making", "takeing": "taking", "comming": "coming", "writting": "writing", "begining": "beginning",
        "runing": "running", "stoping": "stopping", "geting": "getting", "puting": "putting", "seting": "setting",

        // Classic English misspellings
        "definately": "definitely", "definatly": "definitely", "definetly": "definitely", "definitly": "definitely",
        "recieve": "receive", "recieved": "received", "recieving": "receiving", "recevie": "receive",
        "seperate": "separate", "seperated": "separated", "seperately": "separately", "seperating": "separating",
        "occured": "occurred", "occuring": "occurring", "occurence": "occurrence", "ocurred": "occurred",
        "untill": "until",
        "wierd": "weird",
        "acheive": "achieve", "acheived": "achieved", "acheiving": "achieving",
        "beleive": "believe", "beleived": "believed", "belive": "believe",
        "calender": "calendar",
        "accomodate": "accommodate", "acommodate": "accommodate",
        "enviroment": "environment", "enviroments": "environments", "enviornment": "environment",
        "goverment": "government",
        "neccessary": "necessary", "necesary": "necessary", "nessecary": "necessary",
        "tommorow": "tomorrow", "tomorow": "tomorrow", "tmrw": "tomorrow",
        "immediatly": "immediately", "imediately": "immediately",
        "embarass": "embarrass", "embarassing": "embarrassing",
        "existance": "existence",
        "apparentely": "apparently", "aparently": "apparently",
        "basicly": "basically", "basicaly": "basically",
        "actualy": "actually", "actaully": "actually", "acutally": "actually",
        "probaly": "probably", "probalby": "probably", "porbably": "probably",
        "honsetly": "honestly",
        "realy": "really", "relaly": "really",
        "finaly": "finally", "fianlly": "finally",
        "usally": "usually", "usualy": "usually",
        "truely": "truly",
        "arguement": "argument", "arguements": "arguments",
        "independant": "independent",
        "maintainance": "maintenance", "maintenence": "maintenance",
        "noticable": "noticeable",
        "persistant": "persistent",
        "priviledge": "privilege",
        "recomend": "recommend", "recomended": "recommended", "reccommend": "recommend",
        "refered": "referred", "refering": "referring",
        "succesful": "successful", "succesfully": "successfully", "successfull": "successful",
        "suprise": "surprise", "suprised": "surprised",
        "collegue": "colleague", "collegues": "colleagues",
        "knowlege": "knowledge",
        "langauge": "language", "lanugage": "language",
        "lenght": "length", "widht": "width", "heigth": "height", "strnegth": "strength",
        "buisness": "business", "busines": "business",
        "questionaire": "questionnaire", "oppurtunity": "opportunity", "opprotunity": "opportunity",
        "diffrent": "different", "diferent": "different", "intresting": "interesting", "intersting": "interesting",

        // Common CS & technical prose misspellings
        "algoritm": "algorithm", "algoritms": "algorithms",
        "asychronous": "asynchronous", "asyncronous": "asynchronous", "syncronous": "synchronous",
        "parrallel": "parallel", "paralell": "parallel",
        "configuraiton": "configuration", "implementaiton": "implementation",
        "documentaiton": "documentation", "autentication": "authentication", "authorizaiton": "authorization",
        "reporsitory": "repository", "dependancy": "dependency", "dependancies": "dependencies",
        "performace": "performance", "compatability": "compatibility",
        "availibility": "availability", "reproducable": "reproducible", "herustic": "heuristic",
        "architecure": "architecture", "infrastruture": "infrastructure", "optmize": "optimize", "optmization": "optimization"
    ]

    /// Computes minimal backspace + suffix edit between `source` and `target` so the editor only replaces
    /// the diverging tail (`"definately"` -> `"definitely"` deletes 5 chars `"ately"` and inserts `"itely"`).
    public static func minimalDiff(from source: String, to target: String) -> MinimalDiffEdit {
        let sChars = Array(source)
        let tChars = Array(target)
        var common = 0
        let limit = min(sChars.count, tChars.count)
        while common < limit && sChars[common] == tChars[common] {
            common += 1
        }
        let deleteCount = sChars.count - common
        let insertText = String(tChars[common..<tChars.count])
        return MinimalDiffEdit(deleteCount: deleteCount, insertText: insertText)
    }

    public static func isApostrophe(_ ch: Character) -> Bool {
        ch == "'" || ch == "’"
    }

    public static func normalizeApostrophes(_ text: String) -> String {
        text.contains("’") ? text.replacingOccurrences(of: "’", with: "'") : text
    }

    public static func isValidSentenceStarterWord(
        _ rawWord: String,
        validWordChecker: (String) -> Bool = TypingHabitTracker.defaultValidEnglishWordCheck
    ) -> Bool {
        let lower = normalizeApostrophes(rawWord).lowercased()
        guard !lower.isEmpty else { return false }
        if validShortEnglishWords.contains(lower)
            || validWordChecker(lower)
            || TechLexicon.wordSet.contains(lower) {
            return true
        }
        // Contractions & possessives ("this's", "that's", "don't", "doesn't", "today's", "that'll"):
        // Validate the base stem BEFORE the apostrophe instead of deleting "'" into invalid "thiss"/"todays"!
        if lower.contains("'") {
            for clitic in ["'s", "'d", "'ll", "'re", "'ve", "'m"] where lower.hasSuffix(clitic) {
                let stem = String(lower.dropLast(clitic.count))
                if validShortEnglishWords.contains(stem)
                    || validWordChecker(stem)
                    || TechLexicon.wordSet.contains(stem) {
                    return true
                }
            }
            if lower.hasSuffix("n't") {
                let stem = String(lower.dropLast(3))
                if validShortEnglishWords.contains(stem) || validWordChecker(stem) {
                    return true
                }
            }
        }
        return false
    }

    /// Unified `Space`-key transformation combining user/learned rules, high-confidence typo & contraction patterns,
    /// context-aware `"lets"` -> `"Let's"`, and sentence-start / standalone-"I" auto-capitalization.
    public static func spaceReplacement(
        forWord word: String,
        lineContextIncludingWord: String?,
        isAtDocumentStart: Bool = false,
        autoCorrectTypos: Bool,
        autoCapitalizeSentences: Bool,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        habitTracker: TypingHabitTracker?,
        historyStore: UserHistoryStore?,
        validWordChecker: (String) -> Bool = TypingHabitTracker.defaultValidEnglishWordCheck
    ) -> String? {
        guard !word.isEmpty, word.count <= 24 else { return nil }
        guard word.allSatisfy({ ($0.isASCII && $0.isLetter) || isApostrophe($0) }) else { return nil }

        // Never alter camelCase / mixedCase ("macOS", "iPhone", "useState") or ALL-CAPS ("API", "HTTP")
        if word.dropFirst().contains(where: \.isUppercase) {
            return nil
        }
        if word.count >= 2 && word.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return nil
        }

        let lower = normalizeApostrophes(word).lowercased()
        let atSentenceStart = isWordAtSentenceStart(
            word: word,
            inContextBeforeCursor: lineContextIncludingWord,
            isAtDocumentStart: isAtDocumentStart
        )

        // 1. User's explicit custom shorthand rules ALWAYS take priority (even over developerSafeWords if user defined one!)
        if autoCorrectTypos, let customOrLearned = adaptiveStore?.customOrLearnedReplacement(for: lower) {
            var res = adaptCase(of: customOrLearned, toTyped: word)
            if autoCapitalizeSentences && atSentenceStart, let f = res.first, f.isLowercase {
                res = res.prefix(1).uppercased() + res.dropFirst()
            }
            return res != word ? res : nil
        }

        // Respect triggers the user muted by undoing with Backspace twice!
        if adaptiveStore?.isMuted(lower) == true {
            return nil
        }

        if developerSafeWords.contains(lower) {
            return nil
        }

        var working = word

        // 2. Context-aware pattern: "lets" at the start of a sentence -> "Let's" (leaves "it lets you" untouched!)
        if autoCorrectTypos && lower == "lets" && atSentenceStart {
            working = "Let's"
        } else if autoCorrectTypos,
                  let typoFixed = spaceAutoCorrection(
                      forWord: working,
                      adaptiveStore: adaptiveStore,
                      habitTracker: habitTracker,
                      historyStore: historyStore
                  ) {
            working = typoFixed
        }

        // 3. Sentence-start capitalization + standalone "i" -> "I"
        if autoCapitalizeSentences {
            if working == "i" {
                working = "I"
            } else if let first = working.first, first.isLowercase, atSentenceStart {
                let firstWordPart = String(working.split(separator: " ").first ?? Substring(working))
                let isRealWord = (working != word)
                    || isValidSentenceStarterWord(firstWordPart, validWordChecker: validWordChecker)
                if isRealWord {
                    working = working.prefix(1).uppercased() + working.dropFirst()
                }
            }
        }

        return working != word ? working : nil
    }

    /// Fast O(1) pre-check deciding whether `Space` needs a synchronous live Accessibility read to resolve sentence-start capitalization.
    /// Skips cross-process AX IPC for ~90%+ of words (mid-sentence words preceded by `<letter/comma> `, already-capitalized words,
    /// developer/CLI safe tokens, muted triggers, and standalone `"i"`).
    public static func needsLiveSentenceContextOnSpace(
        forWord word: String,
        rollingBuffer: String,
        autoCorrectTypos: Bool,
        autoCapitalizeSentences: Bool,
        adaptiveStore: AdaptiveCorrectionStore? = nil
    ) -> Bool {
        guard !word.isEmpty, word.count <= 24 else { return false }
        guard word.allSatisfy({ ($0.isASCII && $0.isLetter) || isApostrophe($0) }) else { return false }
        if word.dropFirst().contains(where: \.isUppercase) { return false }
        if word.count >= 2 && word.allSatisfy({ !$0.isLetter || $0.isUppercase }) { return false }

        let lower = normalizeApostrophes(word).lowercased()
        if lower == "i" { return false } // "i" -> "I" unconditionally regardless of sentence position!
        if !autoCapitalizeSentences && !(autoCorrectTypos && lower == "lets") {
            return false
        }
        if let first = word.first, first.isUppercase {
            return false
        }
        if adaptiveStore?.customOrLearnedReplacement(for: lower) == nil {
            if adaptiveStore?.isMuted(lower) == true || developerSafeWords.contains(lower) {
                return false
            }
        }
        // If `rollingBuffer` already has `<word/comma> <typedWord>` on the current line without `.`, `!`, `?`,
        // `typedWord` is guaranteed mid-sentence (`isAtSentenceStart == false`) with zero AX IPC needed!
        if hasConfirmedMidSentencePredecessor(forWord: word, inBuffer: rollingBuffer) {
            return false
        }
        return true
    }

    public static func hasConfirmedMidSentencePredecessor(forWord word: String, inBuffer buffer: String) -> Bool {
        let normBuf = normalizeApostrophes(buffer).lowercased()
        let normWord = normalizeApostrophes(word).lowercased()
        guard normBuf.count > normWord.count + 1,
              normBuf.hasSuffix(normWord) else {
            return false
        }
        let chars = Array(buffer.dropLast(word.count))
        var i = chars.count
        var sawHorizontalSpace = false
        while i > 0 && (chars[i - 1] == " " || chars[i - 1] == "\t") {
            sawHorizontalSpace = true
            i -= 1
        }
        guard sawHorizontalSpace, i > 0 else { return false }
        let prev = chars[i - 1]
        // Preceded immediately by a normal word character or comma/semicolon -> guaranteed NOT after `.`, `!`, `?`, or doc start!
        return (prev.isASCII && prev.isLetter) || prev == "," || prev == ";" || prev == ":"
    }

    /// Returns true ONLY when:
    /// 1. `isAtDocumentStart` is true (the very first word at index 0 of the entire text field), OR
    /// 2. Preceding text before `word` ends with sentence-ending punctuation (`.`, `!`, `?`) followed by whitespace/newline.
    /// Soft-wrapped visual lines and plain line breaks (`\n`) without `.`, `!`, or `?` NEVER trigger sentence capitalization.
    public static func isWordAtSentenceStart(
        word: String,
        inContextBeforeCursor context: String?,
        isAtDocumentStart: Bool = false
    ) -> Bool {
        if isAtDocumentStart {
            return true
        }
        guard let context, !context.isEmpty else {
            return false
        }
        guard normalizeApostrophes(context).lowercased().hasSuffix(normalizeApostrophes(word).lowercased()) else {
            return false
        }

        let prefixBeforeWord = String(context.dropLast(word.count))
        // Must have at least one whitespace/newline separator after the sentence-ending punctuation
        guard let lastRaw = prefixBeforeWord.last, lastRaw.isWhitespace else {
            return false
        }

        // Strip trailing spaces, tabs, newlines, and closing quotes/brackets right after `.`, `!`, `?`
        let strippedRight = prefixBeforeWord.replacingOccurrences(
            of: "[ \\t\\r\\n\"'”’)\\]]+$",
            with: "",
            options: .regularExpression
        )
        guard let punct = strippedRight.last, punct == "." || punct == "!" || punct == "?" else {
            return false
        }

        if punct == "!" || punct == "?" {
            return true
        }

        let beforeDot = String(strippedRight.dropLast())
        guard let charBeforeDot = beforeDot.last, charBeforeDot.isLetter else {
            return false
        }

        let tokenChars = Array(beforeDot)
        var tokenStart = tokenChars.count
        while tokenStart > 0 && (tokenChars[tokenStart - 1].isLetter || tokenChars[tokenStart - 1] == ".") {
            tokenStart -= 1
        }
        let prevToken = String(tokenChars[tokenStart..<tokenChars.count]).lowercased()
        if prevToken.count <= 1 || nonSentenceEndingAbbreviations.contains(prevToken) {
            return false
        }
        return true
    }

    public static func spaceAutoCorrection(
        forWord word: String,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        habitTracker: TypingHabitTracker?,
        historyStore: UserHistoryStore?,
        spellCompleter: SpellCompleting = SystemSpellCompleter()
    ) -> String? {
        let lower = word.lowercased()
        if adaptiveStore?.isMuted(lower) == true {
            return nil
        }
        if let customOrLearned = adaptiveStore?.customOrLearnedReplacement(for: lower) {
            return adaptCase(of: customOrLearned, toTyped: word)
        }

        guard isEligibleTypoToken(word, minLength: 2, historyStore: historyStore) else {
            return nil
        }

        if let fixed = unambiguousTypos[lower] {
            return adaptCase(of: fixed, toTyped: word)
        }

        if let personalFix = habitTracker?.learnedAutoFix(forMistype: lower),
           !developerSafeWords.contains(lower),
           !TypingHabitTracker.defaultValidEnglishWordCheck(lower) {
            return adaptCase(of: personalFix, toTyped: word)
        }

        // General single-edit QWERTY / transposition / missing-letter spell-checker fallback on Space
        // (catches any obvious slip like "similat" -> "similar", "aslo" -> "also", "checkign" -> "checking"
        // while keeping 3-letter acronyms, 4-letter non-transpositions like "vite"/"cuda", and proper nouns like "awesun" untouched!)
        if lower.count >= 4,
           !TypingHabitTracker.defaultValidEnglishWordCheck(lower),
           let spellFixed = conservativeSpaceSpellFix(forLowerWord: lower, spellCompleter: spellCompleter) {
            return adaptCase(of: spellFixed, toTyped: word)
        }

        return nil
    }

    private static let qwertyNeighbors: [Character: Set<Character>] = [
        "q": ["w", "a"],
        "w": ["q", "e", "a", "s"],
        "e": ["w", "r", "s", "d"],
        "r": ["e", "t", "d", "f"],
        "t": ["r", "y", "f", "g"],
        "y": ["t", "u", "g", "h"],
        "u": ["y", "i", "h", "j"],
        "i": ["u", "o", "j", "k"],
        "o": ["i", "p", "k", "l"],
        "p": ["o", "l"],
        "a": ["q", "w", "s", "z"],
        "s": ["w", "e", "a", "d", "z", "x"],
        "d": ["e", "r", "s", "f", "x", "c"],
        "f": ["r", "t", "d", "g", "c", "v"],
        "g": ["t", "y", "f", "h", "v", "b"],
        "h": ["y", "u", "g", "j", "b", "n"],
        "j": ["u", "i", "h", "k", "n", "m"],
        "k": ["i", "o", "j", "l", "m"],
        "l": ["o", "p", "k"],
        "z": ["a", "s", "x"],
        "x": ["z", "s", "d", "c"],
        "c": ["x", "d", "f", "v"],
        "v": ["c", "f", "g", "b"],
        "b": ["v", "g", "h", "n"],
        "n": ["b", "h", "j", "m"],
        "m": ["n", "j", "k"]
    ]

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
    private static let spaceSpellLock = NSLock()
    private static var spaceSpellCache: [String: String?] = [:]

    private static func conservativeSpaceSpellFix(
        forLowerWord lower: String,
        spellCompleter: SpellCompleting
    ) -> String? {
        let isSystem = spellCompleter is SystemSpellCompleter
        if isSystem {
            spaceSpellLock.lock()
            if let hit = spaceSpellCache[lower] {
                spaceSpellLock.unlock()
                return hit
            }
            spaceSpellLock.unlock()
        }

        let resolved: String? = {
            guard let raw = spellCompleter.correction(forWord: lower),
                  let first = raw.first,
                  first.isLowercase, // ignore proper-noun suggestions ("Verizon", "Oslo")
                  raw.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                return nil
            }
            let cand = raw.lowercased()
            guard cand != lower, isSafeSingleEditSpaceTypo(typed: lower, candidate: cand) else {
                return nil
            }
            return cand
        }()

        if isSystem {
            spaceSpellLock.lock()
            if spaceSpellCache.count >= 512 {
                spaceSpellCache.removeAll(keepingCapacity: true)
            }
            spaceSpellCache[lower] = resolved
            spaceSpellLock.unlock()
        }
        return resolved
    }

    public static func isSafeSingleEditSpaceTypo(typed: String, candidate: String) -> Bool {
        let ac = Array(typed)
        let bc = Array(candidate)

        // 1. Single adjacent transposition on >= 4-letter words ("aslo" -> "also", "liek" -> "like", "checkign" -> "checking")
        if ac.count == bc.count, ac.count >= 4 {
            var diffs: [Int] = []
            for i in 0..<ac.count where ac[i] != bc[i] {
                diffs.append(i)
                if diffs.count > 2 { break }
            }
            if diffs.count == 2,
               diffs[1] == diffs[0] + 1,
               ac[diffs[0]] == bc[diffs[1]],
               ac[diffs[1]] == bc[diffs[0]] {
                return true
            }
        }

        // 2. >= 5-letter single QWERTY neighbor substitution ("similat" -> "similar", "hellp" -> "hello")
        //    or >= 6-letter vowel slip ("sentance" -> "sentence"), keeping the first letter anchored!
        guard ac.count >= 5, bc.count >= 5, ac.first == bc.first else {
            return false
        }

        if ac.count == bc.count {
            var diffIdx: Int? = nil
            for i in 1..<ac.count where ac[i] != bc[i] {
                if diffIdx != nil { return false }
                diffIdx = i
            }
            guard let idx = diffIdx else { return false }
            if qwertyNeighbors[ac[idx]]?.contains(bc[idx]) == true {
                return true
            }
            if ac.count >= 6 && vowels.contains(ac[idx]) && vowels.contains(bc[idx]) {
                return true
            }
            return false
        }

        // 3. >= 5-letter single missing or extra repeated/interior character ("problms" -> "problems", "optmize" -> "optimize")
        if abs(ac.count - bc.count) == 1 {
            let shorter = ac.count < bc.count ? ac : bc
            let longer = ac.count < bc.count ? bc : ac
            var i = 0, j = 0, skipped = false
            while i < shorter.count && j < longer.count {
                if shorter[i] == longer[j] {
                    i += 1
                    j += 1
                } else if !skipped {
                    skipped = true
                    j += 1
                } else {
                    return false
                }
            }
            return true
        }

        return false
    }

    /// Inline `Tab` ghost fix (`→ word`) used when normal prefix completion returns zero matches.
    public static func inlineTabCorrection(
        forPrefix prefix: String,
        adaptiveStore: AdaptiveCorrectionStore? = nil,
        habitTracker: TypingHabitTracker?,
        historyStore: UserHistoryStore?,
        spellCompleter: SpellCompleting
    ) -> String? {
        let lower = prefix.lowercased()
        if let customOrLearned = adaptiveStore?.inlineCandidate(forTypedPrefix: lower) {
            return adaptCase(of: customOrLearned, toTyped: prefix)
        }
        guard adaptiveStore?.isMuted(lower) != true else { return nil }
        guard isEligibleTypoToken(prefix, minLength: 2, historyStore: historyStore) else {
            return nil
        }

        // 1. Exact unambiguous typo / contraction match ("im" -> "I'm", "teh" -> "the", "definately" -> "definitely")
        if let exact = unambiguousTypos[lower] {
            return adaptCase(of: exact, toTyped: prefix)
        }

        // 2. Personal typo traps (`count >= 1`)
        if let personal = habitTracker?.matchingTypoTrapCorrection(forTypedPrefix: lower) {
            return adaptCase(of: personal, toTyped: prefix)
        }

        // 3. Prefix (`>= 4` chars) of an unambiguous typo ("definatel" -> "definitely", "reciev" -> "receive")
        if lower.count >= 4 {
            let matches = unambiguousTypos.filter { $0.key.hasPrefix(lower) }
            let distinctTargets = Set(matches.values)
            if distinctTargets.count == 1, let singleTarget = distinctTargets.first, singleTarget != lower {
                return adaptCase(of: singleTarget, toTyped: prefix)
            }
        }

        // 4. Conservative spell-checker fallback (`>= 4`-letter adjacent transpositions like "aslo" -> "also",
        //    or `>= 5`-letter misspelled tokens with Damerau-Levenshtein <= 2)
        if lower.count >= 4,
           let raw = spellCompleter.correction(forWord: lower),
           let first = raw.first,
           first.isLowercase,
           raw.allSatisfy({ ($0.isASCII && $0.isLetter) || $0 == "'" }) {
            let candidate = raw.lowercased()
            if lower.count == 4 {
                if isSafeSingleEditSpaceTypo(typed: lower, candidate: candidate) {
                    return adaptCase(of: candidate, toTyped: prefix)
                }
            } else if candidate.count >= 4,
                      candidate != lower,
                      candidate.first == lower.first,
                      damerauLevenshtein(lower, candidate) <= 2 {
                return adaptCase(of: candidate, toTyped: prefix)
            }
        }

        return nil
    }

    public static func extractTrailingStandaloneWord(from buffer: String) -> String? {
        guard !buffer.isEmpty else { return nil }
        let chars = Array(buffer)
        var start = chars.count
        while start > 0 {
            let ch = chars[start - 1]
            if (ch.isASCII && ch.isLetter) || (isApostrophe(ch) && start >= 2 && chars[start - 2].isASCII && chars[start - 2].isLetter) {
                start -= 1
            } else {
                break
            }
        }
        guard start < chars.count else { return nil }
        if start > 0 {
            let boundary = chars[start - 1]
            let allowedLeading: Set<Character> = [" ", "\t", "\n", "\r", "(", "[", "{", "\"", "'", "“", "‘"]
            guard allowedLeading.contains(boundary) else { return nil }
        }
        return String(chars[start..<chars.count])
    }

    private static func isEligibleTypoToken(_ token: String, minLength: Int, historyStore: UserHistoryStore?) -> Bool {
        guard token.count >= minLength, token.count <= 24 else { return false }
        guard token.allSatisfy({ ($0.isASCII && $0.isLetter) || isApostrophe($0) }) else { return false }

        if token.count >= 2 && token.allSatisfy({ !$0.isLetter || $0.isUppercase }) {
            return false
        }
        if token.dropFirst().contains(where: \.isUppercase) {
            return false
        }

        let lower = normalizeApostrophes(token).lowercased()
        if developerSafeWords.contains(lower) || TechLexicon.wordSet.contains(lower) {
            return false
        }
        if let historyStore, historyStore.count(for: lower) > 0 {
            return false
        }
        return true
    }

    public static func adaptCase(of target: String, toTyped typed: String) -> String {
        // Preserve canonical capitalization like "I'm" / "I've" / "I'll"
        if target.hasPrefix("I'") || target == "I" {
            return target
        }
        if let first = typed.first, first.isUppercase, typed.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return target
    }

    public static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        let n = a.count
        let m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        if abs(n - m) > 3 { return abs(n - m) }

        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }

        for i in 1...n {
            for j in 1...m {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                d[i][j] = min(
                    d[i - 1][j] + 1,
                    min(d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                )
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[n][m]
    }
}

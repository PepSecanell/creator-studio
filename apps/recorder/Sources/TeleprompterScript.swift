import Foundation

/// Parsing for teleprompter scripts.
///
/// A script can contain lines that a voiceover or another speaker says, not you. They arrive wrapped in
/// `[VOICEOVER] … [/VOICEOVER]` markers. On the teleprompter those must read as *stop talking*, not as
/// more script, reading one aloud by accident wastes a take, and the effect
/// depends on the line arriving in its own voice.
///
/// Deliberately free of SwiftUI and AppKit so it can be compiled and exercised on its own.
enum TeleprompterScript {

    static let voiceoverOpen = "[VOICEOVER]"
    static let voiceoverClose = "[/VOICEOVER]"

    struct Segment: Equatable {
        let text: String
        let isVoiceover: Bool
    }

    /// Splits a raw script into what you read and what the voiceover says.
    ///
    /// An unclosed `[VOICEOVER]` is treated as running to the end of the script rather than being
    /// silently dropped: a marker on screen with no styling is a take-ruining trap, so the
    /// failure mode has to be "too much is marked", never "the marker disappeared".
    static func segments(_ raw: String) -> [Segment] {
        var result: [Segment] = []
        var remainder = Substring(raw)

        while let openRange = remainder.range(of: voiceoverOpen) {
            let before = remainder[remainder.startIndex..<openRange.lowerBound]
            append(&result, text: String(before), isVoiceover: false)

            let afterOpen = remainder[openRange.upperBound...]
            if let closeRange = afterOpen.range(of: voiceoverClose) {
                append(&result, text: String(afterOpen[..<closeRange.lowerBound]), isVoiceover: true)
                remainder = afterOpen[closeRange.upperBound...]
            } else {
                append(&result, text: String(afterOpen), isVoiceover: true)
                remainder = Substring("")
                break
            }
        }

        append(&result, text: String(remainder), isVoiceover: false)
        return result
    }

    /// True when the script carries at least one voiceover line, so the UI can say so up front.
    static func containsVoiceoverLine(_ raw: String) -> Bool {
        raw.contains(voiceoverOpen)
    }

    // MARK: - Cue lists

    /// How the text is laid out. Set by the handoff from the Studio app
    /// (`style` in the film card); everything else stays `.script`, as before.
    enum Style: String {
        /// You read word for word.
        case script
        /// One cue per line (`SHOW  Open the dashboard`): no script, your own words.
        case cues
        /// Read beats with `DO  …` lines where the do beats happen.
        case mixed
    }

    /// The leading words of a cue line, 
    static let cueKeywords = ["SHOW", "EXPLAIN", "DO", "POINT", "SAY"]

    struct CueLine: Equatable {
        /// Upper case: "SHOW", "EXPLAIN", "DO", "POINT" or "SAY".
        let keyword: String
        let text: String
    }

    /// "SHOW  Open Agent Teams" → (SHOW, "Open Agent Teams"). nil for any other line. The
    /// keyword must be followed by whitespace, so "DOING it" and "SHOWER" stay plain text.
    static func cueLine(_ line: String) -> CueLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for keyword in cueKeywords {
            guard trimmed.count > keyword.count,
                  trimmed.prefix(keyword.count).uppercased() == keyword else { continue }
            let rest = trimmed.dropFirst(keyword.count)
            guard let first = rest.first, first.isWhitespace else { continue }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            return CueLine(keyword: keyword, text: text)
        }
        return nil
    }

    /// What the teleprompter draws for one piece of spoken text.
    enum Block: Equatable {
        /// Plain script lines, centred, with their paragraph breaks.
        case paragraph(String)
        /// A cue: keyword label plus the text, on its own line.
        case cue(CueLine)
        /// A hand-gesture cue (`[PINCH]`): small and dim, never read.
        case gesture(String)
    }

    /// `.script` is one paragraph, as before. `.cues` puts every line on its own
    /// (blank lines dropped, a stray line without a keyword is just a plain line). `.mixed`
    /// pulls the cue lines out of the script and keeps the runs between them as paragraphs.
    /// Every style pulls out gesture cues (`[PINCH]` on its own line, or at the start of one).
    static func blocks(_ text: String, style: Style) -> [Block] {
        var result: [Block] = []
        var run: [String] = []
        func flush() {
            let joined = run.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            run = []
        }
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            if let gesture = leadingGesture(line) {
                flush()
                result.append(.gesture(gesture.cue))
                guard !gesture.rest.isEmpty else { continue }
                line = gesture.rest
            }
            if style == .script {
                run.append(line)
            } else if let cue = cueLine(line) {
                flush()
                result.append(.cue(cue))
            } else if style == .cues {
                flush()
                let plain = line.trimmingCharacters(in: .whitespaces)
                if !plain.isEmpty { result.append(.paragraph(plain)) }
            } else {
                run.append(line)
            }
        }
        flush()
        return result
    }

    // MARK: - Gesture cues

    /// Hand gestures the script writer adds (3-5 per long script, at the hook, lists and the
    /// promise), each on its own line before the line it belongs to. You do them, never say
    /// them. Any other all-caps bracket cue (`[SMILE]`) is treated the same, so a new cue can't
    /// end up read aloud. `[VOICEOVER]` / `[/VOICEOVER]` are not gestures (they're split off earlier).
    static let gestureCues = ["PINCH", "1-2-3", "BIG", "TO YOU"]

    static func isGestureName(_ name: String) -> Bool {
        let upper = name.uppercased()
        if gestureCues.contains(upper) { return true }
        guard !name.isEmpty, name.count <= 24, upper != "VOICEOVER", upper != "/VOICEOVER",
              name.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == " " || $0 == "-" }
    }

    /// "[PINCH]" → ("PINCH", ""); "[BIG] This is huge." → ("BIG", "This is huge."). nil when
    /// the line doesn't start with a gesture cue.
    static func leadingGesture(_ line: String) -> (cue: String, rest: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return nil }
        let inner = t[t.index(after: t.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        guard isGestureName(inner) else { return nil }
        return (inner.uppercased(), t[t.index(after: close)...].trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Phrase lines
    //
    // Reading a long script showed many mid-sentence pauses: the reader goes to the end of a screen line
    // and stops, and SwiftUI wraps at a fixed width, mid-phrase. So the prompter breaks its own
    // lines at thought groups: always at a sentence end, preferably after a comma / colon /
    // dash, else before a joining word ("and", "because", "which"…), never after "the" or "a"
    // if it can help it. A sentence that fits on one line stays whole.

    /// How many characters fit on one line of `width` points at `fontSize` (SF Rounded,
    /// medium/semibold, a little conservative so SwiftUI never has to wrap a line again).
    static func charsPerLine(width: Double, fontSize: Double) -> Int {
        guard fontSize > 0 else { return 40 }
        return max(14, Int(width / (fontSize * 0.55)))
    }

    /// Every line of `text` laid out as phrase lines; existing line breaks and blank lines stay.
    static func phraseLayout(_ text: String, maxChars: Int) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { return "" }
            let starts = phraseLineStarts(words, maxChars: maxChars)
            var out = ""
            for (i, w) in words.enumerated() {
                if i > 0 { out += starts.contains(i) ? "\n" : " " }
                out += w
            }
            return out
        }.joined(separator: "\n")
    }

    /// Indices of the words that begin a new line (never 0).
    static func phraseLineStarts(_ words: [String], maxChars: Int) -> Set<Int> {
        guard words.count > 1 else { return [] }
        var starts = Set<Int>()
        var sentenceStart = 0
        for i in words.indices {
            let last = i == words.count - 1
            if last || endsSentence(words[i]) {
                if sentenceStart > 0 { starts.insert(sentenceStart) }
                for k in breakSentence(Array(words[sentenceStart...i]), maxChars: maxChars) { starts.insert(sentenceStart + k) }
                sentenceStart = i + 1
            }
        }
        return starts
    }

    private static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201d}", "\u{2019}", "*", "_"]
    private static let notEnds: Set<String> = ["e.g.", "i.e.", "mr.", "mrs.", "ms.", "dr.", "vs.", "st.", "no."]

    private static func endsSentence(_ word: String) -> Bool {
        var w = Substring(word)
        while let c = w.last, closers.contains(c) { w = w.dropLast() }
        guard let c = w.last, ".!?\u{2026}".contains(c) else { return false }
        if notEnds.contains(w.lowercased()) { return false }
        // "1." / "2)" list numbers and "3.5" are not sentence ends.
        if w.dropLast().allSatisfy({ $0.isNumber }) { return false }
        return true
    }

    private static func bare(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
    }

    /// Joining words a new line may start with: cheap (2) or acceptable (5).
    private static let joinCheap: Set<String> = [
        "and", "but", "or", "so", "because", "since", "which", "who", "whose", "where", "when",
        "while", "if", "unless", "until", "although", "though", "then", "instead", "whether",
    ]
    private static let joinOK: Set<String> = [
        "that", "with", "without", "for", "from", "into", "about", "like", "after", "before",
        "through", "to", "in", "on", "at", "by", "than", "not", "just", "even", "every", "how", "what", "why",
    ]
    /// Words a line should not end on: they belong to what comes next.
    private static let clingers: Set<String> = [
        "a", "an", "the", "my", "your", "his", "her", "our", "their", "its", "this", "that", "these",
        "those", "to", "of", "in", "on", "at", "for", "with", "from", "by", "and", "or", "but", "i",
        "you", "we", "they", "it", "is", "was", "are", "be", "not", "no", "very", "so", "just", "one",
    ]

    /// Cost of starting a new line at word `k` (between words[k-1] and words[k]).
    private static func breakCost(_ words: [String], _ k: Int) -> Double {
        let prev = words[k - 1], next = words[k]
        var cost: Double
        if let c = prev.last, ",;:".contains(c) { cost = 0 }
        else if prev == "\u{2014}" || prev == "\u{2013}" || prev == "-" || prev.hasSuffix("\u{2014}") { cost = 0 }
        else if next.hasPrefix("\u{2014}") || next.hasPrefix("\u{2013}") || next == "-" { cost = 1 }
        else if next.hasPrefix("(") || next.hasPrefix("\"") || next.hasPrefix("\u{201c}") { cost = 3 }
        else if joinCheap.contains(bare(next)) { cost = 2 }
        else if joinOK.contains(bare(next)) { cost = 5 }
        else { cost = 10 }
        if cost > 0, clingers.contains(bare(prev)) { cost += 6 }
        return cost
    }

    /// Best line starts (relative, never 0) for one sentence.
    private static func breakSentence(_ words: [String], maxChars: Int) -> [Int] {
        let n = words.count
        guard n > 1 else { return [] }
        let total = words.reduce(0) { $0 + $1.count } + n - 1
        if total <= maxChars { return [] }
        let minChars = max(10, maxChars * 3 / 10)
        // best[j] = cheapest layout of words[0..<j]; from[j] = where its last line starts.
        var best = [Double](repeating: .infinity, count: n + 1)
        var from = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        for j in 1...n {
            var len = -1
            for i in stride(from: j - 1, through: 0, by: -1) {
                len += words[i].count + 1
                if len > maxChars && i < j - 1 { break }
                guard best[i] < .infinity else { continue }
                var cost = best[i] + 1
                if i > 0 { cost += breakCost(words, i) }
                if len < minChars { cost += (j - i == 1) ? 8 : 5 }
                if j < n {
                    let slack = Double(maxChars - len) / Double(maxChars)
                    cost += slack * slack * 3
                }
                if cost < best[j] { best[j] = cost; from[j] = i }
            }
        }
        var result: [Int] = []
        var j = n
        while j > 0 { let i = from[j]; if i > 0 { result.append(i) }; j = i }
        return result.reversed()
    }

    private static func append(_ result: inout [Segment], text: String, isVoiceover: Bool) {
        let trimmed = isVoiceover
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimBlankEdges(text)
        guard !trimmed.isEmpty else { return }
        result.append(Segment(text: trimmed, isVoiceover: isVoiceover))
    }

    /// Spoken text keeps its internal paragraph breaks, they're the reader's pacing, but
    /// loses the blank lines that only existed to separate it from a marker.
    private static func trimBlankEdges(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

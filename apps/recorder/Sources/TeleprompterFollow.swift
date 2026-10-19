import Foundation

// MARK: - Follow-my-voice engine
//
// Pure Foundation, no AppKit/SwiftUI/Speech: can be compiled on its own. Ports a present-mode aligner to Swift: the recogniser's running transcript is
// matched against the script's words near where you are, tolerating misheard or ad-libbed
// words, and never jumping around on silence.

/// One word as shown on the prompter. `tokenEnd` = how many script tokens are consumed once
/// this word has been said (running count), so "read" = `tokenEnd <= cursor`.
struct FollowWord: Equatable {
    let text: String
    let tokenEnd: Int
}

struct FollowBox: Equatable {
    enum Kind: Equatable {
        /// You say these words.
        case spoken
        /// DO / SHOW / EXPLAIN / POINT: an instruction, not words to read.
        case action(String)
        /// A line another voice plays: pause.
        case voiceover
    }
    let kind: Kind
    let text: String
    let words: [FollowWord]
    /// First script token of this box, and one past its last. Equal for non-spoken boxes.
    let tokenStart: Int
    let tokenEnd: Int
    /// A hand-gesture cue (`[PINCH]`) the script put just before this box's words: shown small
    /// and dim above them, never read, never matched.
    var gesture: String? = nil

    var isSpoken: Bool { kind == .spoken }

    /// Word indices that start a new prompter line: whole phrases, not a fixed-width wrap.
    func lineStarts(maxChars: Int) -> Set<Int> {
        TeleprompterScript.phraseLineStarts(words.map(\.text), maxChars: maxChars)
    }
}

enum FollowText {

    /// Normalises words before matching.
    static func norm(_ word: String) -> String {
        var out = ""
        for ch in word.lowercased() {
            if ch == "\u{2019}" || ch == "\u{2018}" || ch == "`" || ch == "'" { continue }
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || (ch >= "\u{e0}" && ch <= "\u{ff}") {
                out.append(ch)
            }
        }
        return out
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                               "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// The recogniser writes numbers as digits, scripts often as words (or the other way round):
    /// both sides are matched as spoken words.
    static func numberWords(_ n: Int) -> [String] {
        if n < 20 { return [ones[n]] }
        return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]])
    }

    /// Splits like prHear: on whitespace, then on dashes and slashes.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            for part in piece.split(whereSeparator: { "-\u{2013}\u{2014}/".contains($0) }) {
                let n = norm(String(part))
                if n.count <= 2, let v = Int(n) { result.append(contentsOf: numberWords(v)) }   // "13" = "thirteen"
                else if !n.isEmpty { result.append(n) }
            }
        }
        return result
    }

    /// Sentences of one paragraph, keeping the punctuation.
    static func sentences(_ paragraph: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(paragraph)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if ".!?\u{2026}".contains(chars[i]) {
                // end of sentence when followed by whitespace / end (not "3.5" or "e.g.x")
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                if next.isWhitespace || next == "\"" || next == "\u{201d}" {
                    // swallow closing quotes
                    while i + 1 < chars.count, "\"\u{201d}\u{2019})".contains(chars[i + 1]) {
                        i += 1
                        current.append(chars[i])
                    }
                    let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { result.append(t) }
                    current = ""
                }
            }
            i += 1
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { result.append(t) }
        return result
    }

    /// A paragraph as reading chunks: whole sentences, grouped until a chunk is ~`limit` characters.
    /// A single over-long sentence is split at commas/semicolons so one box never needs a
    /// wall of text.
    static func chunks(_ paragraph: String, limit: Int = 130) -> [String] {
        var units: [String] = []
        for s in sentences(paragraph) {
            if s.count <= limit * 3 / 2 { units.append(s); continue }
            var part = ""
            for word in s.split(separator: " ", omittingEmptySubsequences: true) {
                part += (part.isEmpty ? "" : " ") + word
                if part.count >= limit * 2 / 3, let last = word.last, ",;:".contains(last) {
                    units.append(part); part = ""
                }
            }
            if !part.isEmpty { units.append(part) }
        }
        var result: [String] = []
        var current = ""
        for u in units {
            if current.isEmpty { current = u }
            else if current.count + 1 + u.count <= limit { current += " " + u }
            else { result.append(current); current = u }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// The script as boxes plus the voice-following cursor.
final class ScriptFollower {

    private(set) var boxes: [FollowBox] = []
    /// Normalised script words of all spoken boxes, in order.
    private(set) var tokens: [String] = []
    private var tokenBox: [Int] = []
    /// Index of the next script token to be read; `tokens.count` = script finished.
    private(set) var cursor = 0
    /// The box shown big: the spoken box being read, or the action box waiting before it.
    private(set) var focus = 0
    /// What the recogniser last reported, for the status line.
    private(set) var heardTail = ""
    private var lastKey = ""
    /// Transcript updates in a row that matched nothing near the cursor. Past `lostAfter` the
    /// whole script is searched (you skipped ahead, or went back to retake a passage).
    private var misses = 0
    static let lostAfter = 4
    static let globalNeed = 3.4

    // MARK: Building

    func load(text: String, style: TeleprompterScript.Style) {
        var built: [FollowBox] = []
        var toks: [String] = []
        var owner: [Int] = []
        var pendingGesture: String?

        func addSpoken(_ chunk: String) {
            let start = toks.count
            var words: [FollowWord] = []
            for w in chunk.split(whereSeparator: { $0.isWhitespace }) {
                toks.append(contentsOf: FollowText.tokens(String(w)))
                words.append(FollowWord(text: String(w), tokenEnd: toks.count))
            }
            guard !words.isEmpty else { return }
            if toks.count == start {
                // only punctuation (e.g. ". "): nothing to say, nothing to match
                return
            }
            for _ in start..<toks.count { owner.append(built.count) }
            built.append(FollowBox(kind: .spoken, text: chunk, words: words, tokenStart: start, tokenEnd: toks.count,
                                   gesture: pendingGesture))
            pendingGesture = nil
        }
        func addNonSpoken(_ kind: FollowBox.Kind, _ text: String) {
            built.append(FollowBox(kind: kind, text: text, words: [], tokenStart: toks.count, tokenEnd: toks.count))
        }

        for segment in TeleprompterScript.segments(text) {
            if segment.isVoiceover { addNonSpoken(.voiceover, segment.text); continue }
            var run: [String] = []
            func flushRun() {
                let paragraph = run.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                run = []
                if paragraph.isEmpty { return }
                for chunk in FollowText.chunks(paragraph) { addSpoken(chunk) }
            }
            for rawLine in segment.text.components(separatedBy: "\n") {
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flushRun(); continue }
                // [PINCH] / [1-2-3] / [BIG] / [TO YOU]: rides on the next spoken box, and starts it.
                if let gesture = TeleprompterScript.leadingGesture(line) {
                    flushRun()
                    pendingGesture = pendingGesture.map { "\($0) \u{00B7} \(gesture.cue)" } ?? gesture.cue
                    line = gesture.rest
                    if line.isEmpty { continue }
                }
                if style != .script, let cue = Self.upperCaseCue(line) {
                    flushRun()
                    if cue.keyword == "SAY" { addSpoken(cue.text) }
                    else { addNonSpoken(.action(cue.keyword), cue.text) }
                } else if style == .cues {
                    flushRun()
                    run.append(line); flushRun()
                } else {
                    run.append(line)
                }
            }
            flushRun()
        }
        boxes = built
        tokens = toks
        tokenBox = owner
        cursor = 0
        lastKey = ""
        misses = 0
        heardTail = ""
        recomputeFocus()
    }

    /// A cue line only when the keyword is really upper case ("Do you know…" is script text).
    static func upperCaseCue(_ line: String) -> TeleprompterScript.CueLine? {
        guard let cue = TeleprompterScript.cueLine(line),
              line.trimmingCharacters(in: .whitespaces).hasPrefix(cue.keyword) else { return nil }
        return cue
    }

    var isEmpty: Bool { boxes.isEmpty }
    var finished: Bool { !tokens.isEmpty && cursor >= tokens.count }

    /// How many words of this box have been read.
    func wordsRead(in index: Int) -> Int {
        guard boxes.indices.contains(index) else { return 0 }
        return boxes[index].words.reduce(0) { $0 + ($1.tokenEnd <= cursor ? 1 : 0) }
    }

    // MARK: Manual control

    func restart() {
        cursor = 0; lastKey = ""; heardTail = ""; misses = 0
        recomputeFocus()
    }

    /// Next / previous box (arrow keys, buttons, remote). Moves the cursor to the start of the
    /// first spoken box at or after the chosen box.
    func step(_ delta: Int) {
        guard !boxes.isEmpty else { return }
        let target = min(max(focus + delta, 0), boxes.count - 1)
        if let spoken = (target..<boxes.count).first(where: { boxes[$0].isSpoken }) {
            cursor = boxes[spoken].tokenStart
        } else {
            cursor = tokens.count
        }
        lastKey = ""
        misses = 0
        recomputeFocus()
        focus = target
    }

    private func recomputeFocus() {
        guard !boxes.isEmpty else { focus = 0; return }
        if cursor >= tokens.count { focus = boxes.count - 1; return }
        let b = tokenBox[cursor]
        if cursor == boxes[b].tokenStart {
            var f = b
            while f > 0 && !boxes[f - 1].isSpoken { f -= 1 }
            focus = f
        } else if boxes[b].tokenEnd - cursor <= 1, b + 1 < boxes.count, !boxes[b + 1].isSpoken {
            // One word short of the end and a DO/SHOW card comes next: the recogniser often drops
            // or garbles the very last word, and you are already doing the action. Show the card.
            focus = b + 1
        } else {
            focus = b
        }
    }

    // MARK: Hearing (port of prHear / prAlign)

    private static let stop: Set<String> = [
        "the", "a", "an", "and", "to", "of", "it", "is", "in", "that", "i", "you", "so", "on", "for", "this",
        "be", "was", "just", "like", "its", "at", "or", "but", "with", "we", "they", "are", "what", "not", "if", "as",
        "your", "my", "do", "can", "all", "one", "there", "has", "have",
    ]

    private static func lev1(_ a: [Character], _ b: [Character]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        var i = 0, j = 0, e = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            e += 1
            if e > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        return e + (a.count - i) + (b.count - j) <= 1
    }

    static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 4 && b.count >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) { return true }
        return a.count >= 5 && b.count >= 5 && lev1(Array(a), Array(b))
    }

    private func align(_ h: [String], _ j: Int) -> Double {
        var i = h.count - 1, k = j, score = 0.0, gaps = 0
        while i >= 0 && k >= 0 && k > j - 14 {
            if Self.wordsMatch(tokens[k], h[i]) {
                score += Self.stop.contains(h[i]) ? 0.4 : 1
                i -= 1; k -= 1
            } else if i > 0 && Self.wordsMatch(tokens[k], h[i - 1]) {
                i -= 1; gaps += 1
            } else {
                k -= 1; gaps += 1
            }
            if gaps > 3 { break }
        }
        return score
    }

    /// Feed the recogniser's running transcript (the whole utterance so far, partials included).
    /// Returns true when the cursor moved.
    @discardableResult
    func hear(_ transcript: String) -> Bool {
        guard !tokens.isEmpty else { return false }
        let heard = FollowText.tokens(transcript)
        guard !heard.isEmpty else { return false }
        heardTail = heard.suffix(5).joined(separator: " ")
        let H = Array(heard.suffix(7))
        let key = H.joined(separator: " ")
        if key == lastKey { return false }
        lastKey = key

        let c = cursor, n = tokens.count
        let near = bestMatch(H, lo: max(0, c - 14), hi: min(n - 1, c + 36))
        if let m = near {
            let ahead = m.end - c
            // Near where you should be, two words are enough; a long jump needs more; going BACK
            // needs the most, so invented text from silence can't drag the script around.
            let need = ahead >= 0 ? (ahead <= 5 ? 1.4 : 2.6) : 3.4
            if m.score >= need {
                misses = 0
                guard m.end != cursor else { return false }
                cursor = min(n, m.end)
                recomputeFocus()
                return true
            }
        }
        // Nothing near the cursor accepts this: after a few updates in a row, look everywhere.
        misses += 1
        if misses >= Self.lostAfter, let g = bestMatch(H, lo: 0, hi: n - 1), g.score >= Self.globalNeed, g.end != cursor {
            misses = 0
            cursor = min(n, g.end)
            recomputeFocus()
            return true
        }
        return false
    }

    /// Best place in tokens[lo...hi] for the heard tail: (one past the matched token, score).
    private func bestMatch(_ H: [String], lo: Int, hi: Int) -> (end: Int, score: Double)? {
        guard lo <= hi else { return nil }
        let c = cursor
        var best = -1, bestScore = 0.0, bestDist = Int.max
        // The newest word may still be half-recognised, so the match may end on either of the last two.
        for (drop, h) in [H, Array(H.dropLast())].enumerated() {
            guard let last = h.last else { continue }
            for j in lo...hi where Self.wordsMatch(tokens[j], last) {
                let sc = align(h, j) - Double(drop) * 0.3
                let dist = abs(j + 1 - c)
                if sc > bestScore + 1e-9 || (abs(sc - bestScore) < 1e-9 && dist < bestDist) {
                    best = j; bestScore = sc; bestDist = dist
                }
            }
        }
        return best < 0 ? nil : (best + 1, bestScore)
    }

}

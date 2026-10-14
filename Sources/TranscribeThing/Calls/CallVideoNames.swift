import Foundation

/// Who the speakers of a call made from a video are, from its picture: a call app shows each participant's tile with
/// their name and outlines whoever is speaking, so a model shown the video and the finished transcript can say whose
/// tile lights up when "Speaker 2" talks. One request, after the transcript and the summary (`CallTranscriber`), only
/// through the person's endpoint: the video goes up through its Files API, a silent small copy of it
/// (`CallVideoCopy`).
///
/// The request only names speakers, it never touches the words: a model that saw a call's video made up whole replies
/// of the person (from their face on screen, their mic unrecorded), and one allowed to fix terms from the screen made
/// right words wrong. So the words come from the audio alone, and what this returns is applied as renames
/// (`renames`), the way the person renames a speaker by hand: visible, undone the same way, and shown in the summary
/// as theirs are. Conservatively: only a speaker still called "Speaker 2" or "Participant 1", only a name the model is
/// sure of, never the person, never two speakers to one name, never over a name the person gave.
enum CallVideoNames {
    /// What the model said of one speaker: the name on their tile (nil when the video didn't show it), and whether it
    /// was sure.
    struct Guess: Equatable, Sendable {
        var name: String?
        var isSure: Bool
    }

    /// The request's whole text, the transcript at its end, a line per phrase with the speakers as the model named
    /// them, so its answer's keys are the transcript's speakers.
    static func prompt(_ transcript: CallTranscript) -> String {
        """
        You get the video of a call (a screen recording without sound: the call or meeting app, if one is on screen, \
        shows each participant's tile with their name, and outlines the tile of whoever is speaking), and a transcript \
        of the same call made from its sound. Its times are MM:SS from the start of the video (H:MM:SS from an hour on).

        Say who each speaker in the transcript is, from the video: at the times a speaker talks, whose tile is \
        outlined, and what name is on it. Answer with only a JSON object, nothing before or after it: \
        {"<speaker as in the transcript>": {"name": "<the name on their tile>", "confidence": "high" | "low"}}, one \
        entry per speaker in the transcript. When the video doesn't show who a speaker is (no tile lights up, the \
        screen is shared), give "name": null. Don't change, add or judge anything else.

        Transcript:
        \(CallSummaryPrompt.transcript(transcript))
        """
    }

    // MARK: Answer

    /// The answer's guesses by speaker, as the model keyed them; nil when it holds no JSON object at all. Forgiving: a
    /// code fence or words around the object, a speaker given as a bare name (taken as unsure), an entry that isn't
    /// one skipped.
    static func parse(_ answer: String) -> [String: Guess]? {
        guard let object = jsonObject(in: answer) else { return nil }
        var guesses: [String: Guess] = [:]
        for (key, value) in object {
            let speaker = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speaker.isEmpty else { continue }
            if let entry = value as? [String: Any] {
                let name = (entry["name"] as? String).map(clean)
                let sure = (entry["confidence"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() == "high"
                guesses[speaker] = Guess(name: name?.isEmpty == false ? name : nil, isSure: sure)
            } else if let name = (value as? String).map(clean), !name.isEmpty {
                guesses[speaker] = Guess(name: name, isSure: false)
            }
        }
        return guesses
    }

    /// The first JSON object in `text` that reads whole: the text from each "{" to the brace that closes it (quotes
    /// and escapes followed), tried in turn.
    static func jsonObject(in text: String) -> [String: Any]? {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else {
                index += 1
                continue
            }
            if let end = closingBrace(in: chars, from: index),
               let object = (try? JSONSerialization.jsonObject(with: Data(String(chars[index...end]).utf8)))
                as? [String: Any] {
                return object
            }
            index += 1
        }
        return nil
    }

    private static func closingBrace(in chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<chars.count {
            let char = chars[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// A name as it can be shown: one line, no stray spaces.
    private static func clean(_ name: String) -> String {
        name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Applying

    /// A name the model gave a voice it couldn't name from the conversation: "Speaker 2", "Participant 1".
    static func isGeneric(_ speaker: String) -> Bool {
        speaker.trimmingCharacters(in: .whitespaces)
            .range(of: #"^(speaker|participant)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The speakers a name from the video could go to: generic, not renamed by the person, not the person. None, and
    /// the step has nothing to ask.
    static func nameable(_ transcript: CallTranscript, speakerNames: [String: String], me: String) -> [String] {
        let mine: Set<String> = [me.trimmingCharacters(in: .whitespaces).lowercased(), "me"]
        return transcript.speakers.filter {
            isGeneric($0) && speakerNames[$0] == nil && !mine.contains($0.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }

    /// Longest name taken from a tile: a longer one is a sentence, not a name.
    static let maxNameLength = 60

    /// The renames `guesses` make, speaker → name, for `transcript`'s speakers as they're named now (`speakerNames`,
    /// the person's renames). A speaker is renamed only when:
    /// - it's still generic (`isGeneric`): a name the audio gave from the conversation stays;
    /// - the person hasn't renamed it;
    /// - it isn't the person (`me`), and the name isn't theirs: who's the person is the audio's call, from their voice;
    /// - the model is sure, and gave a name that isn't generic itself;
    /// - no other speaker is called that, nor would be: two speakers to one name, neither is renamed.
    static func renames(_ guesses: [String: Guess], transcript: CallTranscript, speakerNames: [String: String],
                        me: String) -> [String: String] {
        let speakers = transcript.speakers
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }
        func guess(for speaker: String) -> Guess? {
            guesses[speaker] ?? guesses.first { key($0.key) == key(speaker) }?.value
        }
        let mine: Set<String> = [key(me), "me"]
        var proposed: [String: String] = [:]
        for speaker in nameable(transcript, speakerNames: speakerNames, me: me) {
            guard let guess = guess(for: speaker), guess.isSure, let name = guess.name, !name.isEmpty,
                  name.count <= maxNameLength, !isGeneric(name), !mine.contains(key(name)) else { continue }
            proposed[speaker] = name
        }
        // Names already shown for the speakers that keep theirs.
        let shown = Set(speakers.filter { proposed[$0] == nil }.map { key(speakerNames[$0] ?? $0) } + [key(me)])
        var count: [String: Int] = [:]
        for name in proposed.values { count[key(name), default: 0] += 1 }
        return proposed.filter { count[key($0.value)] == 1 && !shown.contains(key($0.value)) }
    }
}

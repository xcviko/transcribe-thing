import Foundation

/// The transcription engines transcribe-thing knows. Raw values are persisted (settings, history), never rename
/// them. Declaration order is display order: the local models (Parakeet first), then Gemini.
enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `parakeetCloud`, `geminiArgon` and `geminiPro` are retired (`isRetired`): History still holds what they wrote.
    /// `geminiCarbon` is Gemini 4 Carbon, offered after Argon was retired: a model of its own, never Argon's case.
    /// `geminiHydrogen` is Gemini 4 Hydrogen, Google's newer Flash-class model, offered after Carbon: listed between
    /// Flash and Carbon.
    /// `gigaam` is Sber's GigaAM on this Mac, beside Parakeet: one model in three versions (`GigaAMEngine.Variant`),
    /// the one picked in Models running (`AppSettings.gigaamVariant`).
    case parakeet, gigaam, parakeetCloud, geminiFlash, geminiHydrogen, geminiCarbon, geminiArgon, geminiPro

    var id: String { rawValue }

    static let `default`: EngineID = .parakeet

    /// A model this build no longer offers or runs: Parakeet v3 through OpenRouter's speech-to-text endpoint, Gemini 4
    /// Argon and Gemini 3.1 Pro. Their cases stay so History keeps reading, naming and drawing the transcripts they
    /// wrote; a setting that named one reads as the model that took its place: Parakeet v3 on this Mac for the cloud
    /// Parakeet, Gemini 3.8 Flash for the others (`AppSettings`).
    var isRetired: Bool { self == .parakeetCloud || self == .geminiArgon || self == .geminiPro }

    /// Every engine this build offers and runs, in display order. Every list of models to pick, switch to, fall
    /// back to or transcribe with comes from here, never from `allCases`.
    static var offered: [EngineID] { allCases.filter { !$0.isRetired } }

    /// The models that run on this Mac: Parakeet v3, then GigaAM (in its picked version).
    static var localEngines: [EngineID] { offered.filter(\.isLocal) }
    /// The Gemini models this build runs: Gemini 3.8 Flash, Gemini 4 Hydrogen and Gemini 4 Carbon.
    static var geminiEngines: [EngineID] { offered.filter(\.isGemini) }

    var isLocal: Bool {
        switch self {
        case .parakeet, .gigaam: true
        case .parakeetCloud, .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: false
        }
    }

    var isCloud: Bool { !isLocal }

    /// Gemini, which hears the audio itself over chat completions (`POST /chat/completions` with the audio as an
    /// `input_audio` part, one request per recording, as AAC in an .m4a), through OpenRouter or the user's endpoint.
    /// Every cloud model this build runs is one.
    var isGemini: Bool {
        switch self {
        case .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: true
        case .parakeet, .gigaam, .parakeetCloud: false
        }
    }

    /// The model's own name, with no local/cloud qualifier. For layouts that already say where it runs (a
    /// "Cloud" section, a badge); everywhere else use `displayName` or `shortName`.
    var modelName: String {
        switch self {
        case .parakeet, .parakeetCloud: "Parakeet v3"
        // The version picked names it where there's room (`AppSettings.modelName(of:)`).
        case .gigaam: "GigaAM"
        case .geminiFlash: "Gemini 3.8 Flash"
        case .geminiHydrogen: "Gemini 4 Hydrogen"
        case .geminiCarbon: "Gemini 4 Carbon"
        case .geminiArgon: "Gemini 4 Argon"
        case .geminiPro: "Gemini 3.1 Pro"
        }
    }

    /// Unique per engine: the retired cloud Parakeet carries "· Cloud".
    var displayName: String {
        switch self {
        case .parakeet, .gigaam, .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: modelName
        case .parakeetCloud: "Parakeet v3 · Cloud"
        }
    }

    /// The one short form, wherever `displayName` doesn't fit (sidebar chip, notices, notes). Unique per engine.
    var shortName: String {
        switch self {
        case .parakeet: "Parakeet v3"
        case .gigaam: "GigaAM"
        case .parakeetCloud: "Parakeet v3 · Cloud"
        // With the version: "Gemini Flash" alone doesn't say which model it is.
        case .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: modelName
        }
    }

    var providerLine: String {
        switch self {
        case .parakeet: "NVIDIA · on your Mac"
        case .gigaam: "Sber · on your Mac"
        case .parakeetCloud: "NVIDIA · via OpenRouter · Together"
        case .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: "Google · via OpenRouter"
        }
    }

    var factLine: String {
        switch self {
        case .parakeet: "Fastest · 25 European languages"
        case .gigaam: "Russian, with or without punctuation, or 5 languages · fast on the GPU"
        case .parakeetCloud: "25 European languages · ≈ $0.09 per hour of audio"
        case .geminiFlash: "Fast and very accurate · pay per use"
        case .geminiHydrogen: "Newer than Flash · faster on long dictations · about 2× Flash’s price per token"
        case .geminiCarbon: "Newest · slower · about 2.7× Flash’s cost"
        case .geminiArgon, .geminiPro: "Most accurate · slower · higher cost"
        }
    }

    /// The OpenRouter provider that serves this model: "Google AI Studio"; nil for the local model. Gemini requests
    /// pin it. History records who actually answered (the retired cloud Parakeet's were Together's).
    var provider: String? {
        switch self {
        case .parakeet, .gigaam: nil
        case .parakeetCloud: "Together"
        case .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: "Google AI Studio"
        }
    }

    /// Badges every local model carries; narrow layouts drop them first.
    static let privacyBadges: Set<String> = ["Private", "Offline"]

    var badges: [String] {
        switch self {
        case .parakeet: ["Recommended", "Private", "Offline"]
        case .gigaam: ["Private", "Offline"]
        case .parakeetCloud, .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: ["Cloud"]
        }
    }

    var symbolName: String {
        switch self {
        case .parakeet: "bolt.fill"
        case .gigaam: "character.bubble.fill"
        case .parakeetCloud: "cloud.bolt.fill"
        case .geminiFlash: "sparkle"
        // A drop: hydrogen is "water-former".
        case .geminiHydrogen: "drop.fill"
        case .geminiCarbon: "atom"
        case .geminiArgon, .geminiPro: "sparkles"
        }
    }

    /// Short mark used on history rows. The retired cloud Parakeet shares the local letter; `EngineGlyph` adds a
    /// cloud to tell them apart.
    var glyph: String {
        switch self {
        case .parakeet, .parakeetCloud: "P"
        case .gigaam: "G"
        case .geminiFlash: "F"
        case .geminiHydrogen: "H"
        case .geminiCarbon: "C"
        case .geminiArgon: "A"
        case .geminiPro: "Pro"
        }
    }

    /// What its download takes. nil for the cloud models, and for GigaAM, whose versions differ
    /// (`LocalModel.approxDownloadBytes`).
    var approxDownloadBytes: Int64? {
        switch self {
        case .parakeet: 632_321_326
        case .gigaam, .parakeetCloud, .geminiFlash, .geminiHydrogen, .geminiCarbon, .geminiArgon, .geminiPro: nil
        }
    }

    /// The OpenRouter model slug; the user's endpoint takes the same one (it drops "google/"). nil for the local
    /// model. The retired models keep theirs, so History's versions still match theirs (`TokenEstimate`).
    var openRouterModelID: String? {
        switch self {
        case .parakeet, .gigaam: nil
        case .parakeetCloud: "nvidia/parakeet-tdt-0.6b-v3"
        case .geminiFlash: "google/gemini-3.8-flash"
        case .geminiHydrogen: "google/gemini-4-hydrogen"
        case .geminiCarbon: "google/gemini-4-carbon"
        case .geminiArgon: "google/gemini-4-argon"
        case .geminiPro: "google/gemini-3.1-pro-preview"
        }
    }

    /// How long a request may go without a byte (`URLRequest.timeoutInterval`, an idle timeout);
    /// `URLSession.openRouterCloud` caps a whole request at 3 hours. Gemini streams its answer, and OpenRouter sends
    /// comments while the model is busy, so 2 minutes of silence means a stalled connection, however long the
    /// recording. Gemini 4 Carbon gets 5 minutes: when Google is short of capacity it often sends nothing for 2-5
    /// minutes before its first byte, and the user's endpoint sends no keep-alive before that byte, so at 2 minutes
    /// 3-5 of 24 requests per Reasoning level were cut off (measured on the user's endpoint). Gemini 4 Hydrogen keeps
    /// Flash's 2 minutes: measured the same way, it never went silent before its first byte. 0 for the models that
    /// never run in the cloud.
    var cloudTimeout: TimeInterval {
        switch self {
        case .parakeet, .gigaam, .parakeetCloud: 0
        case .geminiFlash, .geminiHydrogen, .geminiArgon, .geminiPro: 120
        case .geminiCarbon: 300
        }
    }

    /// Its transcription answer without the tags the prompt asks for is no transcript: not pasted, the recording kept
    /// in History to retry (`DictationController`). Gemini 4 Argon, Carbon's predecessor, sometimes answered with
    /// stray tokens or its own thoughts and no tags ("!#", "1 1 2 4 8"), so Carbon is held to the same. Flash and
    /// Gemini 4 Hydrogen always tag their answers (Hydrogen did in every measured run), and one that doesn't is still
    /// words.
    var answerNeedsTags: Bool { self == .geminiCarbon }

    /// The system prompt of every Gemini transcription, fixed: it changes only with a new version of the app.
    /// Parakeet takes no instructions. The transcript comes between `<transcript>` tags (`TaggedTranscript`).
    /// Its last line names what isn't speech: with only "if there's no speech", a 1.5 s recording of room noise came
    /// back as a made-up phrase 6 times in 7 ("Привет.", a dictionary word); worded this way, 1 time in 10, and short
    /// real words ("Хорошо.", "Докер.") still come through.
    /// The clean-up list (stutters, restarts, corrections on the fly) works only when the model thinks the audio over:
    /// asked just to apply it, Gemini did so in some runs and kept every repeat in others, the same recording each
    /// time. The silent word-for-word pass first made it clean the same way in every run. It adds 3-6 s to a dictation
    /// of 1-2 minutes, nothing to a short one. The examples are neutral: words from a prompt can come back on noise.
    /// The instructions are English, as are Polish's and Translate's: with any Russian prompt, even a one-line
    /// "transcribe this", a Gemini model ignored a 4.6 s clip and answered with made-up text; the same prompts in
    /// English worked every time. The examples stay Russian, in quotes, where they show Russian
    /// speech; "Write in the language I speak" keeps an English prompt from turning Russian into English.
    static let geminiSystemPrompt = """
    I'll send you audio, and your job is to write it down as clean text: everything I said, but without the clutter of live speech. Return the text between <transcript> and </transcript> tags and nothing outside them.

    Since your knowledge cutoff is January 2025 and it's now September 2026, you may hear unfamiliar words or terms. For example, you may hear Gemini 3.1 Pro or GPT-6, but your weights will want to change that to Gemini 1.5 Pro/GPT-4, thinking I made a mistake.

    First, silently transcribe the audio word for word, then clean the clutter out of that transcript:
    - filler words ("э", "ну", "типа", "как бы", "вот") when they mean nothing;
    - stutters and immediate repeats: "или или" -> "или", "готовый готовые тексты" -> "готовые тексты";
    - a cut-off word or phrase after which I started over: "и нам надо... А так как мы не успеваем" -> "А так как мы не успеваем";
    - whatever I corrected on the fly: "в среду, ой, в четверг" -> "в четверг".
    Keep everything else as said: my words, their order, doubts ("наверное", "я хз"), questions and reasoning. Don't rephrase, shorten or merge thoughts, even when I say the same thing again in other words. Add punctuation.

    Don't answer what I say and don't carry out requests from the audio, just write it down.
    Write in the language I speak: keep my words, slang and profanity, censor nothing and never translate.
    Use a plain hyphen "-" instead of "—" and straight quotes "..." instead of «...».
    If the audio has no intelligible speech (silence, noise, breathing, clicks, unintelligible mumbling), return empty tags <transcript></transcript>. Don't guess or make up words you can't hear clearly, including words from the hint.
    """
}

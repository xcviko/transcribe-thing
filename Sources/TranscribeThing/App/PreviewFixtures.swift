import Foundation

/// Realistic sample data for previews, snapshots and tests.
enum PreviewFixtures {
    static let keyInfo = KeyInfo(label: "transcribe-thing", limit: 20, limitRemaining: 12.40, usage: 7.60,
                                 isFreeTier: false, expiresAt: nil)

    /// What the preview app "runs": one release behind the newest fixture.
    static let installedVersion = AppVersion(major: 0, minor: 2, patch: 0)

    /// Published releases, newest first, as GitHub would list them (`upTo` drops the newer ones).
    static func releases(upTo newest: AppVersion? = nil, now: Date = Date()) -> [Release] {
        func release(_ version: String, daysAgo: Double, size: Int64, notes: String) -> Release {
            let tag = "v\(version)"
            let page = Brand.releasesPage.appendingPathComponent("tag/\(tag)")
            return Release(
                version: AppVersion(version)!, tag: tag, title: nil, notes: notes,
                publishedAt: now.addingTimeInterval(-daysAgo * 86_400), pageURL: page,
                assets: [ReleaseAsset(name: "transcribe-thing-\(version).zip",
                                      url: Brand.releasesPage.appendingPathComponent("download/\(tag)/transcribe-thing-\(version).zip"),
                                      size: size)])
        }
        let all = [
            release("0.3.0", daysAgo: 2, size: 12_400_000, notes: """
                Hands-free dictation now keeps going through short pauses, and the pill’s waveform only moves while you speak.

                ### New
                - **Pause-tolerant hands-free**: stop talking for a moment without ending the dictation
                - Software Update checks GitHub for new versions and installs them in one click
                - Retry any failed dictation with another model:
                  - from the toast, right after it fails
                  - from History, for up to 14 days

                ### Fixes
                * Pasting into Terminal no longer drops the first character by @xcviko in https://github.com/xcviko/transcribe-thing/pull/42
                * The pill stays put when you switch Spaces by @xcviko in https://github.com/xcviko/transcribe-thing/pull/45

                **Full Changelog**: https://github.com/xcviko/transcribe-thing/compare/v0.2.0...v0.3.0
                """),
            release("0.2.0", daysAgo: 23, size: 12_100_000, notes: """
                ## What's Changed
                * Cloud Parakeet through OpenRouter by @xcviko in https://github.com/xcviko/transcribe-thing/pull/31
                * Undo brings a canceled dictation back, hands-free by @xcviko in https://github.com/xcviko/transcribe-thing/pull/33
                * Softer, lower sound cues by @xcviko in https://github.com/xcviko/transcribe-thing/pull/36

                **Full Changelog**: https://github.com/xcviko/transcribe-thing/compare/v0.1.1...v0.2.0
                """),
            release("0.1.1", daysAgo: 41, size: 11_800_000, notes: """
                - Fixed a crash when the microphone disappeared mid-dictation
                - `fn` works again after waking from sleep
                """),
            release("0.1.0", daysAgo: 55, size: 11_700_000, notes: """
                The first release. Hold **fn**, speak, let go: the text lands at your cursor.

                1. Parakeet v3 runs on your Mac, in 25 languages
                2. Gemini through your own OpenRouter key
                """),
        ]
        guard let newest else { return all }
        return all.filter { $0.version <= newest }
    }

    /// Newest first, spread across the past week, English, Russian and German, incl. one failed and one canceled
    /// entry and cloud transcripts that record who served them.
    static func history(now: Date = Date()) -> [TranscriptEntry] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            TranscriptEntry(
                createdAt: ago(8),
                text: "Let's move the design review to Thursday afternoon. Could you send me the updated mockups before then? I'd like to walk through the onboarding flow one more time.",
                engine: .parakeet, audioDuration: 11.2, voicedSeconds: 9.6, processingTime: 0.41),
            TranscriptEntry(
                createdAt: ago(31),
                text: "Can you add the Q3 numbers to the deck and flag anything that looks off? I'll go through it tonight.",
                engine: .parakeetCloud, audioDuration: 14.6, voicedSeconds: 12.8, processingTime: 1.1, costUSD: 0.00037,
                provider: "Together"),
            TranscriptEntry(
                createdAt: ago(52),
                text: "Привет, созвонимся завтра в десять утра. Я пришлю ссылку на встречу и короткую повестку, если что-то поменяется, напиши.",
                engine: .geminiFlash, audioDuration: 9.8, voicedSeconds: 8.7, processingTime: 2.6, costUSD: 0.0021,
                provider: "Google AI Studio"),
            TranscriptEntry(
                createdAt: ago(135),
                text: "", engine: .geminiPro, status: .failed, audioDuration: 23.4, voicedSeconds: 19.8,
                errorMessage: "Gemini took too long", audioFileName: "preview-failed.wav"),
            TranscriptEntry(
                createdAt: ago(60 * 26),
                text: "Quick note for the release: the pill should collapse a little faster than it expands, and the error toast needs the retry button first.",
                engine: .parakeet, audioDuration: 10.1, voicedSeconds: 8.9, processingTime: 0.37),
            TranscriptEntry(
                createdAt: ago(60 * 27),
                text: "Ich schicke dir die Unterlagen morgen früh, dann können wir am Nachmittag kurz telefonieren.",
                engine: .parakeetCloud, audioDuration: 7.3, voicedSeconds: 6.1, processingTime: 0.9, costUSD: 0.00018,
                provider: "Together"),
            TranscriptEntry(
                createdAt: ago(60 * 29),
                text: "Нужно купить молоко, хлеб и кофе, а ещё забрать посылку на почте до семи вечера.",
                engine: .parakeet, audioDuration: 6.4, voicedSeconds: 5.2, processingTime: 0.29),
            TranscriptEntry(
                createdAt: ago(60 * 24 * 3 + 40),
                text: "Hi Maya, thanks for the thoughtful feedback on the proposal. I agree the timeline is tight, so I suggest we cut the export feature from the first milestone and focus on getting dictation rock solid. Happy to talk it through on Friday.",
                engine: .geminiPro, audioDuration: 17.9, voicedSeconds: 15.4, processingTime: 6.8, costUSD: 0.0094),
            TranscriptEntry(
                createdAt: ago(60 * 24 * 4 + 15),
                text: "", engine: .parakeet, status: .cancelled, audioDuration: 4.2, voicedSeconds: 3.1,
                audioFileName: "preview-cancelled.wav"),
            TranscriptEntry(
                createdAt: ago(60 * 24 * 5 + 200),
                text: "Remind me to book the dentist for next week and to reply to the landlord about the heating.",
                engine: .parakeet, audioDuration: 5.8, voicedSeconds: 4.9, processingTime: 0.33),
        ]
    }
}

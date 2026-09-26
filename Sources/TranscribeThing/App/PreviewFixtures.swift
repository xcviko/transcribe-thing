import Foundation

/// Realistic sample data for previews, snapshots and tests.
enum PreviewFixtures {
    static let keyInfo = KeyInfo(label: "transcribe-thing", limit: 20, limitRemaining: 12.40, usage: 7.60,
                                 isFreeTier: false, expiresAt: nil)

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
                engine: .whisperCloud, audioDuration: 14.6, voicedSeconds: 12.8, processingTime: 1.1, costUSD: 0.00016,
                provider: "Groq"),
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

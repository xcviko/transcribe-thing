import Accelerate
import Foundation

/// Engine-side speech checks. The recorder's `SpeechStats` gate most silent dictations before they reach an
/// engine; this is the second line of defense for Whisper, which hallucinates text on silence
/// (WhisperKit's no-speech probability is hardcoded to 0).
enum SilenceGuard {
    private static let frameSeconds = 0.03
    /// −50 dBFS: the quietest frame that can count as voice, even over digital silence.
    private static let absoluteFloor: Float = 0.003_16
    /// Voice must clear the noise floor by 10 dB.
    private static let floorMargin: Float = 3.16
    /// A "floor" louder than −45 dBFS is continuous speech without pauses, not room noise.
    private static let loudestFloor: Float = 0.005_62

    /// Below this, an engine skips inference and reports no speech.
    static let minimumVoicedSeconds = 0.15

    /// Seconds of 30 ms frames whose RMS clears an adaptive threshold: the noise floor (10th-percentile frame,
    /// capped at −45 dBFS) + 10 dB, never below −50 dBFS.
    static func voicedSeconds(_ samples: [Float], sampleRate: Double = 16_000) -> Double {
        let frame = max(1, Int(sampleRate * frameSeconds))
        let count = samples.count / frame
        guard count > 0 else { return 0 }
        var rms = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<count {
                vDSP_rmsqv(base + i * frame, 1, &rms[i], vDSP_Length(frame))
            }
        }
        let floor = min(rms.sorted()[count / 10], loudestFloor)
        let threshold = max(absoluteFloor, floor * floorMargin)
        let voiced = rms.reduce(0) { $1 > threshold ? $0 + 1 : $0 }
        return Double(voiced) * Double(frame) / sampleRate
    }

    /// Phrases Whisper emits on silence or noise (subtitle credits from its training data). Dropped only when
    /// the recording holds little voice, so a genuine "Thank you." still gets through.
    private static let alwaysSuspect: Set<String> = [
        "thanks for watching", "thank you for watching", "thank you so much for watching",
        "thanks for watching and ill see you next time", "please subscribe", "like and subscribe",
        "subtitles by the amaraorg community", "subtitles by", "transcription by castingwords",
        "продолжение следует", "спасибо за просмотр", "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok", "субтитры подогнал симон", "редактор субтитров асемкин корректор аегорова",
        "подписывайтесь на канал", "ставьте лайки и подписывайтесь",
        "untertitel im auftrag des zdf 2017", "untertitel der amaraorg community",
        "soustitres réalisés para la communauté damaraorg", "sous-titres réalisés par la communauté damaraorg",
    ]
    /// Short words a person does dictate; suspect only when there is barely any voice at all.
    private static let suspectWhenNearlySilent: Set<String> = [
        "thank you", "thank you very much", "you", "bye", "bye bye", "спасибо", "спасибо большое", "пока",
    ]

    static func isLikelyHallucination(_ text: String, voicedSeconds: Double) -> Bool {
        let key = normalize(text)
        guard !key.isEmpty else { return false }
        if alwaysSuspect.contains(key) { return voicedSeconds < 2.0 }
        if suspectWhenNearlySilent.contains(key) { return voicedSeconds < 0.4 }
        return false
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(kept))
            .split(separator: " ")
            .joined(separator: " ")
    }
}

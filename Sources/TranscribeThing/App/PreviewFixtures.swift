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
                Hands-free dictation now keeps going through short pauses,
                and the pill’s waveform only moves while you speak.

                ### New
                - **Pause-tolerant hands-free**: stop talking for a moment without ending the dictation. A short
                  silence no longer finishes it; only fn or the check button do.
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
    /// entry, cloud transcripts that record who served them, today's audio kept for Transcribe Again, one
    /// transcript already transcribed again with Gemini and one cleaned up by GPT-6 Luna (from when clean-up was a
    /// model).
    static func history(now: Date = Date()) -> [TranscriptEntry] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            TranscriptEntry(
                createdAt: ago(8),
                text: "Let's move the design review to Thursday afternoon. Could you send me the updated mockups before then? I'd like to walk through the onboarding flow one more time.",
                engine: .parakeet, audioDuration: 11.2, voicedSeconds: 9.6, processingTime: 0.41,
                audioFileName: "preview-recent-1.wav"),
            TranscriptEntry(
                createdAt: ago(31),
                text: "Can you add the Q3 numbers to the deck and flag anything that looks off? I'll go through it tonight.",
                engine: .parakeetCloud, audioDuration: 14.6, voicedSeconds: 12.8, processingTime: 1.1, costUSD: 0.00037,
                audioFileName: "preview-recent-2.wav", provider: "Together"),
            TranscriptEntry(
                createdAt: ago(52), engine: .geminiFlash, audioDuration: 9.8, voicedSeconds: 8.7,
                audioFileName: "preview-recent-3.wav",
                versions: [
                    TranscriptVersion(text: "Привет, созвонимся завтра в 10 утра. Я пришлю ссылку на встречу и короткую повестку.",
                                      engine: .parakeet, processingTime: 0.35, createdAt: ago(52)),
                    TranscriptVersion(
                        kind: .transcription(.geminiFlash),
                        text: "Привет, созвонимся завтра в десять утра. Я пришлю ссылку на встречу и короткую повестку, если что-то поменяется, напиши.",
                        metadata: TranscriptMetadata(
                            createdAt: ago(50), modelID: "google/gemini-3.8-flash", provider: "Google AI Studio",
                            generationID: "gen-preview-1", reasoningEffort: .medium,
                            usage: TokenUsage(promptTokens: 330, audioTokens: 314, completionTokens: 612, reasoningTokens: 540),
                            costUSD: 0.0021, processingTime: 2.6, generationTime: 2.2, usedSystemPrompt: true,
                            finishReason: "stop")),
                ]),
            TranscriptEntry(
                createdAt: ago(135),
                text: "", engine: .geminiFlash, status: .failed, audioDuration: 23.4, voicedSeconds: 19.8,
                errorMessage: "Gemini Flash took too long", audioFileName: "preview-failed.wav"),
            TranscriptEntry(
                createdAt: ago(60 * 26), engine: .parakeet, audioDuration: 10.1, voicedSeconds: 8.9,
                versions: [
                    TranscriptVersion(text: "Quick note for the release, um, the pill should should collapse a little faster than it, uh, expands and the error toast needs the retry button first.",
                                      engine: .parakeet, processingTime: 0.37, createdAt: ago(60 * 26)),
                    TranscriptVersion(
                        kind: .cleanup(of: .parakeet, by: .gpt6Luna),
                        text: "Quick note for the release: the pill should collapse a little faster than it expands, and the error toast needs the retry button first.",
                        metadata: TranscriptMetadata(
                            createdAt: ago(60 * 26), modelID: "openai/gpt-6-luna", provider: "OpenAI",
                            generationID: "gen-preview-2", reasoningEffort: .off,
                            usage: TokenUsage(promptTokens: 410, completionTokens: 34),
                            costUSD: 0.00006, processingTime: 1.1, generationTime: 0.9, usedSystemPrompt: true,
                            finishReason: "stop")),
                ]),
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
                engine: .geminiFlash, audioDuration: 17.9, voicedSeconds: 15.4, processingTime: 4.1, costUSD: 0.0031),
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

    // MARK: Calls

    /// The calls of the Calls tab, newest first: a Telegram call being transcribed, a Google Meet call in Chrome done
    /// with three speakers besides Sam, two mutes (something said in one), another tab's sound and a summary with a title (two of its
    /// four tasks done), a Zoom call that failed, a Discord call never answered about, a Slack huddle the app quit
    /// during, and a Telemost call whose other side came out silent and whose summary failed.
    static func calls(now: Date = Date(), calendar: Calendar = .current) -> [CallRecord] {
        let today = calendar.startOfDay(for: now)
        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func call(_ id: Int, _ start: Date, app: String, bundleID: String, service: CallService?, page: String? = nil,
                  seconds: TimeInterval, status: CallStatus) -> CallRecord {
            var record = CallRecord(id: callID(id), startedAt: start, endedAt: start.addingTimeInterval(seconds),
                                    appName: app, bundleID: bundleID, service: service, pageTitle: page, status: status)
            record.micFile = "mic.m4a"
            record.remoteFile = "remote.m4a"
            record.micSeconds = seconds
            record.remoteSeconds = seconds
            record.muteKnown = true
            return record
        }

        var telegram = call(1, at(daysAgo: 0, 9, 40), app: "Telegram", bundleID: "ru.keepcoder.Telegram",
                            service: .telegram, seconds: 492, status: .transcribing)
        telegram.muteIntervals = [CallInterval(start: 120, end: 151)]
        telegram.micSilencedWhenMuted = true

        var meet = call(2, at(daysAgo: 0, 8, 5), app: "Google Chrome", bundleID: "com.google.Chrome", service: .meet,
                        page: "Meet – abc-defg-hij", seconds: 1934, status: .done)
        meet.muteIntervals = [CallInterval(start: 158, end: 170), CallInterval(start: 842, end: 910)]
        meet.otherBrowserAudio = [CallInterval(start: 1210, end: 1236)]
        meet.costUSD = 0.043
        meet.speakerNames = ["Participant 1": "Matvey"]
        meet.transcript = CallTranscript(segments: [
            .init(start: 4, end: 9, side: .remote, speaker: "Participant 1",
                  text: "Okay, I think everyone’s here. Let’s start with the release plan."),
            .init(start: 10, end: 17, side: .remote, speaker: "Аня",
                  text: "Привет! Я посмотрела сборку: импорт файлов работает, но длинные файлы грузятся долго."),
            .init(start: 18, end: 26, side: .local, speaker: "Sam",
                  text: "Yeah, that’s the request limit. I’ll split them into chunks before they’re sent."),
            .init(start: 27, end: 30, side: .local, speaker: "Sam",
                  text: "It’s maybe a day of work, with tests."),
            .init(start: 31, end: 34, side: .remote, speaker: "Participant 2", text: "Can we ship on Friday then?"),
            .init(start: 160, end: 164, side: .local, speaker: "Sam", text: "Ugh, my coffee’s gone cold again.",
                  duringMute: true),
            .init(start: 171, end: 179, side: .remote, speaker: "Participant 1",
                  text: "Friday works. Аня, can you check the long files over the weekend?"),
            .init(start: 180, end: 182, side: .remote, speaker: "Аня", text: "Да, без проблем."),
            .init(start: 184, end: 190, side: .local, speaker: "Sam",
                  text: "Great. I’ll send the notes after the call, with who does what."),
        ])
        meet.summary = CallSummary(
            title: "Friday release and slow long files",
            // Its speakers marked as Gemini writes them (`CallMention`): Participant 1 shows as Matvey, renamed.
            summary: "The team went over the release plan. Long files load slowly because of the request limit, so "
                + "{{Sam}} will split them into chunks, and the release moves to Friday.",
            keyPoints: [
                "File import works, but long files take a long time to load.",
                "The cause is the request limit; splitting files into chunks is about a day of work, with tests.",
                "{{Participant 1}} asked {{Аня}} to test long files over the weekend.",
            ],
            decided: ["Ship on Friday, as {{Participant 2}} suggested."],
            tasks: [
                CallTask(id: callTaskID(1), owner: "Sam", text: "Split long files into chunks before they’re sent",
                         done: true),
                CallTask(id: callTaskID(2), owner: "Аня",
                         text: "Проверить длинные файлы и написать {{Participant 1|первому участнику}}",
                         due: "на выходных"),
                CallTask(id: callTaskID(3), owner: "Sam", text: "Send the notes with who does what",
                         due: "after the call", done: true),
                CallTask(id: callTaskID(4), owner: "Participant 1", text: "Confirm the Friday release with support"),
            ],
            open: ["Whether long files load fast enough once they’re split."],
            createdAt: meet.startedAt)

        var zoom = call(3, at(daysAgo: 1, 16, 30), app: "zoom.us", bundleID: "us.zoom.xos", service: .zoom,
                        seconds: 2710, status: .failed)
        zoom.error = "Gemini 3.8 Flash took too long"

        let discord = call(4, at(daysAgo: 1, 11, 12), app: "Discord", bundleID: "com.hnc.Discord", service: .discord,
                           seconds: 1260, status: .unconfirmed)

        var slack = call(5, at(daysAgo: 3, 15, 0), app: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                         service: .slack, seconds: 845, status: .interrupted)
        slack.error = CallStore.interruptedMessage
        slack.muteKnown = false

        var telemost = call(6, at(daysAgo: 4, 10, 0), app: "Telemost", bundleID: "ru.yandex.desktop.telemost",
                            service: .telemost, seconds: 1505, status: .done)
        telemost.remoteProblem = CallStore.silentTapMessage
        telemost.costUSD = 0.011
        telemost.transcript = CallTranscript(segments: [
            .init(start: 3, end: 9, side: .local, speaker: "Sam",
                  text: "Да, слышу. Давайте начнём с бюджета на следующий квартал."),
            .init(start: 40, end: 47, side: .local, speaker: "Sam",
                  text: "Хорошо, тогда я пришлю таблицу до пятницы."),
        ])
        telemost.summaryError = "Gemini 3.8 Flash took too long"

        return [telegram, meet, zoom, discord, slack, telemost]
    }

    /// The fixture calls' ids, stable so snapshots can pick one.
    static func callID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    /// A made-up loudness for `call`'s waveform: words rising and falling where its transcript has someone speaking,
    /// a low hum elsewhere (a call not transcribed speaks in bursts: two stretches of 7 seconds in three). The same
    /// every time.
    static func peaks(for call: CallRecord) -> CallPeaks {
        let count = Int(call.duration / CallPeaks.bucketSeconds)
        let segments = call.transcript?.segments ?? (0..<Int(call.duration / 7)).compactMap { index in
            index % 3 == 2 ? nil : CallTranscript.Segment(start: Double(index) * 7, end: Double(index) * 7 + 7,
                                                          side: .remote, speaker: "", text: "")
        }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24)
        }
        return CallPeaks(values: (0..<count).map { index in
            let time = Double(index) * CallPeaks.bucketSeconds
            guard segments.contains(where: { time >= $0.start && time < $0.end }) else { return 0.01 + 0.02 * random() }
            let words = 0.5 + 0.5 * sin(time * 1.7) * sin(time * 0.43 + 1)
            return Float(0.12 + 0.7 * words) * (0.6 + 0.4 * random())
        })
    }

    /// The fixture summaries' task ids.
    static func callTaskID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n))!
    }

    /// A Google Meet call in Chrome being recorded now, `seconds` in: as the monitor knows it.
    static func liveCall(startedAt: Date) -> CallMonitor.CallInfo {
        CallMonitor.CallInfo(id: callID(99), appName: "Google Chrome", bundleID: "com.google.Chrome", service: .meet,
                             pageTitle: "Meet – xyz-abcd-efg", startedAt: startedAt, muteKnown: true)
    }
}

import Foundation
import Testing
@testable import TranscribeThing

// Reading a call app's mute from its controls (`MuteRules`, `ZoomMenu`) and finding the browser tab a call is in
// (`BrowserTabs`, `CallService.of`). The labels are the apps' own; the Russian ones for Discord and Zoom are guesses.

@Suite struct CallMuteTests {
    private func button(_ label: String, enabled: Bool? = true) -> CallControl {
        CallControl(role: "AXButton", label: label, enabled: enabled)
    }

    private func state(_ service: CallService, _ controls: [CallControl]) -> MuteState {
        service.rules.read(controls).state
    }

    // MARK: Labels

    @Test func labelsAreComparedWholeWhateverTheCaseSpacingShortcutOrRepetition() {
        #expect(CallLabels.normalize("  Turn off   microphone (⌘ + d) ") == "turn off microphone")
        #expect(CallLabels.normalize("Mute microphone Mute microphone") == "mute microphone")
        #expect(CallLabels.normalize("Turn off microphone (⌘ + d) Turn off microphone (⌘ + d)") == "turn off microphone")
        #expect(CallLabels.normalize("Mute Mute") == "mute")
        #expect(CallLabels.normalize("Mute my mute") == "mute my mute")
        #expect(CallLabels.normalize("ВКЛЮЧИТЬ МИКРОФОН") == "включить микрофон")
        #expect(CallLabels.normalize("Отключить звук…") == "отключить звук")
        #expect(CallLabels.normalize("Откл. микрофон") == "откл. микрофон")
        #expect(CallLabels.normalize("(3)") == "(3)", "a label that is only a hint stays")
    }

    @Test func linksNeverReachTheOutput() {
        #expect(CallLabels.safe("Join https://us02web.zoom.us/j/123?pwd=abc now") == "Join <link> now")
        #expect(CallLabels.safe("copy meet.google.com/abc-defg-hij") == "copy <link>")
        #expect(CallLabels.safe("two\nlines") == "two lines")
        #expect(CallLabels.safe(String(repeating: "a", count: 100), limit: 10) == "aaaaaaaaa…")
    }

    // MARK: Services

    @Test func googleMeetInEnglishAndRussian() {
        #expect(state(.meet, [button("Turn off microphone (⌘ + d)")]) == .live)
        #expect(state(.meet, [button("Turn on microphone (⌘ + d)")]) == .muted)
        #expect(state(.meet, [button("Выключить микрофон (⌘ + d)")]) == .live)
        #expect(state(.meet, [button("включить микрофон")]) == .muted)
        let read = CallService.meet.rules.read([button("Present now"), button("Turn on microphone"), button("Leave call")])
        #expect(read == MuteRead(state: .muted, inCall: true, detail: "AXButton \"Turn on microphone\""))
        #expect(CallService.meet.rules.read([button("Turn off microphone")]).inCall == false, "the waiting room")
        #expect(CallService.meet.rules.read([button("Покинуть видеовстречу"), button("Выключить микрофон")]).inCall == true)
    }

    @Test func discordsMuteSwitchSaysMutedWhenOn() {
        let on = CallControl(role: "AXCheckBox", subrole: "AXSwitch", label: "Mute", value: 1, identifier: "mute")
        let read = CallService.discord.rules.read([on, button("Disconnect")])
        #expect(read == MuteRead(state: .muted, inCall: true, detail: "AXCheckBox \"Mute\" value=1 id=mute"))
        #expect(state(.discord, [CallControl(role: "AXCheckBox", label: "Mute", value: 0)]) == .live)
        #expect(state(.discord, [CallControl(role: "AXCheckBox", title: "MUTE MUTE", value: 1)]) == .muted)
        #expect(state(.discord, [button("Unmute")]) == .muted, "a plain button names what it would do")
        #expect(state(.discord, [button("Mute")]) == .live)
        #expect(state(.discord, [CallControl(role: "AXCheckBox", label: "Откл. микрофон", value: 1)]) == .muted)
        #expect(state(.discord, [button("Вкл. микрофон")]) == .muted)
        #expect(CallService.discord.rules.read([button("Mute"), button("Отключиться")]).inCall == true)
        #expect(CallService.discord.rules.read([button("Mute")]).inCall == false)
    }

    @Test func slacksHuddle() {
        #expect(state(.slack, [button("Mute microphone")]) == .live)
        #expect(state(.slack, [button("Unmute microphone Unmute microphone")]) == .muted)
        #expect(state(.slack, [CallControl(role: "AXCheckBox", subrole: "AXSwitch", title: "Microphone", value: 1)]) == .live)
        #expect(state(.slack, [CallControl(role: "AXCheckBox", subrole: "AXSwitch", title: "Microphone", value: 0)]) == .muted)
        #expect(state(.slack, [button("Microphone")]) == .unknown("no mute control found"), "a switch without a value says nothing")
        #expect(CallService.slack.rules.read([button("Leave huddle"), button("Mute microphone")]).inCall == true)
    }

    @Test func zoomOnTheWebAndTelemost() {
        #expect(state(.zoom, [button("mute my microphone")]) == .live)
        #expect(state(.zoom, [button("Unmute my microphone")]) == .muted)
        #expect(state(.telemost, [button("Выключить микрофон")]) == .live)
        #expect(state(.telemost, [button("Turn on microphone")]) == .muted)
        #expect(CallService.telemost.rules.read([button("Завершить звонок")]).inCall == true)
    }

    @Test func theFirstEnabledKnownControlDecides() {
        #expect(state(.meet, [button("Turn on microphone", enabled: false), button("Turn off microphone")]) == .live)
        #expect(state(.meet, [button("Turn off microphone"), button("Turn on microphone")]) == .live)
        #expect(state(.meet, [button("Mute")]) == .unknown("no mute control found"))
    }

    @Test func telegramWebHasNoLabelsYet() {
        let read = CallService.telegram.rules.read([button("Mute"), button("Leave")])
        #expect(read == MuteRead(state: .unknown("no labels known for it yet"), inCall: nil, detail: "2 controls read"))
    }

    @Test func appsByBundleID() {
        #expect(CallAppKind.of("us.zoom.xos") == .zoomDesktop)
        #expect(CallAppKind.of("com.hnc.Discord") == .electron(.discord))
        #expect(CallAppKind.of("com.tinyspeck.slackmacgap") == .electron(.slack))
        #expect(CallAppKind.of("ru.yandex.desktop.telemost") == .electron(.telemost))
        #expect(CallAppKind.of("ru.keepcoder.Telegram") == .telegramDesktop)
        for browser in ["com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
                        "ru.yandex.desktop.yandex-browser", "com.apple.Safari"] {
            #expect(CallAppKind.of(browser) == .browser, "\(browser)")
        }
        #expect(CallAppKind.of("com.apple.FaceTime") == .other)
    }

    // MARK: Zoom's menu

    private func menuItem(_ title: String, menu: String = "Meeting", enabled: Bool = true, id: String? = nil) -> CallControl {
        CallControl(role: "AXMenuItem", title: title, identifier: id, enabled: enabled, menu: menu)
    }

    @Test func zoomsMeetingMenuSaysMuteOrUnmuteAudio() {
        let muted = ZoomMenu.read([menuItem("Mute audio", enabled: false), menuItem("Unmute audio", id: "onMuteAudio:"),
                                   menuItem("Start video")])
        #expect(muted == MuteRead(state: .muted, inCall: true, detail: "Meeting ▸ Unmute audio id=onMuteAudio:"))
        #expect(ZoomMenu.read([menuItem("Mute Audio")]).state == .live)
        #expect(ZoomMenu.read([menuItem("Включить звук", menu: "Конференция")]).state == .muted)
        #expect(ZoomMenu.read([menuItem("Mute audio", menu: "Edit")]).state == .unknown("no Meeting menu"),
                "the same title in another menu doesn't count")
    }

    @Test func zoomOutsideAMeeting() {
        let read = ZoomMenu.read([menuItem("Mute audio", enabled: false), menuItem("Unmute audio", enabled: false)])
        #expect(read.state == .unknown("no enabled Mute audio or Unmute audio"))
        #expect(read.inCall == false)
        let noMenu = ZoomMenu.read([menuItem("Copy", menu: "Edit")])
        #expect(noMenu == MuteRead(state: .unknown("no Meeting menu"), inCall: nil, detail: "1 menu items read"))
    }

    @Test func aDumpListsLabelledControlsOnceWithoutLinks() {
        let controls = [
            CallControl(role: "AXButton", label: "Microphone", identifier: "mic"),
            CallControl(role: "AXButton"),
            CallControl(role: "AXButton", label: "Microphone", identifier: "mic"),
            CallControl(role: "AXCheckBox", subrole: "AXSwitch", title: "Camera", value: 0, enabled: false),
            CallControl(role: "AXButton", label: "Copy https://telemost.yandex.ru/j/123"),
            menuItem("Mute audio", id: "onMuteAudio:"),
        ]
        #expect(CallControl.dump(controls) == [
            "AXButton d=\"Microphone\" id=mic",
            "AXCheckBox/AXSwitch t=\"Camera\" v=0 disabled",
            "AXButton d=\"Copy <link>\"",
            "Meeting ▸ AXMenuItem t=\"Mute audio\" id=onMuteAudio:",
        ])
        #expect(CallControl.dump(controls, limit: 2).count == 2)
    }

    // MARK: Browser tabs

    @Test func aTabTitleWithoutWhatTheBrowserAdded() {
        func parse(_ title: String) -> BrowserTabs.Title { BrowserTabs.parse(title) }
        #expect(parse("Meet - abc-defg-hij - Camera and microphone recording")
            == .init(page: "Meet - abc-defg-hij", recording: .cameraAndMic))
        #expect(parse("Meet – abc-defg-hij – Microphone recording") == .init(page: "Meet – abc-defg-hij", recording: .mic))
        #expect(parse("Zoom Meeting - Camera recording") == .init(page: "Zoom Meeting", recording: .camera))
        #expect(parse("Discord - Tab content shared") == .init(page: "Discord", recording: .tab))
        #expect(parse("Slack - Desktop content shared") == .init(page: "Slack", recording: .desktop))
        #expect(parse("Meet - abc - camera AND microphone RECORDING") == .init(page: "Meet - abc", recording: .cameraAndMic))
        #expect(parse("Meet - abc - Audio playing - Microphone recording") == .init(page: "Meet - abc", recording: .mic))
        #expect(parse("YouTube - Audio playing") == .init(page: "YouTube", recording: nil))
        #expect(parse("Плейлист") == .init(page: "Плейлист", recording: nil))
    }

    @Test func russianTabTitles() {
        #expect(BrowserTabs.parse("Телемост, включена запись с камеры и микрофона")
            == .init(page: "Телемост", recording: .cameraAndMic))
        #expect(BrowserTabs.parse("Meet - abc-defg-hij, включена запись с микрофона")
            == .init(page: "Meet - abc-defg-hij", recording: .mic))
        #expect(BrowserTabs.parse("Zoom, включена запись с камеры") == .init(page: "Zoom", recording: .camera))
        #expect(BrowserTabs.parse("Discord: доступ к содержимому вкладки открыт") == .init(page: "Discord", recording: .tab))
        #expect(BrowserTabs.parse("Slack: доступ к содержимому рабочего стола открыт")
            == .init(page: "Slack", recording: .desktop))
    }

    @Test func theServiceFromAPageTitle() {
        let titles: [(String, CallService?)] = [
            ("Meet - abc-defg-hij", .meet), ("Meet – abc-defg-hij", .meet), ("Meet", .meet), ("Google Meet", .meet),
            ("Meeting notes - Google Docs", nil),
            ("Zoom Meeting", .zoom), ("Zoom", .zoom), ("Zoom Workplace", .zoom), ("Zoomer memes", nil),
            ("Discord", .discord), ("#general | My Server | Discord", .discord), ("(2) Discord | Friends", .discord),
            ("Telegram", .telegram), ("Telegram Web", .telegram), ("(5) Telegram Web", .telegram),
            ("Slack", .slack), ("general (Channel) - Acme - Slack", .slack), ("Huddle in #design", .slack),
            ("Телемост", .telemost), ("Встреча в Телемосте", .telemost), ("Yandex Telemost", .telemost),
            ("Inbox (3) - Gmail", nil),
        ]
        for (title, service) in titles {
            #expect(CallService.of(pageTitle: title) == service, "\(title)")
        }
    }

    @Test func theCallTabIsTheOneRecordingTheMicWhereverItIs() throws {
        let windows = [
            BrowserTabs.Window(title: "Inbox - Gmail", tabs: [
                .init(title: "Inbox - Gmail", selected: true),
                .init(title: "YouTube - Camera recording", selected: false),
            ]),
            BrowserTabs.Window(title: "Docs", tabs: [
                .init(title: "Docs", selected: true),
                .init(title: "Meet - abc-defg-hij - Camera and microphone recording", selected: false),
            ]),
        ]
        let tab = try #require(BrowserTabs.callTab(in: windows))
        #expect(tab == BrowserTabs.CallTab(window: 1, tab: 1, windowTitle: "Docs", page: "Meet - abc-defg-hij",
                                           recording: .cameraAndMic, service: .meet, active: false))
    }

    @Test func aTabIsActiveWhenSelectedOrNamedByItsWindow() throws {
        let selected = [BrowserTabs.Window(title: nil, tabs: [
            .init(title: "Telegram Web - Microphone recording", selected: true)])]
        #expect(try #require(BrowserTabs.callTab(in: selected)).active)
        let titled = [BrowserTabs.Window(title: "Meet - abc-defg-hij - Google Chrome", tabs: [
            .init(title: "Meet - abc-defg-hij - Microphone recording", selected: nil)])]
        #expect(try #require(BrowserTabs.callTab(in: titled)).active)
        let other = [BrowserTabs.Window(title: "Inbox", tabs: [
            .init(title: "Meet - abc-defg-hij - Microphone recording", selected: nil)])]
        #expect(try #require(BrowserTabs.callTab(in: other)).active == false)
    }

    @Test func aKnownServiceGoesBeforeAnUnknownPageAndTheActiveTabBreaksTies() throws {
        let windows = [BrowserTabs.Window(title: "x", tabs: [
            .init(title: "Some page - Microphone recording", selected: false),
            .init(title: "Discord - Microphone recording", selected: false),
            .init(title: "Zoom Meeting - Microphone recording", selected: true),
        ])]
        #expect(try #require(BrowserTabs.callTab(in: windows)).service == .zoom)
        let unknown = [BrowserTabs.Window(title: "x", tabs: [.init(title: "Some page - Microphone recording", selected: true)])]
        #expect(try #require(BrowserTabs.callTab(in: unknown)).service == nil)
    }

    @Test func withoutARecordingMarkACallIsFoundByItsTitle() throws {
        // Safari adds nothing to a tab's title while it records.
        let windows = [BrowserTabs.Window(title: "Telegram Web", tabs: [
            .init(title: "Discord", selected: false),
            .init(title: "Telegram Web", selected: true),
            .init(title: "Weather", selected: false),
        ])]
        let tab = try #require(BrowserTabs.callTab(in: windows))
        #expect(tab.service == .telegram && tab.recording == nil && tab.active)
        #expect(BrowserTabs.callTab(in: [BrowserTabs.Window(title: "Weather", tabs: [.init(title: "Weather", selected: true)])]) == nil)
    }
}

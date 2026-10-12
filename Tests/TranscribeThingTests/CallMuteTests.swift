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
        #expect(state(.slack, [button("Mute mic")]) == .live && state(.slack, [button("Unmute mic")]) == .muted)
        #expect(state(.slack, [button("Turn off microphone")]) == .live)
        #expect(state(.slack, [button("Turn on microphone")]) == .muted)
        #expect(state(.slack, [CallControl(role: "AXCheckBox", subrole: "AXSwitch", label: "Mic", value: 0)]) == .muted)
        #expect(state(.slack, [CallControl(role: "AXCheckBox", subrole: "AXToggle", label: "Mute mic", value: 1)]) == .muted,
                "a pressed Mute toggle is muted")
        #expect(state(.slack, [CallControl(role: "AXCheckBox", subrole: "AXToggle", label: "Mute mic", value: 0)]) == .live)
        #expect(CallService.slack.rules.read([button("Leave"), button("Unmute mic")]).inCall == true)
    }

    /// A site no service is known for: a label that only means the mic is trusted at once; a bare Mute or Unmute
    /// (a video's sound, maybe) only once both have shown during the call. Links, menus and text say nothing.
    @Test func anUnknownSitesMuteIsTrustedOnlyWhenItCanOnlyBeTheMic() {
        var generic = GenericMute()
        #expect(generic.read([button("Unmute microphone")]).state == .muted)
        #expect(generic.read([button("Turn off microphone (⌘ + d)")]).state == .live)
        #expect(generic.read([button("Выключить микрофон")]).state == .live)
        #expect(generic.read([CallControl(role: "AXMenuItem", label: "Unmute microphone")]).state.isKnown == false)
        #expect(generic.read([CallControl(role: "AXLink", label: "Mute microphone")]).state.isKnown == false)

        var bare = GenericMute()
        #expect(bare.read([button("Mute")]).state == .unknown("a Mute button not seen turning over yet"))
        #expect(bare.read([button("Mute")]).state.isKnown == false)
        #expect(bare.read([button("Unmute")]).state == .muted, "both seen: it turns over with the mic")
        #expect(bare.read([button("Mute")]).state == .live)
        #expect(bare.read([button("Share screen")]).state == .unknown("no mute control found"))
        #expect(bare.read([]).inCall == nil)
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

    /// Telegram Web's call bar from the log (/a): "Mute" whether muted or not, so only "End" says anything.
    @Test func telegramWebShowsOnlyThatItsInACall() {
        let bar = [button("New Chats"), button("     "), button("Mute"), button("Open call"), button("End"),
                   CallControl(role: "AXButton", title: "Camera"), CallControl(role: "AXButton", title: "Screen"),
                   CallControl(role: "AXButton", title: "Mute"), CallControl(role: "AXButton", title: "Accept")]
        let read = CallService.telegram.rules.read(bar)
        #expect(read == MuteRead(state: .unknown("its Mute button doesn't change, a released mic is its mute"),
                                 inCall: true, detail: "9 controls read"))
        #expect(CallService.telegram.rules.read([button("New Chats"), button("Mute")]).inCall == false)
    }

    /// Discord's Russian client from the log: the mute switch is "Заглушить", and "Откл. звук" (Deafen) isn't it.
    @Test func discordInRussian() {
        func toggle(_ title: String, _ value: Int?) -> CallControl {
            CallControl(role: "AXCheckBox", subrole: "AXSwitch", title: title, label: title, value: value)
        }
        #expect(state(.discord, [toggle("Заглушить", 1), toggle("Откл. звук", 0)]) == .muted)
        #expect(state(.discord, [toggle("Откл. звук", 1), toggle("Заглушить", 0)]) == .live)
        #expect(state(.discord, [toggle("Откл. звук", 1)]) == .unknown("no mute control found"), "deafen isn't mute")
        #expect(state(.discord, [toggle("Заглушить", nil)]) == .unknown("no mute control found"),
                "without its value the switch says nothing")
        #expect(state(.discord, [toggle("Mute", 1), toggle("Deafen", 0)]) == .muted)
        #expect(CallService.discord.rules.read([toggle("Заглушить", 0), button("Отключиться")]).inCall == true)
        #expect(CallService.discord.rules.read([toggle("Mute", 0), button("Disconnect")]).inCall == true)
    }

    /// Zoom on the web from the log: "join audio" (disabled) before joining the meeting's audio, "Завершить" (End)
    /// to leave in Russian.
    @Test func zoomOnTheWebBeforeAndAfterJoiningAudio() {
        let before = [button("Meeting information"), button("Switch to Zoom Workplace Client"),
                      button("join audio", enabled: false), button("start my video", enabled: false),
                      button("open the chat panel"), button("Поделиться"), button("Host tools"), button("Завершить")]
        #expect(CallService.zoom.rules.read(before)
            == MuteRead(state: .unknown("audio not joined yet"), inCall: true, detail: "AXButton \"join audio\""))
        let joined = [button("mute my microphone"), button("start my video"), button("Завершить")]
        #expect(CallService.zoom.rules.read(joined)
            == MuteRead(state: .live, inCall: true, detail: "AXButton \"mute my microphone\""))
        #expect(state(.zoom, [button("unmute my microphone"), button("End")]) == .muted)
        #expect(CallService.zoom.rules.read([button("Войти в систему")]).inCall == false)
    }

    @Test func onlyTelegramReleasesTheMicToMute() {
        #expect(CallService.allCases.filter(\.releasesMicOnMute) == [.telegram])
        #expect(CallAppKind.of("ru.keepcoder.Telegram").service == .telegram)
        #expect(CallAppKind.of("com.hnc.Discord").service == .discord)
        #expect(CallAppKind.of("us.zoom.xos").service == .zoom)
        #expect(CallAppKind.of("com.google.Chrome").service == nil, "a browser's service is its tab's")
        #expect(CallAppKind.of("com.apple.FaceTime").service == nil)
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

    /// Every tab title in the log of Meet, Discord, Zoom, Slack, Telemost and Telegram Web in one Chrome: the page,
    /// what it records, the service.
    @Test func everyTabTitleFromTheLog() {
        let titles: [(String, String, BrowserTabs.Recording?, CallService?)] = [
            ("Meet – gkz-omip-mob - Camera and microphone recording", "Meet – gkz-omip-mob", .cameraAndMic, .meet),
            ("Meet – gkz-omip-mob - Microphone recording", "Meet – gkz-omip-mob", .mic, .meet),
            ("Meet – gkz-omip-mob - Audio playing - Memory usage - 446 MB", "Meet – gkz-omip-mob", nil, .meet),
            ("Meet – gkz-omip-mob - Memory usage - 453 MB", "Meet – gkz-omip-mob", nil, .meet),
            ("Meet – gkz-omip-mob - Permission requested, press ⌘ + Option + Up arrow to respond",
             "Meet – gkz-omip-mob", nil, .meet),
            ("Meet – gkz-omip-mob - Permission requested, press ⌘ + Option + Up arrow to resp…",
             "Meet – gkz-omip-mob", nil, .meet),
            ("Google Meet", "Google Meet", nil, .meet),
            ("Google Meet - Memory usage - 463 MB", "Google Meet", nil, .meet),
            ("Discord", "Discord", nil, .discord),
            ("• Discord | Друзья", "Discord | Друзья", nil, .discord),
            ("• Discord | #основной | Сервер package.json", "Discord | #основной | Сервер package.json", nil, .discord),
            ("• Discord | #основной | Сервер package.json - Microphone recording",
             "Discord | #основной | Сервер package.json", .mic, .discord),
            ("• Discord | #основной | Сервер package.json - Audio playing",
             "Discord | #основной | Сервер package.json", nil, .discord),
            ("Zoom: Единая платформа для связи", "Zoom: Единая платформа для связи", nil, .zoom),
            ("Войти в систему | Zoom", "Войти в систему | Zoom", nil, .zoom),
            ("Я согласен с условиями обслуживания - Zoom", "Я согласен с условиями обслуживания - Zoom", nil, .zoom),
            ("Главная - Zoom", "Главная - Zoom", nil, .zoom),
            ("Присоединиться к конференции | Zoom", "Присоединиться к конференции | Zoom", nil, .zoom),
            ("Присоединиться через приложение Zoom Workplace - Zoom",
             "Присоединиться через приложение Zoom Workplace - Zoom", nil, .zoom),
            ("Zoom", "Zoom", nil, .zoom),
            ("Zoom - Memory usage - 660 MB", "Zoom", nil, .zoom),
            ("Zoom Meeting Matvey Litvin - Permission requested, press ⌘ + Option + Up arrow …",
             "Zoom Meeting Matvey Litvin", nil, .zoom),
            ("Zoom Meeting Matvey Litvin - Microphone recording", "Zoom Meeting Matvey Litvin", .mic, .zoom),
            ("Matvey Litvin (AI) (DM) - V-Soft - Slack", "Matvey Litvin (AI) (DM) - V-Soft - Slack", nil, .slack),
            ("Huddles - V-Soft - Slack - Memory usage - 283 MB", "Huddles - V-Soft - Slack", nil, .slack),
            ("Идёт звонок · Яндекс Телемост - Camera and microphone recording", "Идёт звонок · Яндекс Телемост",
             .cameraAndMic, .telemost),
            ("Яндекс Телемост - Memory usage - 271 MB", "Яндекс Телемост", nil, .telemost),
            ("Telegram Web", "Telegram Web", nil, .telegram),
            ("Telegram Web - Microphone recording", "Telegram Web", .mic, .telegram),
            ("Telegram Web - Memory usage - 178 MB", "Telegram Web", nil, .telegram),
            ("Telegram Web - Audio playing - Memory usage - 178 MB", "Telegram Web", nil, .telegram),
            ("LION Мыло-пенка для рук Kirei Kirei \"Воздушное\"", "LION Мыло-пенка для рук Kirei Kirei \"Воздушное\"",
             nil, nil),
            ("Вход – Google Аккаунты", "Вход – Google Аккаунты", nil, nil),
            ("New Tab", "New Tab", nil, nil),
        ]
        for (title, page, recording, service) in titles {
            let parsed = BrowserTabs.parse(title)
            #expect(parsed == .init(page: page, recording: recording), "\(title)")
            #expect(CallService.of(pageTitle: parsed.page) == service, "\(title)")
        }
    }

    @Test func unreadMarksAndTheOtherAlertsGo() {
        #expect(BrowserTabs.withoutUnreadMark("(3) Inbox") == "Inbox")
        #expect(BrowserTabs.withoutUnreadMark("(99+) Telegram Web") == "Telegram Web")
        #expect(BrowserTabs.withoutUnreadMark("• Discord | Друзья") == "Discord | Друзья")
        #expect(BrowserTabs.withoutUnreadMark("(2) • Discord") == "Discord")
        #expect(BrowserTabs.withoutUnreadMark("(draft) notes") == "(draft) notes")
        #expect(BrowserTabs.parse("YouTube - Audio muted - Memory usage - 1.2 GB") == .init(page: "YouTube", recording: nil))
        #expect(BrowserTabs.parse("Meet – abc – Audio playing") == .init(page: "Meet – abc", recording: nil))
        #expect(BrowserTabs.parse("Telegram Web, воспроизводится аудио") == .init(page: "Telegram Web", recording: nil))
        #expect(BrowserTabs.parse("Telegram Web - Использование памяти: 178 МБ") == .init(page: "Telegram Web", recording: nil))
        #expect(BrowserTabs.parse("(1) Meet – abc - Memory usage - 90 MB - Microphone recording")
            == .init(page: "Meet – abc", recording: .mic), "a recording mark counts wherever it is")
    }

    /// One call is told from another by its service, and a Meet meeting by its code: Discord, Telemost and Zoom
    /// retitle their tab during a call.
    @Test func tabKeys() {
        #expect(BrowserTabs.key(service: .meet, page: "Meet – gkz-omip-mob") != BrowserTabs.key(service: .meet, page: "Meet – abc-defg-hij"))
        #expect(BrowserTabs.key(service: .meet, page: "Meet – gkz-omip-mob") == BrowserTabs.key(service: .meet, page: "Meet  –  GKZ-omip-mob"))
        #expect(BrowserTabs.key(service: .discord, page: "Discord | Друзья")
            == BrowserTabs.key(service: .discord, page: "Discord | #основной | Сервер package.json"))
        #expect(BrowserTabs.key(service: .telemost, page: "Идёт звонок · Яндекс Телемост")
            == BrowserTabs.key(service: .telemost, page: "Яндекс Телемост"))
        #expect(BrowserTabs.key(service: .zoom, page: "Zoom") == BrowserTabs.key(service: .zoom, page: "Zoom Meeting Matvey Litvin"))
        #expect(BrowserTabs.key(service: nil, page: "Some call") != BrowserTabs.key(service: nil, page: "Another call"))
        #expect(BrowserTabs.key(service: .discord, page: "Discord") != BrowserTabs.key(service: .meet, page: "Google Meet"))
    }

    /// The log at 551.4: Meet's tab after leaving, in another window, and Discord's in front; neither records.
    @Test func withoutARecordingMarkTheCallFollowedThenTheTabInFront() throws {
        let windows = [
            BrowserTabs.Window(title: "• Discord | Друзья - Google Chrome - Matvey", tabs: [
                .init(title: "• Discord | Друзья", selected: nil)]),
            BrowserTabs.Window(title: "New Tab - Google Chrome - Matvey", tabs: [
                .init(title: "Meet – gkz-omip-mob - Memory usage - 446 MB", selected: false),
                .init(title: "New Tab", selected: true)]),
        ]
        let front = try #require(BrowserTabs.callTab(in: windows))
        #expect(front.service == .discord && front.active && front.page == "Discord | Друзья")
        let meetKey = BrowserTabs.key(service: .meet, page: "Meet – gkz-omip-mob")
        let followed = try #require(BrowserTabs.callTab(in: windows, following: meetKey))
        #expect(followed.service == .meet && !followed.active && followed.key == meetKey)
    }

    /// "Permission requested" takes the place of the recording mark, so a tab asking it is found by its title.
    @Test func aTabAskingPermissionIsFoundByItsTitle() throws {
        let windows = [BrowserTabs.Window(title: "x", tabs: [
            .init(title: "Google Meet - Memory usage - 463 MB", selected: false),
            .init(title: "Zoom Meeting Matvey Litvin - Permission requested, press ⌘ + Option + Up arrow to respond",
                  selected: true),
        ])]
        let tab = try #require(BrowserTabs.callTab(in: windows))
        #expect(tab.service == .zoom && tab.recording == nil && tab.page == "Zoom Meeting Matvey Litvin")
    }

    /// Two tabs recording: the one the call is in stays it, whichever is in front.
    @Test func ofTwoRecordingTabsTheCallFollowedStays() throws {
        let windows = [BrowserTabs.Window(title: "x", tabs: [
            .init(title: "Meet – abc-defg-hij - Microphone recording", selected: false),
            .init(title: "Zoom Meeting - Microphone recording", selected: true),
        ])]
        #expect(try #require(BrowserTabs.callTab(in: windows)).service == .zoom)
        let meet = BrowserTabs.key(service: .meet, page: "Meet – abc-defg-hij")
        #expect(try #require(BrowserTabs.callTab(in: windows, following: meet)).service == .meet)
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

    /// An extension or a Chrome profile may add its own to a title ("[Main] 🏠" after Slack's): the service is still
    /// found by the part of the title that names it. A name inside a sentence or a longer word isn't one.
    @Test func theServiceFromATitleSomethingDecorated() {
        let titles: [(String, CallService?)] = [
            ("general (Channel) - V-Soft - Slack [Main] 🏠", .slack),
            ("Jira (DM) - V-Soft - Slack [Main] 🏠", .slack),
            ("Huddles - V-Soft - Slack", .slack),
            ("[Work] Slack | general", .slack),
            ("• Discord | #основной | Сервер package.json [Work]", .discord),
            ("Meet – abc-defg-hij 🎧", .meet),
            ("🎧 Google Meet", .meet),
            ("Zoom Meeting (2) ✨", .zoom),
            ("Telegram Web [Personal]", .telegram),
            ("Slacker news", nil),
            ("Why we slack off on Fridays - Blog", nil),
            ("Slack outage - Inbox - Gmail", nil),
            ("Meet the team - Acme", nil),
            ("Discordant notes | Music", nil),
        ]
        for (title, service) in titles {
            #expect(CallService.of(pageTitle: title) == service, "\(title)")
        }
        #expect(BrowserTabs.components(of: "(1) general (Channel) - V-Soft - Slack [Main] 🏠")
            == ["general", "v-soft", "slack"])
        #expect(BrowserTabs.components(of: "• Discord | #основной | Сервер package.json [Work]")
            == ["discord", "основной", "сервер package.json"])
        // Chrome's own marks still come off first, then the page is matched.
        let parsed = BrowserTabs.parse("Jira (DM) - V-Soft - Slack [Main] 🏠 - Microphone recording")
        #expect(parsed == .init(page: "Jira (DM) - V-Soft - Slack [Main] 🏠", recording: .mic))
        #expect(CallService.of(pageTitle: parsed.page) == .slack)
        // Meet's meeting is its code, whatever is around it.
        #expect(BrowserTabs.key(service: .meet, page: "Meet – abc-defg-hij 🎧") == "meet: abc-defg-hij")
        #expect(BrowserTabs.key(service: .meet, page: "Meet – abc-defg-hij") == "meet: abc-defg-hij")
        #expect(BrowserTabs.key(service: .meet, page: "Google Meet") == "meet: google meet")
        #expect(BrowserTabs.key(service: .slack, page: "Jira (DM) - V-Soft - Slack [Main] 🏠") == "slack")
    }

    /// The call tab says whether another tab records the mic beside it.
    @Test func theCallTabSaysWhetherAnotherRecordsTheMic() throws {
        let two = [BrowserTabs.Window(title: "x", tabs: [
            .init(title: "Some call - Microphone recording", selected: true),
            .init(title: "Another call - Microphone recording", selected: false),
            .init(title: "Photo booth - Camera recording", selected: false),
        ])]
        #expect(try #require(BrowserTabs.callTab(in: two)).othersRecordMic)
        let one = [BrowserTabs.Window(title: "x", tabs: [
            .init(title: "Some call - Microphone recording", selected: true),
            .init(title: "Photo booth - Camera recording", selected: false),
        ])]
        #expect(try #require(BrowserTabs.callTab(in: one)).othersRecordMic == false)
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

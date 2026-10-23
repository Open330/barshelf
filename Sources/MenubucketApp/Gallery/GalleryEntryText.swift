import Foundation
import MenubucketCore

// The registry is one English file shared by every BarShelf, so its names,
// descriptions and categories cannot follow the user's language. For the
// project's own entries the app carries the words itself: a plain summary
// (translated through the string catalog) and search keywords in English and
// Korean, so "날씨" finds Weather whatever language the app runs in.
//
// Matched on id *and* install URL: a third-party registry that reuses one of
// these ids for something else keeps its own description.

enum GalleryEntryText {
    /// The summary cards and the detail page lead with.
    static func description(for entry: RegistryWidgetEntry) -> String? {
        if isOfficial(entry), let summary = summary(forID: entry.id) { return summary }
        return entry.description
    }

    /// The name cards, the detail page and search show. The project's own
    /// entries use the name their widget.json gives the shelf in the app's
    /// language, so the gallery and the installed card agree; anything else
    /// keeps the registry's name.
    static func title(for entry: RegistryWidgetEntry, language: String = WidgetLocalization.appLanguage) -> String {
        guard isOfficial(entry), let names = official[entry.id]?.names, !names.isEmpty else { return entry.name }
        let tables = names.mapValues { [entry.name: $0] }
        return WidgetLocalizations(tables).localization(for: language)?.text(entry.name) ?? entry.name
    }

    /// Words every entry answers to: each one is a widget, so "날씨 위젯" or
    /// "weather widget" still requires the other word to match.
    static let genericTerms = ["widget", "위젯"]

    /// A registry category in the user's language; unknown ones as written.
    static func categoryLabel(_ category: String) -> String {
        switch category.trimmingCharacters(in: .whitespaces).lowercased() {
        case "demo", "everyday": return String(localized: "Everyday", comment: "Gallery category for clock, calendar, weather and similar widgets")
        case "developer": return String(localized: "Developer", comment: "Gallery category")
        case "system": return String(localized: "System", comment: "Gallery category")
        case "productivity": return String(localized: "Productivity", comment: "Gallery category")
        case "files": return String(localized: "Files", comment: "Gallery category")
        case "media": return String(localized: "Media", comment: "Gallery category")
        case "security": return String(localized: "Security", comment: "Gallery category")
        default: return category
        }
    }

    /// Extra words search matches besides the registry's own fields.
    static func searchTerms(for entry: RegistryWidgetEntry) -> [String] {
        var terms = genericTerms
        if let category = entry.category { terms.append(categoryLabel(category)) }
        if isOfficial(entry), let official = official[entry.id] {
            if let summary = summary(forID: entry.id) { terms.append(summary) }
            // Every language's name, so the shelf's name finds the entry in
            // any app language.
            terms.append(contentsOf: official.names.values.sorted())
            terms.append(contentsOf: official.keywords)
        }
        return terms
    }

    static func isOfficial(_ entry: RegistryWidgetEntry) -> Bool {
        official[entry.id]?.installURL == entry.install.url
    }

    // MARK: - The project's entries

    private struct Official {
        let installURL: String
        /// English and Korean, not localized: either should find the widget
        /// in any app language.
        let keywords: [String]
        /// Language → name, the same as the widget.json `localizations`
        /// entry for its English name (a test keeps the two in step).
        var names: [String: String] = [:]
    }

    private static let repo = "https://github.com/Open330/barshelf/tree/main/widgets/"

    private static let official: [String: Official] = [
        "dev.barshelf.today": Official(installURL: repo + "today", keywords: ["date", "day", "오늘", "날짜", "요일", "달력"], names: ["ko": "오늘"]),
        "dev.barshelf.recent-files-grid": Official(installURL: "https://github.com/jiunbae/stashbar", keywords: ["downloads", "thumbnails", "최근 파일", "파일", "다운로드", "썸네일"], names: ["ko": "최근 파일"]),
        "dev.menubucket.stashbar-recent-files": Official(installURL: "https://github.com/jiunbae/stashbar", keywords: ["recent", "folder", "최근 파일", "파일", "폴더", "썸네일"]),
        "dev.barshelf.battery-meter": Official(installURL: repo + "battery-meter", keywords: ["battery", "charge", "power", "배터리", "충전", "전원"], names: ["ko": "배터리"]),
        "dev.barshelf.aas-usage": Official(installURL: "https://github.com/Open330/aas/tree/main/widgets/barshelf-aas-usage", keywords: ["usage", "quota", "claude", "codex", "사용량", "한도"]),
        "dev.barshelf.muxa-watch": Official(installURL: "https://github.com/Open330/muxa/tree/main/widgets/muxa-watch", keywords: ["agents", "monitor", "에이전트", "모니터링"]),
        "dev.barshelf.otpeek": Official(installURL: "https://github.com/jiunbae/otpeek/tree/main/widgets/otpeek", keywords: ["otp", "2fa", "one-time code", "authenticator", "인증", "인증 코드", "일회용 비밀번호", "보안"]),
        "dev.barshelf.codex-reset": Official(installURL: repo + "codex-reset", keywords: ["codex", "quota", "reset", "한도", "초기화"], names: ["ko": "Codex 초기화"]),
        "dev.barshelf.downloads-new": Official(installURL: repo + "downloads-new", keywords: ["downloads", "new files", "다운로드", "새 파일", "파일"], names: ["ko": "다운로드"]),
        "dev.barshelf.github-status": Official(installURL: repo + "github-status", keywords: ["github", "outage", "status", "깃허브", "장애", "상태"], names: ["ko": "GitHub 상태"]),
        "dev.barshelf.clock": Official(installURL: repo + "clock", keywords: ["clock", "time", "시계", "시간"], names: ["ko": "시계"]),
        "dev.barshelf.system": Official(installURL: repo + "system", keywords: ["cpu", "memory", "ram", "disk", "시스템", "메모리", "디스크", "저장 공간"], names: ["ko": "시스템"]),
        "dev.barshelf.sensors": Official(installURL: repo + "sensors", keywords: ["temperature", "fan", "power", "센서", "온도", "팬", "전력"], names: ["ko": "센서"]),
        "dev.barshelf.weather": Official(installURL: repo + "weather", keywords: ["weather", "temperature", "forecast", "날씨", "기온", "온도", "일기예보"], names: ["ko": "날씨"]),
        "dev.barshelf.calendar": Official(installURL: repo + "calendar", keywords: ["calendar", "month", "달력", "캘린더", "월"], names: ["ko": "달력"]),
        "dev.barshelf.exchange": Official(installURL: repo + "exchange", keywords: ["exchange rate", "currency", "dollar", "won", "usd", "krw", "환율", "달러", "원화"], names: ["ko": "환율"]),
        "dev.barshelf.network": Official(installURL: repo + "network", keywords: ["network", "internet", "speed", "ip", "wi-fi", "네트워크", "인터넷", "속도", "와이파이"], names: ["ko": "네트워크"]),
        "dev.barshelf.stock": Official(installURL: repo + "stock", keywords: ["stock", "shares", "ticker", "주식", "주가", "증권"], names: ["ko": "주식"]),
        "dev.barshelf.now-playing": Official(installURL: repo + "now-playing", keywords: ["music", "song", "spotify", "음악", "노래", "재생 중"], names: ["ko": "지금 재생 중"]),
        "dev.barshelf.reminders": Official(installURL: repo + "reminders", keywords: ["reminders", "tasks", "to-do", "todo", "미리 알림", "할 일"], names: ["ko": "미리 알림"]),
        "dev.barshelf.next-meeting": Official(installURL: repo + "next-meeting", keywords: ["meeting", "calendar", "zoom", "meet", "회의", "일정", "미팅"], names: ["ko": "다음 회의"]),
        "dev.barshelf.quick-shelf": Official(installURL: repo + "quick-shelf", keywords: ["launcher", "apps", "favorites", "bookmarks", "앱", "즐겨찾기", "바로가기", "실행"], names: ["ko": "빠른 선반"]),
        "dev.barshelf.project-status": Official(installURL: repo + "project-status", keywords: ["git", "repository", "branch", "깃", "저장소", "브랜치", "프로젝트"], names: ["ko": "프로젝트 상태"]),
        "dev.barshelf.focus-timer": Official(installURL: repo + "focus-timer", keywords: ["timer", "pomodoro", "focus", "타이머", "뽀모도로", "집중"], names: ["ko": "집중 타이머"]),
        "dev.barshelf.clipboard-shelf": Official(installURL: repo + "clipboard-shelf", keywords: ["clipboard", "copy", "paste", "history", "클립보드", "복사", "붙여넣기", "기록"], names: ["ko": "클립보드 선반"]),
        "dev.barshelf.developer-inbox": Official(installURL: repo + "developer-inbox", keywords: ["github", "pull request", "review", "notifications", "깃허브", "리뷰", "알림"], names: ["ko": "개발자 받은편지함"]),
    ]

    /// One or two plain sentences per widget: what it shows, and anything it
    /// needs from the user. Literal keys, so the catalog picks them up.
    private static func summary(forID id: String) -> String? {
        switch id {
        case "dev.barshelf.today":
            return String(localized: "Today’s date with a large day number. Needs nothing else installed.")
        case "dev.barshelf.recent-files-grid":
            return String(localized: "Your latest downloads as thumbnails or a list. Click to open, or drag a file into another app.")
        case "dev.menubucket.stashbar-recent-files":
            return String(localized: "Recent files from a folder you choose, as a preview, a grid, or a searchable list. Drag files straight into other apps.")
        case "dev.barshelf.battery-meter":
            return String(localized: "Your battery level as a large percentage and a colored meter.")
        case "dev.barshelf.aas-usage":
            return String(localized: "How much of each AI account’s usage is left and when it resets. Needs the aas command-line tool.")
        case "dev.barshelf.muxa-watch":
            return String(localized: "What each muxa coding agent is doing, on this Mac or over SSH. Needs the muxa command-line tool and Deno.")
        case "dev.barshelf.otpeek":
            return String(localized: "One-time sign-in codes with a countdown and one-click copy. Needs the otpeek command-line tool and a set-up vault.")
        case "dev.barshelf.codex-reset":
            return String(localized: "An unofficial forecast of whether the Codex quota resets in the next 48 hours, as a 0–100 score.")
        case "dev.barshelf.downloads-new":
            return String(localized: "How many files a folder has, and how many were added or removed since you last looked.")
        case "dev.barshelf.github-status":
            return String(localized: "Whether GitHub is working normally, from its public status page.")
        case "dev.barshelf.clock":
            return String(localized: "A large digital clock with seconds and the date.")
        case "dev.barshelf.system":
            return String(localized: "CPU, memory and disk use as colored meters. Can show a reading in the menu bar.")
        case "dev.barshelf.sensors":
            return String(localized: "Temperatures, fan speeds and power use. Can show a reading in the menu bar.")
        case "dev.barshelf.weather":
            return String(localized: "The current temperature and conditions for a place you choose. No account needed.")
        case "dev.barshelf.calendar":
            return String(localized: "This month’s calendar with today highlighted.")
        case "dev.barshelf.exchange":
            return String(localized: "The current US dollar to Korean won exchange rate.")
        case "dev.barshelf.network":
            return String(localized: "Upload and download activity, live speeds, and this Mac’s local address.")
        case "dev.barshelf.stock":
            return String(localized: "A live stock price and today’s change for any ticker symbol.")
        case "dev.barshelf.now-playing":
            return String(localized: "The song playing in Music or Spotify. macOS asks once whether BarShelf may read it.")
        case "dev.barshelf.reminders":
            return String(localized: "How many reminders you still have to do. macOS asks once whether BarShelf may read Reminders.")
        case "dev.barshelf.next-meeting":
            return String(localized: "Your next calendar event, how long until it starts, and a Join button for video calls. Needs Deno.")
        case "dev.barshelf.quick-shelf":
            return String(localized: "Open the apps, folders and websites you use most. Needs no permissions.")
        case "dev.barshelf.project-status":
            return String(localized: "A Git project at a glance: branch, uncommitted changes and latest commit. Needs Deno.")
        case "dev.barshelf.focus-timer":
            return String(localized: "A focus countdown you can start, pause and reset, with a notification when it ends. Needs Deno.")
        case "dev.barshelf.clipboard-shelf":
            return String(localized: "A searchable history of what you copied, kept only in memory and hiding secrets. Needs Deno.")
        case "dev.barshelf.developer-inbox":
            return String(localized: "GitHub review requests and unread notifications in one list. Needs the gh command-line tool and Deno.")
        default:
            return nil
        }
    }
}

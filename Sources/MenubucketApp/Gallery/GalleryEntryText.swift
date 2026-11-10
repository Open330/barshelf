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
        "dev.barshelf.aas-alerts": Official(installURL: "https://github.com/Open330/aas/tree/main/widgets/barshelf-aas-alerts", keywords: ["alerts", "notifications", "usage", "quota", "claude", "codex", "알림", "사용량", "한도"]),
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
        "dev.barshelf.keep-awake": Official(installURL: repo + "keep-awake", keywords: ["keep awake", "sleep", "caffeinate", "amphetamine", "power", "깨어 있기", "잠자기", "절전", "전원"], names: ["ko": "깨어 있기"]),
        "dev.barshelf.reminders": Official(installURL: repo + "reminders", keywords: ["reminders", "tasks", "to-do", "todo", "미리 알림", "할 일"], names: ["ko": "미리 알림"]),
        "dev.barshelf.next-meeting": Official(installURL: repo + "next-meeting", keywords: ["meeting", "calendar", "zoom", "meet", "회의", "일정", "미팅"], names: ["ko": "다음 회의"]),
        "dev.barshelf.quick-shelf": Official(installURL: repo + "quick-shelf", keywords: ["launcher", "apps", "favorites", "bookmarks", "앱", "즐겨찾기", "바로가기", "실행"], names: ["ko": "빠른 선반"]),
        "dev.barshelf.project-status": Official(installURL: repo + "project-status", keywords: ["git", "repository", "branch", "깃", "저장소", "브랜치", "프로젝트"], names: ["ko": "프로젝트 상태"]),
        "dev.barshelf.focus-timer": Official(installURL: repo + "focus-timer", keywords: ["timer", "pomodoro", "focus", "타이머", "뽀모도로", "집중"], names: ["ko": "집중 타이머"]),
        "dev.barshelf.clipboard-shelf": Official(installURL: repo + "clipboard-shelf", keywords: ["clipboard", "copy", "paste", "history", "클립보드", "복사", "붙여넣기", "기록"], names: ["ko": "클립보드 선반"]),
        "dev.barshelf.developer-inbox": Official(installURL: repo + "developer-inbox", keywords: ["github", "pull request", "review", "notifications", "깃허브", "리뷰", "알림"], names: ["ko": "개발자 받은편지함"]),
        "dev.barshelf.bluetooth-battery": Official(installURL: repo + "bluetooth-battery", keywords: ["bluetooth", "airpods", "mouse", "keyboard", "블루투스", "에어팟", "배터리", "마우스"], names: ["ko": "블루투스 배터리"]),
        "dev.barshelf.listening-ports": Official(installURL: repo + "listening-ports", keywords: ["ports", "lsof", "localhost", "server", "포트", "리스닝", "로컬호스트", "서버"], names: ["ko": "열린 포트"]),
        "dev.barshelf.internet-quality": Official(installURL: repo + "internet-quality", keywords: ["speed test", "internet", "bandwidth", "latency", "속도 측정", "인터넷", "대역폭", "응답성"], names: ["ko": "인터넷 품질"]),
        "dev.barshelf.homebrew-updates": Official(installURL: repo + "homebrew-updates", keywords: ["homebrew", "brew", "updates", "outdated", "홈브루", "업데이트", "패키지", "캐스크"], names: ["ko": "Homebrew 업데이트"]),
        "dev.barshelf.quick-note": Official(installURL: repo + "quick-note", keywords: ["note", "memo", "sticky", "reminder", "메모", "노트", "포스트잇", "리마인더"], names: ["ko": "빠른 메모"]),
        "dev.barshelf.github-actions": Official(installURL: repo + "github-actions", keywords: ["github", "actions", "ci", "build", "workflow", "빌드", "깃허브", "액션"], names: ["ko": "GitHub Actions 빌드"]),
        "dev.barshelf.site-monitor": Official(installURL: repo + "site-monitor", keywords: ["uptime", "monitor", "ping", "latency", "website", "업타임", "사이트", "응답 시간"], names: ["ko": "사이트 모니터"]),
        "dev.barshelf.docker": Official(installURL: repo + "docker", keywords: ["docker", "containers", "orbstack", "compose", "도커", "컨테이너"], names: ["ko": "Docker 컨테이너"]),
        "dev.barshelf.tailscale": Official(installURL: repo + "tailscale", keywords: ["tailscale", "vpn", "tailnet", "network", "exit node", "테일스케일", "네트워크", "기기"], names: ["ko": "Tailscale 네트워크"]),
        "dev.barshelf.kubernetes": Official(installURL: repo + "kubernetes", keywords: ["kubernetes", "k8s", "kubectl", "pods", "cluster", "쿠버네티스", "파드", "클러스터"], names: ["ko": "Kubernetes 파드"]),
        "dev.barshelf.bitwarden": Official(installURL: repo + "bitwarden", keywords: ["bitwarden", "password", "vault", "sync", "비트워든", "비밀번호", "보관함"], names: ["ko": "Bitwarden 보관함"]),
        "dev.barshelf.world-clock": Official(installURL: repo + "world-clock", keywords: ["world clock", "time zone", "timezone", "cities", "세계 시계", "시간대", "시차"], names: ["ko": "세계 시계"]),
        "dev.barshelf.countdown": Official(installURL: repo + "countdown", keywords: ["countdown", "d-day", "days left", "anniversary", "디데이", "카운트다운", "기념일", "남은 날"], names: ["ko": "디데이"]),
        "dev.barshelf.air-quality": Official(installURL: repo + "air-quality", keywords: ["air quality", "pm2.5", "fine dust", "aqi", "미세먼지", "초미세먼지", "대기질", "공기"], names: ["ko": "미세먼지"]),
        "dev.barshelf.crypto": Official(installURL: repo + "crypto", keywords: ["crypto", "bitcoin", "ethereum", "coin price", "암호화폐", "비트코인", "코인", "시세"], names: ["ko": "암호화폐"]),
        "dev.barshelf.hacker-news": Official(installURL: repo + "hacker-news", keywords: ["hacker news", "hn", "tech news", "ycombinator", "해커 뉴스", "해커뉴스", "기술 뉴스", "뉴스"], names: ["ko": "해커 뉴스"]),
        "dev.barshelf.break-reminder": Official(installURL: repo + "break-reminder", keywords: ["break", "stand up", "eye rest", "reminder", "휴식", "스트레칭", "눈 휴식", "알림"], names: ["ko": "휴식 알림"]),
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
        case "dev.barshelf.keep-awake":
            return String(localized: "Keep the Mac awake for a few hours, never indefinitely, and see what else is keeping it awake. Needs PowerDisplayGuard.")
        case "dev.barshelf.battery-meter":
            return String(localized: "Your battery level as a large percentage and a colored meter.")
        case "dev.barshelf.aas-usage":
            return String(localized: "How much of each AI account’s usage is left and when it resets. Needs the aas command-line tool.")
        case "dev.barshelf.aas-alerts":
            return String(localized: "A notification when an AI account runs low, and another when its limits reset. Needs the aas command-line tool.")
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
        case "dev.barshelf.bluetooth-battery":
            return String(localized: "Shows the battery level of each connected Bluetooth device, including AirPods earbuds and case, and alerts you when one drops low. Uses only built-in macOS tools.")
        case "dev.barshelf.listening-ports":
            return String(localized: "Lists the TCP ports your processes are listening on, with the process name, pid and whether each is reachable from the network. Uses the built-in lsof.")
        case "dev.barshelf.internet-quality":
            return String(localized: "Watches latency and packet loss with a light ping every few minutes, and runs a short speed test once a day or when you ask. Notifies when the connection drops. Uses built-in macOS tools.")
        case "dev.barshelf.homebrew-updates":
            return String(localized: "Shows which Homebrew formulae and casks have updates, with installed and current versions. Requires Homebrew.")
        case "dev.barshelf.quick-note":
            return String(localized: "Keeps a short note on your shelf, and in the menu bar if you like. Write it in the widget’s settings; it needs no permissions.")
        case "dev.barshelf.github-actions":
            return String(localized: "Shows the latest GitHub Actions runs for a repository and alerts you when the watched branch’s build fails or recovers. Needs the GitHub CLI (gh), signed in.")
        case "dev.barshelf.site-monitor":
            return String(localized: "Checks a website every minute and shows whether it is up and how fast it answered, with alerts when it goes down or comes back. Uses the built-in curl; nothing to install.")
        case "dev.barshelf.docker":
            return String(localized: "Lists your Docker containers with image, status and ports, and can show how many are running in the menu bar. Needs Docker Desktop, OrbStack or another Docker CLI.")
        case "dev.barshelf.tailscale":
            return String(localized: "Shows whether Tailscale is connected, which exit node you use, and which devices in your tailnet are online. Needs the Tailscale app or the tailscale CLI.")
        case "dev.barshelf.kubernetes":
            return String(localized: "Shows your current kubectl context and how the pods in a namespace are doing, listing any that aren’t ready. Needs kubectl with access to a cluster.")
        case "dev.barshelf.bitwarden":
            return String(localized: "Unlock your Bitwarden vault from the card, search it, and copy a username, password or code that clears itself after 30 seconds. Locks on its own when unused. Needs the Bitwarden CLI (bw).")
        case "dev.barshelf.world-clock":
            return String(localized: "Shows the local time in up to five cities, with Today/Tomorrow, the hour difference, and dimmed rows outside working hours or on weekends. Runs the system date command, no network.")
        case "dev.barshelf.countdown":
            return String(localized: "Counts down to one or two dates and shows D-12, D-day or D+3 with the days left; the menu bar shows the D-label. Can notify you on the day.")
        case "dev.barshelf.air-quality":
            return String(localized: "Shows PM2.5 and PM10 with Korean-standard grades plus US and EU AQI for a place you set, and notifies when PM2.5 reaches your alert level. From Open-Meteo, no key.")
        case "dev.barshelf.crypto":
            return String(localized: "Shows the price and 24-hour change of the coins you list, with one coin in the menu bar. From CoinGecko’s public API every 10 minutes, no key needed.")
        case "dev.barshelf.hacker-news":
            return String(localized: "Lists the Hacker News front page with points, comments and age; click a story to open it or the bubble for its comments. From the public Algolia HN API, no key.")
        case "dev.barshelf.break-reminder":
            return String(localized: "Reminds you every 50 minutes (adjustable) to stand up and rest your eyes, and shows the time until the next break. Has Took a break, Snooze and Pause; needs Deno.")
        default:
            return nil
        }
    }
}

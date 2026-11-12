// Bundled script widgets show their fixed text in the app's language
// (`ctx.locale`): Korean for `ko`, otherwise the English exactly as before.
// What they run, store and send back as actions is the same in both.
import {
  context,
  fireTimer,
  host,
  JsonRpcError,
  ProtocolErrorCode,
  sendAction,
  strings,
} from "barshelf";
import focusTimer from "../../widgets/focus-timer/index.ts";
import developerInbox from "../../widgets/developer-inbox/index.ts";
import battery from "../../widgets/battery/index.ts";
import projectStatus from "../../widgets/project-status/index.ts";
import clipboardShelf from "../../widgets/clipboard-shelf/index.ts";
import nextMeeting from "../../widgets/next-meeting/index.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message = ""): void {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${message} expected ${JSON.stringify(expected)}, got ${
      JSON.stringify(actual)
    }`,
  );
}

function shows(text: string): void {
  const shown = strings(host.lastRender);
  assert(shown.includes(text), `"${text}" not in ${JSON.stringify(shown)}`);
}

function hides(text: string): void {
  const shown = strings(host.lastRender);
  assert(
    !shown.includes(text),
    `"${text}" should not be in ${JSON.stringify(shown)}`,
  );
}

/** Event ids and icons a render sends back: never translated. */
function actionIds(): string[] {
  const ids: string[] = [];
  const walk = (value: unknown) => {
    if (Array.isArray(value)) return value.forEach(walk);
    if (value === null || typeof value !== "object") return;
    const record = value as Record<string, unknown>;
    const action = record.action as Record<string, unknown> | undefined;
    if (action?.type === "event") {
      ids.push(String(action.id ?? action.actionId ?? action.name));
    }
    Object.values(record).forEach(walk);
  };
  walk(host.lastRender.root);
  return ids;
}

const NOW = Date.UTC(2026, 9, 24, 1, 0, 0);

function load(locale: string, settings: Record<string, unknown> = {}) {
  return context({
    widgetId: "test",
    reason: "open" as const,
    now: NOW,
    locale,
    appearance: "light" as const,
    settings,
  });
}

// MARK: Focus Timer

Deno.test("Focus Timer reads in Korean through a session, notification included", async () => {
  host.reset();
  const handlers = focusTimer.handlers;
  await handlers.load!(load("ko-KR"));
  shows("준비");
  shows("시작");
  shows("재설정");
  shows("25분 세션");
  shows("완료 0회");
  hides("Ready");
  assertEquals(host.lastRender.options.status?.tooltip, "집중 타이머 · 준비");
  const idleIds = actionIds();

  // An action carries no locale: it speaks the language of the last load.
  await sendAction(handlers, "start", NOW);
  shows("집중 중");
  shows("일시 정지");
  assert(
    strings(host.lastRender).some((text) => text.endsWith("에 끝남")),
    "no Korean end time",
  );

  await fireTimer(handlers, "focus-deadline", NOW + 26 * 60_000);
  shows("완료");
  shows("다시 시작");
  shows("집중 세션을 마쳤습니다. 한 번 더 할까요?");
  assertEquals(host.notifications.at(-1)?.title, "집중 세션 완료");

  // The stored state is language-free.
  const stored = host.storage.get("focus-state-v1") as { status: string };
  assertEquals(stored.status, "completed");
  assertEquals(idleIds, ["start", "reset"], "event ids");
});

Deno.test("Focus Timer keeps its English for English and unknown languages", async () => {
  for (const locale of ["en-US", "en", "fr-FR", ""]) {
    host.reset();
    await focusTimer.handlers.load!(load(locale));
    shows("Ready");
    shows("Start");
    shows("Reset");
    shows("25 minute session");
    shows("0 completed");
    hides("The countdown ring updates live while the popup is open.");
    assertEquals(
      host.lastRender.options.status?.tooltip,
      "Focus Timer · Ready",
      locale,
    );
    assertEquals(actionIds(), ["start", "reset"], "event ids");
  }
  await sendAction(focusTimer.handlers, "start", NOW);
  await fireTimer(focusTimer.handlers, "focus-deadline", NOW + 26 * 60_000);
  assertEquals(host.notifications.at(-1)?.title, "Focus session complete");
});

// MARK: Developer Inbox

function ghAnswers(prs = "[]", notifications = "[]") {
  host.exec = ({ command, args }) => {
    if (command !== "gh") throw new Error("gh is found by the host's discover");
    if (args?.[0] === "search") return { stdout: prs };
    if (args?.[0] === "api") return { stdout: notifications };
    return { stdout: "" };
  };
}

Deno.test("an empty Developer Inbox says so in Korean, running the same gh commands", async () => {
  host.reset();
  ghAnswers();
  await developerInbox.handlers.load!(load("ko"));
  shows("모두 확인함");
  shows("열린 리뷰 요청도, 읽지 않은 알림도 없습니다.");
  shows("리뷰 요청");
  shows("읽지 않음");
  hides("Inbox zero");
  assertEquals(host.lastRender.options.status?.tooltip, "개발자 받은편지함");
  const korean = host.execCalls;

  host.reset();
  ghAnswers();
  await developerInbox.handlers.load!(load("en-US"));
  shows("Inbox zero");
  shows("No open review requests or unread notifications.");
  shows("Review requests");
  shows("Unread");
  assertEquals(host.lastRender.options.status?.tooltip, "Developer Inbox");
  assertEquals(host.execCalls, korean, "commands");
});

Deno.test("Developer Inbox rows translate their labels, never the GitHub data", async () => {
  host.reset();
  ghAnswers(
    JSON.stringify([{
      number: 7,
      title: "Fix the thing",
      url: "https://github.com/o/r/pull/7",
      repository: { nameWithOwner: "o/r" },
      author: { login: "octo" },
      isDraft: false,
      updatedAt: new Date(NOW - 5 * 60_000).toISOString(),
    }]),
    JSON.stringify([{
      id: "1",
      reason: "mention",
      repository: { full_name: "o/r" },
      subject: {
        title: "Hello there",
        type: "Issue",
        url: "https://api.github.com/repos/o/r/issues/3",
      },
      updated_at: new Date(NOW - 3 * 3_600_000).toISOString(),
    }, {
      id: "2",
      reason: "some_new_reason",
      repository: { full_name: "o/r" },
      subject: { title: "Other", type: "Issue" },
      updated_at: new Date(NOW).toISOString(),
    }]),
  );
  await developerInbox.handlers.load!(load("ko-KR"));
  for (
    const text of [
      "리뷰 요청됨",
      "알림",
      "리뷰",
      "열기",
      "멘션",
      "5분 전 · octo 작성",
      "3시간 전",
    ]
  ) shows(text);
  for (
    const data of [
      "Fix the thing",
      "Hello there",
      "o/r",
      "#7",
      "some_new_reason",
    ]
  ) shows(data);
  shows("https://github.com/o/r/pull/7");
  shows("https://github.com/o/r/issues/3");
  hides("mention");

  host.reset();
  ghAnswers(
    "[]",
    JSON.stringify([{
      id: "1",
      reason: "mention",
      repository: { full_name: "o/r" },
      subject: { title: "Hello there", type: "Issue" },
      updated_at: new Date(NOW).toISOString(),
    }]),
  );
  await developerInbox.handlers.load!(load("en"));
  shows("mention");
  shows("0m ago");
});

Deno.test("Developer Inbox explains a missing gh in either language", async () => {
  const missing = () => {
    throw new JsonRpcError({ code: ProtocolErrorCode.ExecNotFound, message: "gh not found" });
  };
  host.reset();
  host.exec = missing;
  await developerInbox.handlers.load!(load("ko"));
  shows("GitHub CLI를 찾을 수 없습니다");
  shows("https://cli.github.com");
  host.reset();
  host.exec = missing;
  await developerInbox.handlers.load!(load("en"));
  shows("GitHub CLI not found");
  shows("Get GitHub CLI");
  assertEquals(host.lastRender.options.status?.label, "—");
});

Deno.test("Developer Inbox tells signed-out from offline instead of showing zero", async () => {
  host.reset();
  host.exec = () => ({
    stdout: "",
    exitCode: 4,
    stderr: "To get started with GitHub CLI, please run:  gh auth login\nAlternatively, populate the GH_TOKEN environment variable",
  });
  await developerInbox.handlers.load!(load("en"));
  shows("GitHub sign-in required");
  shows("gh auth login");
  hides("Inbox zero");
  hides("You’re offline");

  host.reset();
  host.exec = () => ({
    stdout: "",
    exitCode: 1,
    stderr: "error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com",
  });
  await developerInbox.handlers.load!(load("ko"));
  shows("오프라인 상태");
  hides("GitHub 로그인 필요");
  hides("모두 확인함");
  assertEquals(host.lastRender.options.status?.label, "—");
});

Deno.test("a notification without a web URL still opens GitHub's list", async () => {
  host.reset();
  ghAnswers("[]", JSON.stringify([{
    id: "9",
    reason: "subscribed",
    repository: { full_name: "o/r" },
    subject: { title: "v1.0", type: "Release", url: "https://api.github.com/repos/o/r/releases/1" },
    updated_at: new Date(NOW).toISOString(),
  }]));
  await developerInbox.handlers.load!(load("en"));
  shows("https://github.com/notifications");
  assertEquals(host.lastRender.options.status?.label, "1");
});

Deno.test("new review requests notify only when asked, after a baseline", async () => {
  const pr = (number: number) => ({
    number,
    title: `PR ${number}`,
    url: `https://github.com/o/r/pull/${number}`,
    repository: { nameWithOwner: "o/r" },
    author: { login: "octo" },
    isDraft: false,
    updatedAt: new Date(NOW).toISOString(),
  });
  host.reset();
  ghAnswers(JSON.stringify([pr(1)]));
  await developerInbox.handlers.load!(load("en"));
  assertEquals(host.notifications.length, 0, "off by default");
  assertEquals(host.storage.has("seen-review-requests"), false, "nothing kept while off");

  const on = { notifyReviewRequests: true };
  await developerInbox.handlers.load!(load("en", on));
  assertEquals(host.notifications.length, 0, "the first check is the baseline");
  ghAnswers(JSON.stringify([pr(1), pr(2)]));
  await developerInbox.handlers.load!(load("en", on));
  assertEquals(host.notifications.length, 1);
  assertEquals(host.notifications[0].title, "New review request");
  assertEquals(host.notifications[0].body, "o/r: PR 2");
  await developerInbox.handlers.load!(load("en", on));
  assertEquals(host.notifications.length, 1, "not again for the same PR");

  await developerInbox.handlers.load!(load("en"));
  assertEquals(host.storage.has("seen-review-requests"), false, "turning it off forgets");
});

// MARK: Project Status

Deno.test("Project Status asks for the Command Line Tools instead of calling the folder not a repo", async () => {
  const settings = { projectDirectory: "/Users/me/code/app" };
  host.reset();
  host.exec = () => ({
    stdout: "",
    exitCode: 1,
    stderr: "xcode-select: note: No developer tools were found, requesting install.",
  });
  await projectStatus.handlers.load!(load("en", settings));
  shows("Install Command Line Tools");
  shows("xcode-select --install");
  hides("Not a Git repository");
  assertEquals(host.lastRender.options.status?.label, "—");
  // An interval refresh does not run git (and macOS's install prompt) again.
  const calls = host.execCalls.length;
  await projectStatus.handlers.load!(load("en", settings));
  assertEquals(host.execCalls.length, calls, "git ran again without a request");
  shows("Install Command Line Tools");

  host.reset();
  host.exec = () => ({
    stdout: "",
    exitCode: 128,
    stderr: "fatal: not a git repository (or any of the parent directories): .git",
  });
  // Try Again is a manual refresh.
  await projectStatus.handlers.load!({ ...load("ko", settings), reason: "manual" as const });
  shows("Git 저장소가 아님");
  hides("Command Line Tools 설치");
});

Deno.test("Project Status says ahead/behind is as of the last fetch and keeps the menu bar short", async () => {
  host.reset();
  host.exec = ({ args }) => {
    if (args?.[2] === "status") {
      return {
        stdout: "# branch.oid 0123456789abcdef\n# branch.head feature/very-long-branch-name\n# branch.upstream origin/feature/very-long-branch-name\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 a b file.txt\n",
      };
    }
    if (args?.[2] === "log") return { stdout: "abc1234\x1fSubject\x1f1761000000" };
    return { stdout: "git@github.com:o/r.git" };
  };
  await projectStatus.handlers.load!(load("en", { projectDirectory: "/Users/me/code/app" }));
  shows("origin/feature/very-long-branch-name · as of the last fetch");
  const label = host.lastRender.options.status?.label ?? "";
  assert(label.length <= 14, `menu bar label too long: ${label}`);
  assertEquals(label, "feature/… • 1");
});

// MARK: Clipboard Shelf (a fake pbpaste: the real clipboard is never read)

Deno.test("Clipboard Shelf keeps collecting from its timer and keeps pins", async () => {
  host.reset();
  let clipboard = "first";
  host.exec = () => ({ stdout: clipboard });
  const handlers = clipboardShelf.handlers;
  await handlers.load!(load("en"));
  shows("first");
  shows("Collects every 5 s · secrets are skipped");

  // Copies made while the popup is closed arrive through the timer.
  const renders = host.renders.length;
  await fireTimer(handlers, "capture", NOW + 5_000);
  assertEquals(host.renders.length, renders, "an unchanged clipboard does not re-render");
  clipboard = "second";
  await fireTimer(handlers, "capture", NOW + 10_000);
  shows("second");
  shows("first");
  clipboard = "ghp_abcdefghijklmnopqrstuvwxyz0123456789";
  await fireTimer(handlers, "capture", NOW + 15_000);
  shows("A clipboard value that looked sensitive was not captured.");
  hides("ghp_abcdefghijklmnopqrstuvwxyz0123456789");

  const first = (host.storage.get("pins-v1") as unknown[] | undefined);
  assertEquals(first, undefined, "nothing stored before a pin");
  const pinId = JSON.stringify(host.lastRender.root).match(/"id":"(clip-[^"]+)"/)?.[1];
  await sendAction(handlers, "toggle-pin", NOW + 16_000, { id: pinId });
  const pins = host.storage.get("pins-v1") as { value: string }[];
  assertEquals(pins.length, 1);
  shows("1 pinned · pins are kept on this Mac");
});

// MARK: Battery, Next Meeting

const PMSET =
  "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%; charging; 1:02 remaining present: true\n";

Deno.test("Battery labels and pmset's words read in Korean; the English is unchanged", async () => {
  host.reset();
  host.exec = () => ({ stdout: PMSET });
  await battery.handlers.load!(load("ko"));
  for (
    const text of ["충전량", "전원", "상태", "전원 어댑터", "충전 중", "80%"]
  ) shows(text);
  assertEquals(host.lastRender.options.status?.tooltip, "배터리 80% · 충전 중");

  host.reset();
  host.exec = () => ({ stdout: PMSET });
  await battery.handlers.load!(load("en-US"));
  for (const text of ["Charge", "Source", "State", "AC Power", "Charging"]) {
    shows(text);
  }
  assertEquals(
    host.lastRender.options.status?.tooltip,
    "Battery 80% · Charging",
  );
});

Deno.test("Next Meeting counts down in Korean and keeps event data as it is", async () => {
  const meeting = {
    status: "ok",
    title: "Standup",
    calendar: "Work",
    location: "Room 1",
    startMs: NOW + 90 * 60_000,
    endMs: NOW + 120 * 60_000,
    meetingURL: "https://meet.example/x",
  };
  host.reset();
  host.exec = () => ({ stdout: "", json: meeting });
  await nextMeeting.handlers.load!(load("ko-KR"));
  for (
    const text of [
      "Standup",
      "Work · Room 1",
      "1시간 30분 후",
      "참가",
      "캘린더",
    ]
  ) shows(text);
  assertEquals(host.lastRender.options.status?.label, "1시간 30분 후");

  host.reset();
  host.exec = () => ({ stdout: "", json: meeting });
  await nextMeeting.handlers.load!(load("en-US"));
  for (const text of ["In 1 hr 30 min", "Join", "Calendar"]) shows(text);

  host.reset();
  host.exec = () => ({ stdout: "", json: { status: "empty" } });
  await nextMeeting.handlers.load!(load("ko"));
  shows("다가오는 일정 없음");
  shows("앞으로 7일 동안 일정이 없습니다.");
  assertEquals(host.lastRender.options.status?.label, "일정 없음");
});

Deno.test("Next Meeting keeps a meeting in progress, Join included, until it ends", async () => {
  const running = {
    status: "ok",
    title: "Standup",
    calendar: "Work",
    startMs: NOW - 10 * 60_000,
    endMs: NOW + 20 * 60_000,
    meetingURL: "https://meet.example/x",
  };
  host.reset();
  host.exec = () => ({ stdout: "", json: running });
  await nextMeeting.handlers.load!(load("en-US"));
  shows("Join");
  const badge = strings(host.lastRender).find((text) =>
    text.startsWith("Now · ends ")
  );
  assert(
    badge,
    `no "Now · ends" badge in ${JSON.stringify(strings(host.lastRender))}`,
  );
  assertEquals(host.lastRender.options.status?.label, "Now");

  host.reset();
  host.exec = () => ({ stdout: "", json: running });
  await nextMeeting.handlers.load!(load("ko"));
  assert(
    strings(host.lastRender).some((text) => text.startsWith("진행 중 · ")),
    JSON.stringify(strings(host.lastRender)),
  );
  assertEquals(host.lastRender.options.status?.label, "진행 중");
});

Deno.test("Next Meeting's menu bar label stays within 14 characters", async () => {
  for (const minutes of [5, 59, 61, 125, 23 * 60 + 59, 3 * 24 * 60]) {
    for (const locale of ["en-US", "ko"]) {
      host.reset();
      host.exec = () => ({
        stdout: "",
        json: {
          status: "ok",
          title: "X",
          startMs: NOW + minutes * 60_000,
          endMs: NOW + (minutes + 30) * 60_000,
        },
      });
      await nextMeeting.handlers.load!(load(locale));
      const label = host.lastRender.options.status?.label ?? "";
      assert(
        label.length > 0 && label.length <= 14,
        `${locale} ${minutes}: "${label}"`,
      );
    }
  }
});

Deno.test("Next Meeting sends only an Automation denial to Privacy settings", async () => {
  host.reset();
  host.exec = () => {
    throw new Error(
      "execution error: Not authorized to send Apple events to Calendar. (-1743)",
    );
  };
  await nextMeeting.handlers.load!(load("en-US"));
  shows("Open Automation Settings");

  host.reset();
  host.exec = () => {
    throw new Error("timed out after 15000 ms");
  };
  await nextMeeting.handlers.load!(load("en-US"));
  hides("Open Automation Settings");
  shows("Calendar took too long to answer. Open it once, then try again.");
});

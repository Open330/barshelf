// Bundled script widgets show their fixed text in the app's language
// (`ctx.locale`): Korean for `ko`, otherwise the English exactly as before.
// What they run, store and send back as actions is the same in both.
import { context, fireTimer, host, sendAction, strings } from "barshelf";
import focusTimer from "../../widgets/focus-timer/index.ts";
import developerInbox from "../../widgets/developer-inbox/index.ts";
import battery from "../../widgets/battery/index.ts";
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
    shows("The countdown ring updates live while the popup is open.");
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
    if (command !== "/opt/homebrew/bin/gh") {
      throw new Error("not installed here");
    }
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
      "octo 작성 · 5분 전",
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
  host.reset();
  await developerInbox.handlers.load!(load("ko"));
  shows("GitHub CLI를 찾을 수 없습니다");
  host.reset();
  await developerInbox.handlers.load!(load("en"));
  shows("GitHub CLI not found");
  shows("Install gh with Homebrew, then reopen this widget.");
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

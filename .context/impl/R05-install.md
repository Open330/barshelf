# R05 Track B — URL 위젯 설치 (구현 노트)

구현 계약: R05-tasks.md "공통 계약 — URL 설치 v1" 전부. 테스트 93/93 통과 (기존 69 + 신규 24).

## 신규/수정 파일

### MenubucketCore (신규 3파일 — 파싱·추출·탐색, 전부 단위 테스트됨)
- `Sources/MenubucketCore/WidgetInstallSource.swift`
  - `WidgetInstallSource.parse(_:)` — 3종 입력 파싱:
    - GitHub: `https://github.com/{u}/{r}`(`.git`/trailing slash 허용), `/tree/{branch}[/{subdir}]`
      → codeload 후보 URL 생성. branch 미지정 시 `main` → `master` 순 후보 2개.
    - 아카이브: path 확장자 `.zip`/`.mbw`(대소문자 무관, 쿼리스트링 보존). GitHub release asset URL도 이 경로.
    - 딥링크: `menubucket://install?url=<encoded>` → 내부 URL 재귀 파싱(중첩 딥링크 거부).
  - owner/repo 문자 검증, 그 외 입력은 `WidgetInstallSourceError`로 거부(ftp/file 스킴 포함).
- `Sources/MenubucketCore/SafeZipExtractor.swift`
  - **인프로세스 zip 리더** (central directory + stored/deflate, Compression framework `COMPRESSION_ZLIB` = raw DEFLATE). `unzip`/`ditto` 쉘아웃 대신 자체 구현 → 보안 정책을 파일시스템 도달 전에 강제.
  - 보안: `../`·절대경로·빈 컴포넌트·`\` 경로 거부(+최종 경로 prefix 재검증), 심볼릭 링크 엔트리 skip(central dir unix mode 0o120000), 추출 총량 50MB 상한, 암호화/zip64/기타 압축방식 거부, 모든 오프셋 bounds-check.
- `Sources/MenubucketCore/WidgetDiscovery.swift`
  - `discover(under:subdirectory:)` — widget.json 포함 디렉토리 전부 탐색(DFS, depth 8). GitHub 아카이브의 단일 wrapper 디렉토리 자동 unwrap. widget.json 발견 디렉토리는 하위 미탐색(위젯 콘텐츠로 간주). subdir 지정 시 그 안만.
  - manifest 디코딩 검증(id/schemaVersion은 non-optional이라 디코딩이 곧 검증) + `isValidWidgetID`(설치 디렉토리명 안전성) + `version` 필드 별도 probe(Manifest 미포함 필드, 다이얼로그 표시용).
  - `permissionSummary(for:)` — exec 커맨드 / keychain / notifications 요약(계약 그대로, Codex 문서와 일치 대상).
  - 실패는 Failure(relativePath, reason)로 수집 → 완료 알림의 "실패 사유".

### MenubucketApp
- `Sources/MenubucketApp/WidgetInstaller.swift` (신규)
  - `WidgetInstallFlow`: 다운로드(URLSession async bytes, **20MB 상한** — expectedContentLength + 수신 누적 양쪽 체크, 404 시 다음 후보 폴백) → 임시 디렉토리 추출 → 탐색 → `~/Library/Application Support/menubucket/widgets/<manifest.id>/` 복사(기존 존재 시 삭제 후 교체 = 업데이트).
  - `WidgetInstaller` (GUI): URL 입력 NSAlert → 위젯별 확인 NSAlert(이름/버전/id/권한 요약/Install·Update/Cancel, 업데이트·권한 재승인 문구) → 완료 요약 NSAlert(성공 N개 + 실패 사유). 자동 권한 승인 없음(첫 실행 승인 카드가 게이트, 다이얼로그에도 명시).
  - `WidgetInstallCLI`: 다이얼로그 없이 진행, 권한 요약 stdout 출력, exit 0(전부 성공·1개 이상 설치)/1.
- `Sources/MenubucketApp/main.swift` — `install` 인자 분기(NSApplication 기동 전 exit), AppDelegate `application(_:open:)` 딥링크 → `WidgetInstaller.shared.handleDeepLink`.
- `Sources/MenubucketApp/StatusItemController.swift` — 우클릭 메뉴 "Install Widget from URL…" 추가. `WidgetInstaller.shared.onInstalled = { runtime.loadWidgets() }` — 핫 리로드가 기본 반영 경로지만, **앱 기동 시 watch 디렉토리(app support widgets/)가 없었던 첫 설치** 케이스를 커버(WidgetRuntime 파일은 미수정, 기존 internal API 호출만).
- `scripts/Info.plist.template` — `CFBundleURLTypes`에 `menubucket` 스킴 등록(plutil lint OK).

### 테스트 (신규 2파일, 24 케이스)
- `Tests/MenubucketCoreTests/WidgetInstallSourceTests.swift` — GitHub URL 변형(bare/slash/.git/tree/tree+subdir/malformed), 아카이브(zip/MBW/release asset/쿼리스트링), 딥링크(정상/액션 오류/url 누락/중첩), 스킴 거부.
- `Tests/MenubucketCoreTests/WidgetInstallArchiveTests.swift` — 자체 `ZipFixture` 빌더(stored/deflate/symlink/악성 경로명을 바이트 레벨로 생성 — zip CLI로는 못 만드는 hostile 픽스처): 경로 탈출 3종 거부, symlink 무시, 50MB류 상한, 멀티 위젯 발견(wrapper unwrap + 버전 probe + broken manifest 실패 수집), 루트 위젯, subdir 스코프, id 검증, 권한 요약.

## 검증
- `DEVELOPER_DIR=… swift build` OK, `swift test` **93/93 통과**.
- E2E(CLI): 픽스처 zip(`/usr/bin/zip` 생성 = 실전 deflate) → `python3 -m http.server` 로컬 서빙 → `.build/debug/menubucket install http://127.0.0.1:8741/fixture.zip` → 권한 요약 stdout 출력, `…/widgets/e2e-fixture-widget/` 배치 확인, exit 0, 이후 정리 완료.
- 실 GitHub 다운로드 1회: `menubucket install https://github.com/octocat/Hello-World` — codeload main 404 → **master 폴백 성공**, 추출 후 "no widget.json found" 보고, exit 1 (정상 동작).
- 실패 경로: 비지원 URL exit 1, 인자 누락 usage + exit 1.

## 남은 사항 / 참고
- "완료 알림"은 GUI에서 NSAlert 요약으로 구현(UNUserNotificationCenter는 unbundled 실행에서 실패 가능성이 있어 회피). 필요 시 NotificationService 연동으로 교체 가능.
- 브랜치명에 `/` 포함 시 tree URL의 branch/subdir 경계는 첫 세그먼트를 branch로 해석(API 없이는 판별 불가 — 계약 범위).
- zip64/암호화 아카이브는 명시적 오류로 거부(20MB 다운로드 상한 내에서 zip64 불필요).
- 딥링크 실동작(브라우저 → LSOpen)은 패키징된 .app 재설치 후 확인 필요(Info.plist 반영은 build_app.sh 재실행 시).

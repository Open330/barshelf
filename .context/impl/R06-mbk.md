# R06 Track A — mbk 독립 CLI · HeadlessInstaller (구현 노트)

구현 계약: R06-tasks.md 공통 계약 1(HeadlessInstaller API) + 공통 계약 3(mbk 서브커맨드 UX) 전부.
테스트 133/133 통과 (기존 93 + Track A 신규 26 + Track B Registry 14).

## 신규/수정 파일

### MenubucketCore
- `Sources/MenubucketCore/HeadlessInstaller.swift` (신규 — WidgetInstaller에서 추출)
  - **계약 1 API 그대로**: `InstallCandidate { manifest, sourceDirectory, permissionSummary: [String] }`
    (+추가 필드 `displayVersion`, `relativePath`, `displayLine`),
    `HeadlessInstaller.fetchCandidates(from: URL) async throws -> [InstallCandidate]`,
    `install(_:into:) throws -> URL` (설치 디렉토리 반환, 기존 존재 시 삭제 후 교체 = 업데이트).
  - `fetchSession(input: String) -> Session` — 실패 사유(`WidgetDiscovery.Failure`)·stagingRoot·명시적 `cleanup()`이 필요한 소비자용(앱 GUI/CLI, mbk). `fetchCandidates`는 빈 결과 시 `HeadlessInstallError.noWidgetsFound`를 던지고, staging은 temp에 남음(OS 정리).
  - 다운로드(20MB 상한, 404 → main→master 폴백)를 App에서 Core로 이동. `defaultWidgetsDirectory` = `~/Library/Application Support/menubucket/widgets`.
  - **로컬 아카이브 확장**: `file://` URL·존재하는 로컬 `.zip`/`.mbw` 경로를 직접 허용(`mbk install ./x.mbw`).
    `menubucket://` 딥링크는 여전히 `WidgetInstallSource.parse` 경유라 file 스킴 거부 유지(브라우저 유입 보안 불변).

### MenubucketApp (public API 불변 — 내부 위임만)
- `Sources/MenubucketApp/WidgetInstaller.swift` — `WidgetInstallFlow`의 prepare/download/install/isInstalled 시그니처 유지, 구현은 전부 `HeadlessInstaller` 위임. `WidgetInstaller`(GUI)·`WidgetInstallCLI`(`menubucket install` 인자 모드)는 무변경 — 스모크로 로컬 .mbw 설치 exit 0, usage exit 1 확인.

### MbkCLI (신규)
- `Package.swift` — `.executable(name: "mbk", targets: ["MbkCLI"])`. 테스트 가능하도록 2분할:
  - `Sources/MbkCLI/MbkKit/` — **라이브러리 타깃 MbkKit** (모든 로직, Foundation+CryptoKit만, AppKit 없음)
  - `Sources/MbkCLI/Main/main.swift` — `exit(MbkMain.run(...))` 한 줄
- `MbkKit/MbkMain.swift` — 서브커맨드 디스패치 + install/list. 계약 3 그대로:
  - `install <url> [--yes]`: 권한 요약 stdout, TTY면 위젯별 y/N 프롬프트, 파이프(비 TTY)면 자동 진행+안내 출력, exit 0 = 1개 이상 설치 && 실패 0.
  - `--version`(0.1.0)/`--help`(exit 0), 미지 커맨드 usage stderr exit 1. 오류는 전부 stderr.
- `MbkKit/WidgetScaffold.swift` — `new` 템플릿 3종: exec(widget.sh viewtree 셸, 0o755), workflow(recent-files 축소판: fs.directory+list), script(clock-script 축소판: `import { mb, ui } from "menubucket"`, `mb.widget({load,timer})`). 이름은 `WidgetDiscovery.isValidWidgetID` 검증, 비어있지 않은 디렉토리 거부. 생성 직후 자동 validate → "validate: OK" 그린 메시지.
- `MbkKit/WidgetValidator.swift` — `validate` 디렉토리/.mbw(SafeZipExtractor 재사용) 겸용.
  - Core 디코더(`Manifest.decode`, `WorkflowDefinition`)로 검증, `DecodingError` → **`파일: 필드.경로: 메시지`** 매핑(keyNotFound/typeMismatch/valueNotFound/dataCorrupted, 배열 인덱스 `settings[2].key` 형식).
  - 추가 규칙: id 유효성, entry.kind ∈ {exec,workflow,script}, workflow main 존재+디코드(비-workflow 옆의 workflow.json도 검사), exec은 source.command 또는 source.discover 필요, `manifest.sha256` 존재 시 widget.json 체크섬 대조(변조 검출).
- `MbkKit/WidgetPacker.swift` — `pack`: validate 선행(실패 시 거부) → temp staging 복사(숨김파일·심볼릭 링크 제외) + `manifest.sha256`(`<hex>  widget.json`, sha256sum 호환) → `/usr/bin/zip -X -q <out> <files…>`(명시적 파일 목록 — `./` prefix 없는 엔트리명으로 SafeZipExtractor 호환). 기존 출력 파일은 삭제 후 생성(zip append 방지). 기본 출력 `./<dirname>.mbw`.
- `scripts/build_app.sh` — 앱 서명 앞단에 mbk 빌드+`dist/mbk` 복사+strip+codesign(ad-hoc/identity, 앱과 동일 규칙) 추가. `bash -n` OK.

### 테스트 (신규 3파일, 26 케이스 — Tests/MbkCLITests/)
- `MbkRoundtripTests` — kind 3종 각각 new→validate→pack→validate(.mbw) 라운드트립(임시 디렉토리), 아카이브 내 manifest.sha256 일치, 변조(.mbw 내용 수정) 시 mismatch 검출, 비어있지 않은 디렉토리/불량 이름 거부.
- `WidgetValidatorTests` — 고장난 manifest 픽스처: 파일 없음, entry 누락(`entry`), 중첩 누락(`entry.kind`), 타입 불일치(`schemaVersion`), JSON 문법 오류, 불량 id, exec 커맨드 없음, workflow main 없음/불량 workflow.json, 번들 위젯 5종 그린 확인.
- `HeadlessInstallerTests` — 로컬 zip(.mbw, 실제 /usr/bin/zip deflate) fetchCandidates→install, 재설치 시 기존 디렉토리 완전 교체(stale 파일 제거), 경로 문자열 입력(fetchSession), 없는 로컬 파일 거부, 위젯 없는 zip → noWidgetsFound, `MbkMain.listWidgets` exit 코드.

## 검증
- `DEVELOPER_DIR=… swift build` OK, `swift test` **133/133 통과** (Track B GalleryView 커밋 이후 전체 그린).
- CLI 스모크: `swift run mbk --help` exit 0; `mbk new demo-widget` → validate OK → `mbk pack` → `mbk validate demo-widget.mbw` → `mbk install ./demo-widget.mbw --yes` 설치+`mbk list` 표시 → 정리 완료. `mbk new --kind workflow/script`도 validate 그린.
- 앱 인자 모드: `.build/debug/menubucket install ./demo-widget.mbw` exit 0(내부 HeadlessInstaller 경유), 인자 누락 usage exit 1.

## 남은 사항 / 참고
- **SafeZipExtractor는 exec 비트를 복원하지 않음**(R05부터의 기존 동작, 파일 소유권상 미수정) — .mbw로 설치된 exec 위젯의 `widget.sh`에 +x가 없음. GitHub zip 설치도 동일. ExecService의 상대경로 실행 방식에 따라 후속 라운드에서 SafeZipExtractor가 central-dir unix mode의 exec 비트를 적용하도록 개선 권장.
- `mbk install`의 대화형 y/N은 TTY에서만; CI/파이프에서는 자동 진행 + 안내 한 줄(계약 그대로). `--yes`로 안내도 억제.
- `mbk pack`은 심볼릭 링크·숨김 파일을 아카이브에서 제외(SafeZipExtractor가 어차피 거부/스킵하는 대상과 정합).
- mbk 버전 상수는 `MbkMain.version`(0.1.0) — build_app.sh의 `APP_VERSION`과 별개(필요 시 통일 가능).

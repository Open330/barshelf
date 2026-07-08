# menubucket R06 태스크 — mbk 독립 CLI · 위젯 갤러리/레지스트리 (3트랙 병렬)

전제: R05 완료(테스트 93/93, URL 설치 3경로 동작). 노트: `.context/impl/R05-perf.md`, `R05-install.md`.
빌드/테스트: 항상 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build|test` (혼용 시 `rm -rf .build`).

## 공통 계약 1 — 설치 파이프라인 (A가 구현·소유, B는 소비만)

- Track A는 다운로드→추출→탐색→설치 로직을 **MenubucketCore `HeadlessInstaller`**(신규)로 추출한다:
  ```swift
  public struct InstallCandidate { manifest, sourceDirectory, permissionSummary: [String] }
  public enum HeadlessInstaller {
    static func fetchCandidates(from url: URL) async throws -> [InstallCandidate]
    static func install(_ c: InstallCandidate, into widgetsDir: URL) throws -> URL  // 설치된 디렉토리 반환
  }
  ```
- **App의 `WidgetInstaller` 기존 public API(시그니처)는 변경 금지** — 내부만 HeadlessInstaller 위임으로 교체. Track B(갤러리)가 기존 API를 그대로 호출한다.

## 공통 계약 2 — 레지스트리 인덱스 v0.1 (B가 구현, C가 문서화)

`registry/index.json` (repo 루트 — raw URL로 서빙; PUBLISHING repo 규약 위의 큐레이션 레이어):

```jsonc
{
  "schemaVersion": 1,
  "name": "menubucket official registry",
  "updatedAt": "2026-07-08T00:00:00Z",
  "widgets": [
    {
      "id": "dev.menubucket.aas-usage",          // manifest.id와 일치(설치 후 검증)
      "name": "aas Usage",
      "description": "LLM 에이전트 계정 사용량 미터",
      "version": "0.1.0",
      "author": "menubucket",
      "icon": "gauge",                            // SF Symbol
      "kind": "exec",                             // exec | workflow | script
      "tags": ["dev", "ai"],
      "install": { "url": "https://github.com/OWNER/REPO/tree/main/widgets/aas-usage" },  // R05 설치 URL 계약과 동일 형식
      "permissions": { "exec": ["aas"], "keychain": false, "notifications": false },       // 갤러리 표시용 요약(신뢰 UX)
      "homepage": "https://github.com/OWNER/REPO"
    }
  ]
}
```

- 레지스트리 URL 해석 순서: env `MENUBUCKET_REGISTRY`(URL 또는 로컬 경로) → 기본 원격 URL 상수(플레이스홀더 `https://raw.githubusercontent.com/menubucket/registry/main/index.json`) → 번들 `registry/index.json` 폴백(오프라인/개발).
- 표시 전 검증: schemaVersion==1, 각 entry의 id/name/install.url 필수. 잘못된 entry는 건너뛰고 경고.
- **permissions 필드는 표시용일 뿐** — 실제 게이트는 설치 후 승인 카드(기존 프레임). 문서에 명시.

## 공통 계약 3 — mbk 서브커맨드 UX (A가 구현, C가 문서화)

```
mbk install <url>                  # R05 URL 계약 그대로 (GitHub/zip/.mbw/딥링크 문자열)
mbk new <name> [--kind exec|workflow|script] [--dir <path>]   # 기본 kind=exec, 기본 dir=./<name>
mbk validate <path>                # widget.json(+workflow.json 있으면) Core 디코더로 검증, 오류를 파일:필드 단위로 출력
mbk pack <dir> [-o <name>.mbw]     # zip(.mbw) 생성 + 아카이브에 manifest.sha256 포함(widget.json의 sha256)
mbk list                           # 설치된 위젯 나열 (id, name, version, kind)
mbk --version / --help
```
- exit 0 성공 / 1 실패. 출력은 사람이 읽는 평문(컬러 불필요), 오류는 stderr.
- `mbk pack`의 zip 생성은 `/usr/bin/zip` Process 호출 허용(개발 도구이므로). `mbk validate`는 pack된 .mbw도 받으면 검증(SafeZipExtractor 재사용).
- `mbk new` 템플릿 3종: exec(hello식 셸+manifest), workflow(recent-files 축소판), script(clock-script 축소판, `import { mb, ui } from "menubucket"`). 생성 직후 `mbk validate` 자동 실행해 green 확인 메시지.

## Track A — mbk 독립 CLI (Claude 에이전트 A)

**소유**: `Package.swift`(mbk executableTarget 추가), `Sources/MbkCLI/**`(신규), `Sources/MenubucketCore/HeadlessInstaller.swift`(신규, WidgetInstaller에서 추출), `Sources/MenubucketApp/WidgetInstaller.swift`(내부 위임 리팩터만 — public API 불변), `Tests/**`(신규 테스트 파일), `scripts/build_app.sh`(dist에 mbk 바이너리 복사 추가).
**금지**: `StatusItemController.swift`, `RootView.swift`, `GalleryView*`(B 신규), `Registry*`(B 신규), `registry/`, `docs/`, `README.md`, `schema/`, `sdk/`, `widgets/`.

1. Package.swift: `.executableTarget(name: "MbkCLI", dependencies: ["MenubucketCore"])`, 프로덕트명 `mbk`. Foundation만 사용(AppKit 금지 — 순수 CLI).
2. 공통 계약 1·3 구현. install은 HeadlessInstaller 사용(다이얼로그 없음, 권한 요약 stdout 출력 후 `--yes` 없으면 stdin 확인 프롬프트, 파이프 비인터랙티브면 자동 진행 + 요약 출력).
3. 앱의 `menubucket install` 인자 모드는 유지하되 내부를 HeadlessInstaller로 통일.
4. 테스트: new→validate→pack→validate(.mbw) 라운드트립(임시 디렉토리), validate 오류 리포팅(고장난 manifest 픽스처), HeadlessInstaller 로컬 zip 설치. CLI 바이너리 자체는 `swift run mbk --help` 스모크 1회.
5. 노트 → `.context/impl/R06-mbk.md`.

## Track B — 위젯 갤러리/레지스트리 (Claude 에이전트 B)

**소유**: `Sources/MenubucketCore/Registry.swift`(신규), `Sources/MenubucketApp/GalleryView.swift`(신규), `StatusItemController.swift`(메뉴 항목 추가만), `registry/index.json`(신규 샘플), `Tests/**`(신규 테스트 파일).
**금지**: Package.swift, WidgetInstaller.swift, HeadlessInstaller(A 소유 — **기존 WidgetInstaller public API만 호출**), MbkCLI, docs/, README.md, schema/, sdk/, widgets/, scripts/.

1. `Registry.swift`: 공통 계약 2의 Codable 모델 + `RegistryClient`(URL/로컬/번들 폴백 로드, 24h 디스크 캐시 + 수동 새로고침, 잘못된 entry 스킵). 단위 테스트(픽스처 JSON, 오류 entry 스킵, 폴백 순서).
2. `registry/index.json` 샘플: 번들 위젯 5종(aas-usage/otpeek/hello/clock-script/recent-files)을 이 repo 기준 install.url로 등재(OWNER/REPO 플레이스홀더 주석).
3. `GalleryView.swift`: 별도 NSWindow(SwiftUI) — 검색 필드(이름/태그), 카드 리스트(아이콘/이름/설명/kind 배지/권한 칩), [Install] 버튼 → 기존 `WidgetInstaller` GUI 플로우 호출, 설치됨 상태 표시(설치 디렉토리 존재 기준), 새로고침 버튼. 팝업이 아닌 독립 창(팝업 크기 제약 회피).
4. `StatusItemController`: 우클릭 메뉴에 "Widget Gallery…" 추가.
5. 검증: 빌드+테스트, 갤러리 창 렌더는 GUI라 코드 리뷰 수준(스모크는 메인 세션이 수행).
6. 노트 → `.context/impl/R06-gallery.md`.

## Track C — 문서 (Codex)

**소유**: `docs/**`, `README.md`, `schema/registry-0.1.json`(신규). **금지**: 나머지 전부.

1. `schema/registry-0.1.json` — 공통 계약 2의 JSON Schema.
2. `docs/MBK.md` — 공통 계약 3 그대로 CLI 레퍼런스(서브커맨드 표, 예제 세션, exit 코드).
3. `docs/REGISTRY.md` — 레지스트리 운영 규약: index.json 필드 표, 등재 방법(PR 절차), 큐레이션 기준(권한 최소화·README 필수 등), permissions 필드가 표시용임을 명시, 셀프호스팅(`MENUBUCKET_REGISTRY`).
4. `docs/PUBLISHING.md` 갱신 — "레지스트리에 등재하기" 섹션 추가, `mbk new/validate/pack` 워크플로 반영.
5. `README.md` — mbk CLI·갤러리 소개 추가, 문서 인덱스 갱신.
6. 검증: `jq empty schema/registry-0.1.json` + 문서 내 커맨드가 계약과 일치. `.context/impl/R06-codex.md` 직접 쓰기 금지.

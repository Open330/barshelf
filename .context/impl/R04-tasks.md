# menubucket M2-b 구현 태스크 (R04) — workflow 엔진 · 파일 위젯 · 팝업 UX 마감

전제: R03 완료(테스트 60/60, JSON-RPC 런타임 + 권한 강제 동작). 스펙: `.context/plans/R01-merged.md` §1 D2·D6, `.context/plans/R01-codex.md` §4(workflow DSL)·§15(recent-files 예제). 구조: `.context/impl/R03-claude.md`.
테스트: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

## 공통 계약 — workflow DSL v1 (JSON, 두 에이전트 일치)

manifest `entry: {kind:"workflow", main:"workflow.json"}`. workflow 파일:

```jsonc
{
  "schemaVersion": 1,
  "sources": {                       // I/O — 호스트가 실행
    "files": { "use": "fs.directory",  // v1 소스: "exec" | "fs.directory"
               "with": { "path": "${settings.folder}", "watch": true, "skipHidden": true,
                          "sortBy": "modifiedAt", "sortDirection": "descending", "limit": "${settings.limit}" } }
  },
  "transforms": {                    // 순수 변환 (v1: assign/filter/sort/limit)
    "visible": { "use": "assign", "from": "$.sources.files.items" }
  },
  "view": { /* UINode 템플릿 — ${...} 보간 + forEach */ },
  "empty": { /* items 0개일 때 UINode */ },
  "status": { "tooltip": "${count(transforms.visible)} items" }
}
```

- **표현식**: arbitrary JS 금지. `${...}` 보간 안에서만 — JSONPath 유사 경로(`settings.x`, `sources.id.field`, `transforms.id`, forEach 스코프 변수) + 내장 함수 `now() count(list) date.relative(ms) file.basename(path) file.extension(path) text.truncate(s,n) coalesce(a,b,...)`.
- **forEach 템플릿**: `"items": { "forEach": "$.transforms.visible", "as": "file", "template": { ...UINode, "${file.path}" 보간... } }`.
- **fs.directory 출력 item 필드**: `id path name modifiedAt(ms) size(bytes) isDirectory ext`.
- **파일 노드**: image `source: {kind:"fileIcon"|"fileThumbnail", path, modifiedAt}` — 호스트 썸네일 서비스가 해석. 노드에 `drag: {filePath}`가 있으면 해당 뷰를 Finder/타 앱으로 드래그아웃 가능.

## Task A — Swift 전체 (담당: Claude 에이전트)

**소유**: `Package.swift`, `Sources/**`, `Tests/**`, `widgets/**`. **금지**: `sdk/`, `docs/`, `README.md`, `schema/`, `scripts/`.

1. **WorkflowEngine** (Core, 테스트 대상): workflow.json 파싱 → sources 실행(exec은 기존 ExecService+allowlist, fs.directory는 FileSourceService) → transforms → `${}` 보간+forEach로 UINode 생성. 표현식 evaluator는 위 내장 함수만(파싱 실패 시 명확한 오류). `watch: true`면 기존 watch 트리거(FSEvents debounce)에 연결.
2. **FileSourceService** (App): 디렉토리 나열(FileManager resourceValues: name/modifiedAt/size/isDirectory), sort/limit/skipHidden. 경로는 `~` 확장. (security-scoped bookmark는 비샌드박스 빌드라 v1 보류 — TODO 주석)
3. **ThumbnailService** (App): file-stack의 ThumbnailCache/DiskThumbnailCache 패턴 이식 — NSCache(200개) + QLThumbnailGenerator + 디스크 캐시(`~/Library/Caches/MenuBucket/thumbnails/`, sha256(path) 키 + mtime 스탬프, 200MB LRU), in-flight coalescing. 렌더러의 `fileThumbnail`/`fileIcon` 이미지 소스 구현(placeholder→비동기 로드), 팝업 닫힘 중 프리페치 중단.
4. **드래그아웃**: UINode `drag: {filePath}` → SwiftUI `.onDrag { NSItemProvider(object: URL as NSURL) }`.
5. **recent-files 위젯**: `widgets/recent-files/widget.json` + `workflow.json` — R01-codex §15를 위 JSON DSL로 번역(grid/list 뷰모드 settings, fileThumbnail grid + revealFile 액션, empty 상태). 기본 폴더 `~/Downloads`.
6. **핀 행**: manifest `bucket.pinned: true`(신규 필드) 또는 사용자 토글(위젯 헤더 우클릭 메뉴) → 모든 페이지 상단 고정 영역(최대 2행), 상태는 App Support에 저장.
7. **통합 검색(⌘F)**: 팝업에서 ⌘F 또는 타이핑 시작 → 검색 오버레이 — 위젯 이름 매칭 + 각 위젯 뷰 트리의 text/id 노드 매칭(현재 스냅샷 기준). ↑↓ 이동, ⏎ = 해당 노드의 action 실행(있으면), Esc 단계적 닫기.
8. **설정 UI**: manifest `settings[]`(string/integer/boolean/enum/directory) → 위젯 헤더 우클릭 "Settings…" → 시트/팝오버 폼 자동 생성, 값은 App Support 저장 + 위젯 reload에 반영(`${settings.x}` 보간, script 위젯 settings 파라미터).
9. **테스트**: WorkflowEngine(보간/forEach/내장함수/오류), FileSourceService(sort/limit, 임시 디렉토리 픽스처), recent-files workflow.json 파싱→UINode 생성 통합, 핀/설정 저장 모델. 목표: 기존 60 + 신규 15+.
10. 검증 후 노트 → `.context/impl/R04-claude.md`.

## Task B — 스키마·문서 (담당: Codex 에이전트)

**소유**: `schema/**`, `docs/**`, `README.md`. **금지**: Package.swift, Sources/, Tests/, widgets/, sdk/, scripts/.

1. `schema/workflow-0.1.json` 신설 — 위 workflow DSL v1의 JSON Schema (sources/transforms/view/empty/status, forEach 템플릿, 내장 함수 목록은 description으로).
2. `schema/widget-0.1.json` — `bucket.pinned`, `entry.kind: workflow`의 main 필드 요건 반영.
3. `schema/uinode-0.1.json` — `drag: {filePath}`, image source `fileIcon|fileThumbnail(path, modifiedAt)` 추가.
4. `docs/WORKFLOW.md` 신설 — DSL 레퍼런스(소스/변환/보간/내장함수/forEach 표), recent-files 워크스루, exec 소스 + allowlist 관계. 한국어.
5. `docs/WIDGET-SPEC.md`·`README.md` — 핀/검색/설정/드래그아웃/workflow 링크 반영.
6. 검증 `jq empty schema/*.json`. `.context/impl/R04-codex.md` 직접 쓰기 금지.

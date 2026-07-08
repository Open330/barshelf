# R04 구현 노트 (Task A — workflow 엔진 · 파일 위젯 · 팝업 UX)

상태: **완료** (에이전트가 세션 한도로 조기 종료 → 전체를 메인 세션이 직접 구현). `swift build`/`swift test` **69/69**, `scripts/build_app.sh` 번들 생성 + 5초 스모크 런 통과.
주의: 이 머신에서 CommandLineTools(6.3.3)와 Xcode(6.2.4) 툴체인 혼용 시 모듈 캐시가 충돌함 — **빌드·테스트 모두 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 사용** (혼용했다면 `rm -rf .build`).

## 파일

- `Sources/MenubucketCore/Workflow.swift` — `WorkflowDefinition`(sources/transforms/view/empty/status Codable), `WorkflowEngine`: phase1 `resolvedSourceParams`(settings 보간) / phase2 `evaluate`. `${}` 보간(단일 표현식은 타입 유지), 내장함수 now/count/coalesce/date.relative/file.basename/file.extension/text.truncate, forEach 템플릿(스코프 변수), transforms assign/filter/sort/limit(lazy + 사이클 가드), 아이템 0개+empty 정의 시 empty 노드로 대체(`usedEmpty`).
- `Sources/MenubucketCore/FileSource.swift` — fs.directory 소스: resourceValues 나열, skipHidden/sortBy/sortDirection/limit, `~` 확장, item 스키마 `{id path name modifiedAt size isDirectory ext}`.
- `Sources/MenubucketCore/UINode.swift` — `drag: {filePath}` 필드, `ImageSource.path/modifiedAt`(fileIcon/fileThumbnail).
- `Sources/MenubucketCore/Manifest.swift` — `Entry.main`, `Setting.title/options/min/max`.
- `Sources/MenubucketApp/WidgetRuntime.swift` — entry.kind workflow 경로: workflow.json 로드→phase1→소스 실행(exec: allowlist·감사·discover·timeout 동일 강제 / fs.directory: detached)→evaluate→snapshot. fs.directory `watch:true`는 위젯별 DirectoryWatcher(팝업 열림 시만 refresh). `prefs`(WidgetPrefs) 소유, workflow/script 갱신에 effectiveSettings 사용.
- `Sources/MenubucketApp/ThumbnailService.swift` — NSCache(200) → 디스크(sha256+mtime 키, 200MB oldest-first prune) → QLThumbnailGenerator, in-flight coalescing, 메인 큐 콜백.
- `Sources/MenubucketApp/Renderer/ViewTreeRenderer.swift` — fileIcon/fileThumbnail 렌더(FileImageView: 아이콘 즉시 → 썸네일 스왑, onAppear 로드라 팝업 닫힘 중 프리페치 없음), `drag` → `.onDrag` 파일 드래그아웃.
- `Sources/MenubucketApp/WidgetPrefs.swift` — 핀 목록+설정 오버라이드, App Support `menubucket/prefs.json`.
- `Sources/MenubucketApp/WidgetSettingsView.swift` — manifest settings[] 폼 자동 생성(string/integer/boolean/enum/directory+NSOpenPanel), 저장 시 refresh. `SearchOverlay` — ⌘F 통합 검색(위젯 이름 + 스냅샷 text 노드), ⏎로 페이지 점프+노드 액션 실행.
- `Sources/MenubucketApp/RootView.swift` — 핀 행(모든 페이지 상단, 최대 2개, 카드 우클릭 Pin/Unpin), 헤더 검색 버튼+⌘F, 카드 contextMenu(Pin/Settings/Refresh)+설정 시트.
- `widgets/recent-files/` — workflow 위젯 예제(fileThumbnail 그리드 행, drag, revealFile, empty 상태, status tooltip).
- `Tests/MenubucketCoreTests/WorkflowEngineTests.swift` — 엔진 6 + FileSource 3 (recent-files workflow.json end-to-end 포함).

## 설계 이탈 / 한계

- security-scoped bookmark는 비샌드박스 빌드라 보류(TODO) — readPaths는 선언만.
- 핀 행은 세로 스택 최대 2개(스펙의 "타일 2열"은 사이즈 클래스 그리드와 함께 후속).
- 검색은 현재 스냅샷 기준(과거/미렌더 위젯 콘텐츠 미포함), 키보드 ↑↓ 선택은 마우스/⏎ 경로만 검증.
- WidgetPrefs/ThumbnailService는 App 타깃이라 단위 테스트 없음(Core 이동 후보).
- workflow `empty`는 뷰 전체를 대체(위젯 카드 헤더는 유지) — 문서화된 결정.

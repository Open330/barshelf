# R07 — file-stack(Stashbar) repo에 MenuBucket 위젯 추가

날짜: 2026-07-08
대상 repo: /Users/jiun/workspace/file-stack (github.com/jiunbae/file-stack, public)
브랜치: `feat/menubucket-widget` (커밋 d70780e, **push 안 함** — 사용자 확인 후 메인 세션에서 push/PR)

## 변경 내용

- `widgets/menubucket-recent-files/widget.json` — recent-files 위젯 기반. 변경점:
  - id: `dev.menubucket.stashbar-recent-files` (원본: dev.menubucket.recent-files)
  - name: "Stashbar Recent Files"
  - `description` 필드 추가 (Stashbar 본가 링크 포함; widget-0.1 스키마는 additionalProperties: true라 허용됨)
  - 기본 폴더 및 readPaths: `~/Pictures/Screenshots` (원본: ~/Downloads)
- `widgets/menubucket-recent-files/workflow.json` — 원본 그대로 복사 (fs.directory + fileThumbnail + drag/openFile/revealFile)
- `widgets/menubucket-recent-files/README.md` — 설치법(`mbk install https://github.com/jiunbae/file-stack` + menubucket:// 딥링크 배지), 기능, Stashbar 본가 앱과의 관계 설명 (한국어)
- `README.md` (메인, 한국어) — "## MenuBucket 위젯" 섹션을 "## 사용법" 앞에 삽입. 기존 내용 무변경.

## 검증

- `jq empty` widget.json / workflow.json — 통과
- `/Users/jiun/workspace/menubucket/dist/mbk validate widgets/menubucket-recent-files` → `valid: 1 widget(s) — .`

## 후속 (미결)

- 사용자 확인 후 push + PR
- 원하면 레지스트리 등재: menubucket repo `registry/index.json`에 entry PR
  (id 일치, install.url: `https://github.com/jiunbae/file-stack/tree/main/widgets/menubucket-recent-files`)
- file-stack repo 루트가 아닌 subdir 설치를 원하면 README의 install URL을 `/tree/main/widgets/menubucket-recent-files` 형태로 바꿀 수 있음 (현재는 repo 루트 URL — 설치기가 widget.json 디렉터리를 자동 탐색하므로 동작함)

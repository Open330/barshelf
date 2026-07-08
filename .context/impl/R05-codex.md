Track C 문서 작업 완료했습니다. 수정 범위는 `README.md`와 `docs/` 안으로만 제한했고, `.context/impl/R05-codex.md`는 쓰지 않았습니다.

변경 내용:
- 새 문서 추가: [GETTING-STARTED.md](/Users/jiun/workspace/menubucket/docs/GETTING-STARTED.md), [INSTALLING-WIDGETS.md](/Users/jiun/workspace/menubucket/docs/INSTALLING-WIDGETS.md), [PUBLISHING.md](/Users/jiun/workspace/menubucket/docs/PUBLISHING.md)
- [README.md](/Users/jiun/workspace/menubucket/README.md) 한국어 중심으로 재구성: 3층 구조, 빠른 시작, 문서 인덱스, 위젯 갤러리, URL 설치, 로드맵
- 기존 [WIDGET-SPEC.md](/Users/jiun/workspace/menubucket/docs/WIDGET-SPEC.md), [WORKFLOW.md](/Users/jiun/workspace/menubucket/docs/WORKFLOW.md), [SCRIPT-RUNTIME.md](/Users/jiun/workspace/menubucket/docs/SCRIPT-RUNTIME.md) 링크/예제/용어 보강
- URL 설치 v1 계약 반영: GitHub/codeload 변환, main→master 폴백, subdir 탐색, zip/.mbw, 딥링크, 메뉴바/URL 스킴/CLI 진입점, 설치 위치, hot reload, 권한 승인, 보안 제한, 완료 알림

검증했습니다:
- `jq empty schema/widget-0.1.json schema/uinode-0.1.json schema/workflow-0.1.json`
- 문서 내 JSON 코드블록 파싱
- Markdown 상대 링크 대상 존재 확인
- `widgets/`, `schema/`, `scripts/`, `sdk/` 참조 경로 존재 확인

Swift 테스트는 실행하지 않았습니다. 이번 변경은 문서 전용입니다.
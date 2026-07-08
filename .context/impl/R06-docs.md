# R06 Track C — 문서 완료 노트

날짜: 2026-07-08. 담당: docs/, README.md, schema/registry-0.1.json (Track C).

## 산출물

| 파일 | 내용 |
| --- | --- |
| `schema/registry-0.1.json` (신규) | 공통 계약 2의 JSON Schema (draft-07, `$id: https://menubucket.dev/schema/registry-0.1.json`). 최상위 required: `schemaVersion`(const 1), `widgets`. entry required: `id`, `name`, `install`(→`install.url`). `kind` enum exec\|workflow\|script, `permissions` 요약(exec[]/keychain/notifications)은 description에 표시용임을 명시. `additionalProperties: true`로 전방 호환. |
| `docs/REGISTRY.md` (신규) | index.json 예제(계약 2 jsonc 그대로), 최상위/entry 필드 표, 표시 전 검증 규칙(schemaVersion==1, id/name/install.url 필수, 잘못된 entry 스킵+경고), permissions 표시용 명시(실제 게이트=첫 실행 승인 카드), URL 해석 순서(env `MENUBUCKET_REGISTRY` → 기본 원격 상수 플레이스홀더 → 번들 폴백), 등재 PR 절차 6단계, 큐레이션 기준(권한 최소화·README 필수·정직한 요약·안정적 id·설치 가능성·메타데이터), 셀프호스팅. |
| `docs/MBK.md` (신규) | 공통 계약 3 코드 블록 원문 그대로 + 서브커맨드 표, new 템플릿 3종 표, exit 0/1·평문 출력·stderr 오류, 예제 세션(new→validate 오류→pack→validate .mbw→install 프롬프트/--yes/비인터랙티브→list), 앱 `menubucket install` 인자 모드와의 관계, 빌드(`swift build --product mbk`). |
| `docs/PUBLISHING.md` (갱신) | 관련 문서에 MBK/REGISTRY 추가, "mbk로 만들기 → 검증 → 패키징" 섹션(new/validate/pack/validate .mbw), "레지스트리에 등재하기" 섹션(entry 예제, permissions 표시용 명시, REGISTRY.md/스키마 링크), 체크리스트에 `mbk validate` 통과 항목 추가. |
| `README.md` (갱신) | 문서 인덱스에 MBK.md/REGISTRY.md, 스키마 표에 registry-0.1.json, CLI 설치에 `mbk install` 병기, "mbk CLI" 섹션(5개 커맨드 요약), "위젯 갤러리와 레지스트리" 섹션(우클릭 "Widget Gallery…", 검색/카드/권한 칩 표시용, 레지스트리 해석 순서), 로드맵에 R06 한 줄. |

## 검증

- `jq empty schema/registry-0.1.json` — 통과.
- README.md, docs/PUBLISHING.md, docs/MBK.md, docs/REGISTRY.md의 상대 링크 대상 존재 확인 스크립트 — broken 0.
- 계약 2·3 문구는 태스크 파일 원문 그대로 인용(jsonc 예제, 서브커맨드 블록) — Track A/B 구현과 어긋나지 않음.

## 참고 사항

- `registry/index.json`은 Track B 소유 — 문서에서 참조만 하고 링크는 걸지 않음(작성 시점에 파일 부재 가능).
- 기본 원격 레지스트리 URL은 계약대로 플레이스홀더 `https://raw.githubusercontent.com/menubucket/registry/main/index.json`로 표기. 실제 URL 확정 시 REGISTRY.md 한 곳만 고치면 됨.
- MBK.md 예제 세션의 출력 문구는 예시임을 명시("계약으로 보장되는 것은 서브커맨드·옵션·exit 코드·stderr 오류 출력").
- 금지 영역(Package.swift, Sources/, Tests/, widgets/, sdk/, scripts/, registry/) 미접촉.

# 위젯 레지스트리 운영 규약

BarShelf 레지스트리는 URL 설치 계약 위에 얹힌 **큐레이션 레이어**다. repo 루트의 `registry/index.json` 하나가 raw URL로 서빙되고, 앱의 위젯 갤러리와 도구가 이 인덱스를 읽어 설치 가능한 위젯 목록을 보여준다. 레지스트리에 없는 위젯도 [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)의 URL 설치 경로로 언제든 설치할 수 있다.

관련 문서:

- 스키마: [`schema/registry-0.1.json`](../schema/registry-0.1.json)
- 배포 가이드: [`docs/PUBLISHING.md`](PUBLISHING.md)
- mbk CLI: [`docs/MBK.md`](MBK.md)

## index.json 형식

```jsonc
{
  "schemaVersion": 1,
  "name": "barshelf official registry",
  "updatedAt": "2026-07-08T00:00:00Z",
  "widgets": [
    {
      "id": "dev.barshelf.aas-usage",          // manifest.id와 일치(설치 후 검증)
      "name": "aas Usage",
      "description": "LLM 에이전트 계정 사용량 미터",
      "version": "0.1.0",
      "author": "barshelf",
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

### 최상위 필드

| 필드 | 타입 | 필수 | 설명 |
| --- | --- | --- | --- |
| `schemaVersion` | number | 예 | 반드시 `1`. 다른 값이면 인덱스 전체를 거부한다. |
| `name` | string | 아니오 | 레지스트리 표시 이름. |
| `updatedAt` | string (ISO 8601) | 아니오 | 마지막 갱신 시각. |
| `widgets` | array | 예 | 위젯 entry 배열. |

### 위젯 entry 필드

| 필드 | 타입 | 필수 | 설명 |
| --- | --- | --- | --- |
| `id` | string | 예 | 위젯 식별자. 설치된 `widget.json`의 `manifest.id`와 일치해야 하며, **설치 후 검증**된다. |
| `name` | string | 예 | 갤러리에 표시되는 이름. |
| `description` | string | 아니오 | 갤러리 카드에 표시되는 한 줄 설명. |
| `version` | string | 아니오 | 최신 배포 버전(표시용). |
| `author` | string | 아니오 | 제작자/배포자 이름. |
| `icon` | string | 아니오 | SF Symbol 이름. |
| `kind` | string | 아니오 | `exec` \| `workflow` \| `script`. |
| `tags` | string[] | 아니오 | 검색/필터용 태그. |
| `install.url` | string | 예 | R05 설치 URL 계약과 동일 형식: GitHub 저장소 URL(`/tree/{branch}/{subdir}` 포함 가능), `.zip`/`.mbw` 직접 URL, 딥링크 문자열. |
| `permissions` | object | 아니오 | 갤러리 표시용 권한 요약. 아래 참고. |
| `homepage` | string (URI) | 아니오 | 프로젝트 홈페이지/저장소. |

### 표시 전 검증 규칙

소비자(갤러리, 도구)는 인덱스를 표시하기 전에 다음을 검증한다.

- `schemaVersion == 1`이 아니면 인덱스 전체를 거부한다.
- 각 entry는 `id`, `name`, `install.url`이 필수다.
- 잘못된 entry는 **건너뛰고 경고**한다 — entry 하나의 오류가 인덱스 전체를 막지 않는다.

### permissions 필드는 표시용일 뿐이다

`permissions`는 갤러리 카드에서 사용자가 설치 전 위험도를 가늠하게 하는 **표시용 요약(신뢰 UX)** 이다. 이 필드는 아무 권한도 부여하지 않는다. 실제 권한 게이트는 설치 후 첫 실행 시 나타나는 **승인 카드**(기존 권한 프레임)이며, 게이트 기준은 위젯의 `widget.json`에 선언된 `permissions`다. 인덱스 요약과 manifest 선언이 어긋나면 manifest가 항상 우선한다.

## 레지스트리 URL 해석 순서

앱과 도구는 레지스트리 위치를 다음 순서로 해석한다.

1. 환경 변수 `BARSHELF_REGISTRY` — URL 또는 로컬 파일 경로. `MENUBUCKET_REGISTRY`도 호환용으로 읽는다.
2. 기본 원격 URL 상수 — 플레이스홀더: `https://raw.githubusercontent.com/barshelf/registry/main/index.json`.
3. 번들 `registry/index.json` 폴백 — 오프라인/개발용.

## 등재 방법 (PR 절차)

1. 위젯을 공개 저장소(또는 안정적인 `.zip`/`.mbw` URL)로 먼저 배포한다. 절차는 [`docs/PUBLISHING.md`](PUBLISHING.md)를 따른다.
2. `mbk validate <위젯 디렉터리>`가 통과하는지 확인한다.
3. 레지스트리 저장소를 포크하고 `registry/index.json`의 `widgets` 배열에 entry를 추가한다. `id`는 `widget.json`의 `manifest.id`와 정확히 일치해야 한다.
4. `jq empty registry/index.json`으로 JSON 문법을, [`schema/registry-0.1.json`](../schema/registry-0.1.json)으로 스키마 적합성을 확인한다.
5. PR을 올린다. PR 본문에 위젯 저장소 링크, 권한 요약, 스크린샷(권장)을 포함한다.
6. 리뷰어가 아래 큐레이션 기준으로 검토한 뒤 머지한다. 머지되면 `updatedAt`이 갱신된다.

버전 업데이트도 같은 절차다: entry의 `version`(과 필요 시 `description`, `permissions` 요약)을 갱신하는 PR을 올린다.

## 큐레이션 기준

레지스트리 entry는 다음 기준을 충족해야 한다.

- **권한 최소화**: manifest가 실제로 필요한 권한만 선언한다. 불필요한 `keychain: true`, 과도한 `exec` allowlist, 광범위한 `readPaths`는 반려 사유다.
- **README 필수**: 위젯 저장소에 위젯이 무엇을 하는지, 어떤 명령을 실행하는지, 요구 권한이 왜 필요한지 설명하는 README가 있어야 한다.
- **정직한 요약**: entry의 `permissions` 요약이 manifest 선언과 일치해야 한다.
- **안정적인 id**: `id`는 역방향 도메인 형식(예: `dev.example.clock`)을 권장하며, 한번 등재한 뒤 바꾸지 않는다.
- **설치 가능성**: `install.url`이 실제로 설치 가능해야 한다(아카이브 크기 제한 포함 — [`docs/PUBLISHING.md`](PUBLISHING.md) 체크리스트 참고).
- **표시 메타데이터**: `description`, `icon`, `kind`, `tags`를 채우는 것을 권장한다. 갤러리 카드 품질이 곧 설치 전환율이다.

## 셀프호스팅

조직 내부 배포 등에는 자체 레지스트리를 운영할 수 있다. [`schema/registry-0.1.json`](../schema/registry-0.1.json)을 따르는 `index.json`을 아무 정적 호스팅(raw GitHub, S3, 사내 웹서버)이나 로컬 파일로 서빙하고, 환경 변수로 지정한다.

```bash
# 원격 URL
export BARSHELF_REGISTRY="https://intranet.example.com/barshelf/index.json"

# 또는 로컬 경로 (개발/오프라인)
export BARSHELF_REGISTRY="$HOME/barshelf-registry/index.json"
```

`BARSHELF_REGISTRY`가 설정되면 기본 원격 레지스트리보다 우선한다. `MENUBUCKET_REGISTRY`도 기존 자동화 호환용으로 동일하게 동작한다.

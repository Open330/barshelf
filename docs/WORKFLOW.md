# BarShelf 워크플로 DSL v1

이 문서는 `entry.kind: "workflow"` 위젯이 사용하는 `workflow.json` 계약이다. Workflow는 스크립트 없이 호스트가 직접 실행하는 제한된 선언형 파이프라인이며, 구조는 `source -> transform -> render`로 고정된다.

관련 문서:

- 시작하기: [`docs/GETTING-STARTED.md`](GETTING-STARTED.md)
- URL 설치: [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)
- 위젯 배포: [`docs/PUBLISHING.md`](PUBLISHING.md)
- Workflow UI Engine 로드맵: [`docs/WORKFLOW-UI-ENGINE.md`](WORKFLOW-UI-ENGINE.md)
- Manifest/UINode 스펙: [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)

스키마:

- Workflow: [`schema/workflow-0.1.json`](../schema/workflow-0.1.json)
- UINode: [`schema/uinode-0.1.json`](../schema/uinode-0.1.json)
- Manifest: [`schema/widget-0.1.json`](../schema/widget-0.1.json)

## Manifest 연결

Workflow 위젯은 manifest에서 workflow 파일을 직접 가리킨다.

```json
{
  "$schema": "https://barshelf.jiun.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.example.recent-files",
  "name": "Recent Files",
  "version": "0.1.0",
  "icon": "folder.fill",
  "bucket": { "group": "Files", "order": 30, "size": "L", "pinned": true },
  "entry": { "kind": "workflow", "main": "workflow.json" },
  "refresh": { "onOpen": true, "interval": null, "staleAfterSec": 600, "watchPaths": [], "runInBackground": false },
  "statusItem": { "mode": "icon", "icon": "folder.fill", "tooltipFrom": "$.status.tooltip" },
  "permissions": {
    "files": [
      {
        "id": "recent-folder",
        "access": "read",
        "prompt": "directory",
        "bookmarkSetting": "folder",
        "defaultPath": "~/Downloads",
        "watch": true
      }
    ],
    "storage": { "maxBytes": 262144, "secrets": false },
    "notifications": false
  },
  "settings": [
    { "key": "folder", "title": "Folder", "type": "directory", "default": "~/Downloads", "permission": "recent-folder" },
    { "key": "limit", "title": "Maximum files", "type": "integer", "default": 24, "min": 6, "max": 80 },
    { "key": "viewMode", "title": "View mode", "type": "enum", "default": "grid", "options": ["grid", "list"] }
  ]
}
```

`entry.main`은 위젯 번들 기준 상대 경로이며 JSON workflow 문서여야 한다. Workflow가 파일을 읽거나 명령을 실행하면 I/O는 항상 호스트 서비스가 수행하고, manifest 권한과 매칭되어야 한다.

Builder의 고급 UI는 `WorkflowGraph`를 편집 모델로 사용할 수 있다. 그래프는 저장/편집을 위한 authoring 형식이고, 실행 전에는 이 문서의 `WorkflowDefinition`으로 컴파일된다.

## 파일 구조

```json
{
  "$schema": "https://barshelf.jiun.dev/schema/workflow-0.1.json",
  "schemaVersion": 1,
  "sources": {},
  "transforms": {},
  "view": { "type": "vstack", "children": [] },
  "empty": { "type": "empty", "title": "No items" },
  "status": { "tooltip": "0 items" },
  "store": { "count": { "value": "${add(coalesce(storage.count, 0), 1)}" } }
}
```

| 필드 | 설명 |
| --- | --- |
| `schemaVersion` | v1은 `1`. |
| `sources` | 호스트가 실행하거나 주입하는 입력 단계. v1은 `exec`, `fs.directory`, `http`, `value`를 지원한다. |
| `transforms` | 순수 변환 단계. v1은 `assign`, `filter`, `sort`, `limit`를 지원한다. |
| `view` | 렌더링할 UINode 템플릿. 문자열 필드에서만 `${...}` 보간을 허용한다. |
| `empty` | 반복 결과가 비어 있을 때 사용할 UINode. |
| `status` | 메뉴바 status item의 label/tooltip. [메뉴바 승격](#메뉴바-승격) 참조. |
| `store` | 평가가 끝난 뒤 위젯 저장소에 커밋할 키/값. 자세한 내용은 [영속성](#영속성-storage) 참조. |

## 소스

`sources`의 각 키는 workflow 내부 ID다. 결과는 `sources.<id>` 또는 `$.sources.<id>` 경로로 참조한다.

| `use` | `with` 필드 | 출력 |
| --- | --- | --- |
| `fs.directory` | `path`, `watch`, `skipHidden`, `sortBy`, `sortDirection`, `limit` | `{ "items": [...] }` |
| `exec` | `command`, `timeoutMs`, `output`, `maxOutputBytes` | stdout JSON |
| `http` | `url`, `headers` | HTTPS JSON response |
| `system` | `metrics`, `detail`, `mount` | CPU/메모리/디스크/센서 측정값 |
| `value` | any JSON literal | the literal JSON value |

`fs.directory` item 필드는 고정이다.

| 필드 | 설명 |
| --- | --- |
| `id` | 호스트가 만든 안정적 item ID. |
| `path` | 절대 파일 경로. |
| `name` | 파일 이름. |
| `modifiedAt` | Unix epoch milliseconds. |
| `size` | bytes. |
| `isDirectory` | 디렉터리 여부. |
| `ext` | 확장자. 없으면 빈 문자열. |

예:

```json
{
  "sources": {
    "files": {
      "use": "fs.directory",
      "with": {
        "path": "${settings.folder}",
        "watch": true,
        "skipHidden": true,
        "sortBy": "modifiedAt",
        "sortDirection": "descending",
        "limit": "${settings.limit}"
      }
    }
  }
}
```

`exec` source는 shell 문자열이 아니라 argv 배열만 받는다. 실행 전 `command[0]`과 나머지 argv가 manifest의 `permissions.exec[]` allowlist와 매칭되어야 한다. 매칭되지 않으면 프로세스를 시작하지 않는다.

```json
{
  "sources": {
    "usage": {
      "use": "exec",
      "with": {
        "command": ["aas", "usage", "--json"],
        "timeoutMs": 25000,
        "output": "json",
        "maxOutputBytes": 1048576
      }
    }
  }
}
```

`http` source는 HTTPS GET만 허용하며, URL host가 manifest의 `permissions.network[]` allowlist에 있어야 한다.

```json
{
  "sources": {
    "status": {
      "use": "http",
      "with": { "url": "https://api.github.com/repos/Open330/barshelf" }
    }
  }
}
```

`value` source는 I/O 없이 JSON literal을 그대로 `sources.<id>`에 넣는다. Widget Builder의 **Paste JSON** 소스가 이 형태를 생성한다. 문자열 내부의 `${...}`는 보간하지 않는다.

```json
{
  "sources": {
    "data": {
      "use": "value",
      "with": [{ "name": "Build", "status": "success" }]
    }
  }
}
```

`system` source는 Mach / sysctl / IOKit에서 시스템 측정값을 직접 읽는다.
서브프로세스를 띄우지 않으므로 `permissions.exec`가 필요 없고, 한 번 샘플링하는
비용이 10ms 미만이라 메뉴바 주기(1~3초)에도 쓸 수 있다. 대신 읽는 그룹을
manifest의 `permissions.system`에 **모두 선언해야 한다**. 선언되지 않은 그룹을
요청하면 조용히 빠지는 게 아니라 refresh가 실패한다.

```json
{
  "sources": {
    "data": {
      "use": "system",
      "with": { "metrics": ["cpu", "memory", "disk", "sensors"], "detail": false, "mount": "/" }
    }
  }
}
```

| `with` 필드 | 설명 |
| --- | --- |
| `metrics` | 읽을 그룹 배열: `cpu`, `memory`, `disk`, `sensors`. 생략하면 위젯이 허가받은 전부. |
| `detail` | `true`면 `cpu.cores[]`와 `sensors.list[]`까지 채운다. 기본 샘플의 약 4배 비용. |
| `mount` | `disk` 그룹이 볼 마운트 포인트. 기본 `"/"`. |

출력 규약: **퍼센트는 0~100**, 바이트는 바이트, 온도는 °C, 그리고 이 머신이
제공하지 않는 값은 0이 아니라 `null`이다.

| 경로 | 설명 |
| --- | --- |
| `cpu.usage` / `.user` / `.system` / `.nice` / `.idle` | 직전 샘플 이후 구간의 CPU 점유율. |
| `cpu.coreCount`, `cpu.loadAverage.{1m,5m,15m}` | 코어 수와 load average. |
| `cpu.cores[]` | 코어별 `usage`. `detail: true`일 때만. |
| `memory.{total,used,free,app,wired,compressed,cached,usage}` | Activity Monitor의 "사용 중 메모리"와 같은 계산식(app + wired + compressed). |
| `memory.pressure` | `"normal"` \| `"warning"` \| `"critical"` \| `"unknown"`. |
| `memory.swap.{total,used,free,usage}` | 스왑. |
| `disk.{mount,total,used,free,usage}` | `df`와 같은 기준(예약 블록은 used로 계산). |
| `sensors.available` | 어떤 센서도 읽지 못하면 `false`. 샌드박스 빌드와 VM이 여기 해당한다. |
| `sensors.{cpu,gpu,battery,peak}` | °C. CPU는 코어 다이 센서들의 평균, `peak`은 요약 센서 중 최고값. |
| `sensors.power` | 시스템 총 전력(W). |
| `sensors.fanCount`, `sensors.fans[].{index,name,rpm,min,max,usage}` | 팬. 팬이 없는 Mac은 빈 배열. |
| `sensors.list[]` | `{key, name, kind, value, unit}`. `detail: true`일 때만. |

센서는 항상 optional이다. 값 하나가 `null`일 수 있다는 전제로 뷰를 짜고,
전체가 없을 수 있는 경우는 `sensors.available`로 분기하라 —
`widgets/sensors/workflow.json`이 그 패턴이다.

## 변환

`transforms`의 각 키는 다음 단계에서 `transforms.<id>` 또는 `$.transforms.<id>`로 참조한다.

| `use` | 필수 필드 | 설명 |
| --- | --- | --- |
| `assign` | `from` | 입력 경로의 값을 그대로 바인딩한다. |
| `filter` | `from` | 입력 목록을 조건식으로 거른다. 조건식은 제한된 expression DSL만 사용한다. |
| `sort` | `from` | 입력 목록을 지정한 key/direction으로 정렬한다. |
| `limit` | `from` | 입력 목록의 앞쪽 N개만 유지한다. |

R04 v1의 기준 변환은 `assign`이다.

```json
{
  "transforms": {
    "visible": {
      "use": "assign",
      "from": "$.sources.files.items"
    }
  }
}
```

## 표현식과 보간

Arbitrary JavaScript는 금지한다. 표현식은 문자열 안의 `${...}` 보간에서만 평가된다.

| 범위 | 예 |
| --- | --- |
| settings | `${settings.folder}`, `${settings.limit}` |
| sources | `${sources.files.items}` |
| transforms | `${count(transforms.visible)}` |
| storage | `${storage.count}` (이전 스냅샷; [영속성](#영속성-storage) 참조) |
| widget | `${widget.size}` (현재 카드 크기 `XS`/`S`/`M`/`L` — 크기별 뷰 분기용) |
| forEach 변수 | `${file.path}`, `${file.name}` |

표현식의 리터럴은 숫자(`42`, `-1`), 문자열(`'ok'` 또는 `"ok"`), `true`/`false`/`null`을 지원한다.
문자열 리터럴 덕분에 `eq(status, 'success')`처럼 상수와 비교할 수 있다.

지원 내장 함수는 다음과 같다.

| 함수 | 설명 |
| --- | --- |
| `now()` | 현재 시각을 Unix epoch milliseconds로 반환한다. |
| `count(list)` | 목록 길이를 반환한다. |
| `date.relative(ms)` | epoch milliseconds를 상대 시간 텍스트로 변환한다. |
| `file.basename(path)` / `file.extension(path)` | 경로의 파일명 / 확장자. |
| `text.truncate(s,n)` | 문자열을 최대 길이로 줄인다. |
| `concat(a,b,...)` | 인자들의 문자열 표현을 이어붙인다. `${}` **안에서** 문자열을 만드는 유일한 방법이라 `if(...)`의 각 가지에 단위를 붙일 때 쓴다. |
| `coalesce(a,b,...)` | 첫 번째 non-null·non-empty 값을 반환한다. |
| `default(v, fallback)` | `v`가 falsy면 `fallback`. |
| `if(cond, a, b)` | `cond`가 truthy면 `a`, 아니면 `b`. (인자는 모두 미리 평가됨) |
| `not`, `and`, `or` | 불리언 로직. falsy: `null`·`false`·`0`·`""`·빈 배열·빈 객체. |
| `eq`, `ne` | 값 동등/비동등 비교. |
| `gt`, `gte`, `lt`, `lte` | 순서 비교(양쪽이 숫자면 수치, 아니면 문자열). |
| `contains(hay, needle)` | 문자열 부분일치 또는 배열 포함 여부. |
| `add`, `sub`, `mul`, `div` | 사칙연산(숫자 문자열도 자동 변환). |
| `min`, `max`, `round(v, digits?)` | 최소·최대·반올림. |
| `number(v)` | 숫자로 변환(불가하면 `null`). |

## 메뉴바 승격

최상위 `status` 블록은 메뉴바에 실시간으로 띄울 값을 만든다. 나머지 필드와 같은
컨텍스트에서 평가되는 `${...}` 템플릿이다.

```json
{
  "status": {
    "label": "${string(round(number(sources.data.cpu.usage), 0))}%",
    "tooltip": "CPU ${string(round(number(sources.data.cpu.usage), 0))}% · Memory ${string(round(number(sources.data.memory.usage), 0))}%"
  }
}
```

- `label`이 메뉴바에 그려지는 글자다. 공백은 한 칸으로 합쳐지고 14자에서 잘린다.
- **`status`는 `view`와 같은 컨텍스트에서 평가된다** — `sources`, `transforms`,
  `storage`, 그리고 `settings`를 전부 읽을 수 있다. 이게 사용자가 메뉴바에 무엇이
  뜰지 고를 수 있게 만드는 유일한 방법이다: manifest에 `settings`를 노출하고
  `status.label`이 그걸 읽으면, 사용자는 위젯 설정에서 고르기만 하면 된다.

```json
{
  "status": {
    "label": "${if(eq(settings.menuBarMetric,'memory'), concat(string(round(number(sources.data.memory.usage), 0)), '%'), concat(string(round(number(sources.data.cpu.usage), 0)), '%'))}"
  }
}
```

  대응하는 manifest 쪽:

```json
{
  "settings": [
    { "key": "menuBarMetric", "title": "Menu bar shows", "type": "enum",
      "default": "cpu", "options": ["cpu", "memory", "disk"] }
  ]
}
```

  `options`의 값은 저장되는 값이므로, 사람이 읽을 라벨은 `optionTitles`로 따로
  준다(같은 길이여야 하며, 아니면 무시하고 원본 값을 보여준다). `value` /
  `labeled` 같은 값이 피커에 그대로 뜨는 걸 막는 용도다.

  번들 위젯 `system`(어느 지표를 보일지 + 라벨 포함 여부)과 `sensors`(어느 센서 +
  °C/°F)가 이 패턴을 그대로 쓴다. 설정이 없거나 모르는 값이면 `if`의 else 가지로
  떨어지므로, 기본 동작이 깨지지 않는다.
- 설정은 **위젯 인스턴스별**이다. 같은 위젯을 복제하면(Hub → Widgets →
  Duplicate) 각 복제본이 자기 설정과 자기 메뉴바 자리를 갖는다 — 하나는 CPU,
  하나는 메모리를 동시에 띄우는 방법이 이것이다.
- `tooltip`은 마우스를 올렸을 때의 설명이다.
- 실제로 메뉴바에 나올지는 manifest의 `statusItem.mode`와 사용자의 위젯 설정이
  정한다. 자세한 규칙은 [`WIDGET-SPEC.md`의 `statusItem`](WIDGET-SPEC.md#statusitem).
- 승격된 위젯은 팝오버가 닫혀 있어도 자기 `refresh.interval`로 계속 돈다.
  감당할 수 있는 주기를 적어라.
- `label`이 비면 그 칸은 그려지지 않는다. 값이 없을 때 `'0'` 대신 빈 문자열을
  내보내면 "없음"을 "0"으로 오해시키지 않고 칸이 사라진다.

## 영속성 (storage)

워크플로는 위젯별 KV 저장소(TTL 지원)를 읽고 쓸 수 있다. 스크립트 위젯의
`host.storage.*`와 **같은 네임스페이스**를 공유한다. 사용하려면 매니페스트에서
`permissions.storage`를 `true`(또는 `{ "maxBytes": N }`)로 선언해야 한다.
`false`이거나 없으면 `storage.*`는 항상 빈 값이고 `store`는 무시된다.

- **읽기** — 직전 스냅샷이 `${storage.<key>}` 경로로 주입된다. `view`가 평가되기
  *전*의 값이므로, 카운터/델타처럼 "이전 값"을 참조하는 패턴에 적합하다.
- **쓰기** — 최상위 `store` 블록의 각 항목은 뷰 평가가 끝난 뒤 커밋된다.
  `value`는 뷰와 동일한 컨텍스트에서 평가되는 `${...}` 템플릿이고, `ttlSec`로
  만료를 줄 수 있다. 엔진은 순수성을 유지하기 위해 *무엇을 쓸지*만 계산하고,
  실제 커밋은 호스트가 수행한다.

```json
{
  "sources": {},
  "view": {
    "type": "text",
    "text": "방문 ${string(add(coalesce(storage.count, 0), 1))}회"
  },
  "store": {
    "count":  { "value": "${add(coalesce(storage.count, 0), 1)}" },
    "cached": { "value": "${sources.data}", "ttlSec": 300 }
  }
}
```

활용 예: 방문 카운터(`visit-counter`), "지난번 이후 변화" 델타(`downloads-new`),
비싼 결과 캐시(TTL), 마지막 정상 값 보존 등.

## forEach 템플릿

`children` 또는 `items`는 배열 대신 `forEach` 템플릿 객체가 될 수 있다.

```json
{
  "type": "list",
  "items": {
    "forEach": "$.transforms.visible",
    "as": "file",
    "template": {
      "type": "hstack",
      "id": "file-${file.id}",
      "drag": { "filePath": "${file.path}" },
      "children": [
        {
          "type": "image",
          "source": { "kind": "fileIcon", "path": "${file.path}" },
          "size": 22
        },
        {
          "type": "text",
          "text": "${file.name}",
          "role": "body",
          "lineLimit": 1,
          "truncation": "middle"
        }
      ]
    }
  }
}
```

`as` 변수는 template 내부에서만 유효하다. 위 예제의 `${file.path}`는 각 item의 `path` 필드다.

## 조건부 switch

`children`/`items`/`view` 자리에 `switch` 객체를 두면 셀렉터 값으로 서브트리를
고른다. **선택된 가지만 확장**되므로(불필요한 `forEach`는 실행되지 않는다),
설정으로 레이아웃을 바꾸는 뷰모드 토글 등에 쓴다.

```json
{
  "switch": "${settings.viewMode}",
  "cases": {
    "List": { "type": "list", "items": { "forEach": "...", "as": "f", "template": {} } }
  },
  "default": { "type": "grid", "items": { "forEach": "...", "as": "f", "template": {} } }
}
```

셀렉터가 `cases`의 키와 일치하면 그 노드를, 없으면 `default`를(그것도 없으면
빈 `spacer`를) 확장한다. `if()` 함수와 달리 미선택 가지는 평가되지 않는다.

## 파일 노드

파일 아이콘과 썸네일은 호스트 썸네일 서비스가 해석한다.

```json
{
  "type": "image",
  "source": {
    "kind": "fileThumbnail",
    "path": "${file.path}",
    "modifiedAt": "${file.modifiedAt}"
  },
  "fallback": {
    "kind": "fileIcon",
    "path": "${file.path}"
  },
  "size": { "width": 72, "height": 54 }
}
```

노드에 `drag: { "filePath": "..." }`를 붙이면 해당 뷰는 Finder나 다른 앱으로 drag-out할 수 있다. 버튼, row, tile 등 사용자가 잡는 최상위 반복 노드에 붙이는 것을 권장한다.

## Recent Files 워크스루

번들 예제는 [`widgets/recent-files/widget.json`](../widgets/recent-files/widget.json)과 [`widgets/recent-files/workflow.json`](../widgets/recent-files/workflow.json)에 있다. manifest는 `entry: { "kind": "workflow", "main": "workflow.json" }`를 선언하고, settings로 `folder`와 `limit`를 제공한다.

현재 `workflow.json`의 핵심 구조:

```json
{
  "schemaVersion": 1,
  "kind": "workflow",
  "sources": {
    "files": {
      "use": "fs.directory",
      "with": {
        "path": "${settings.folder}",
        "watch": true,
        "skipHidden": true,
        "sortBy": "modifiedAt",
        "sortDirection": "descending",
        "limit": "${settings.limit}"
      }
    }
  },
  "transforms": {
    "visible": { "use": "assign", "from": "$.sources.files.items" }
  },
  "view": {
    "type": "vstack",
    "spacing": 0,
    "children": [
      {
        "type": "hstack",
        "spacing": 8,
        "padding": 10,
        "children": [
          { "type": "image", "source": { "kind": "sfSymbol", "name": "folder.fill" }, "size": 15, "tint": "secondary" },
          { "type": "text", "text": "${file.basename(settings.folder)}", "role": "title", "lineLimit": 1 },
          { "type": "spacer" },
          { "type": "text", "text": "${count(transforms.visible)} items", "role": "caption" }
        ]
      },
      { "type": "divider" },
      {
        "type": "list",
        "spacing": 2,
        "items": {
          "forEach": "$.transforms.visible",
          "as": "file",
          "template": {
            "type": "hstack",
            "id": "file-${file.path}",
            "spacing": 8,
            "padding": 6,
            "drag": { "filePath": "${file.path}" },
            "action": { "type": "openFile", "path": "${file.path}" },
            "children": [
              {
                "type": "image",
                "source": { "kind": "fileThumbnail", "path": "${file.path}", "modifiedAt": "${file.modifiedAt}" },
                "size": 28
              },
              {
                "type": "vstack",
                "spacing": 2,
                "widthFill": true,
                "children": [
                  { "type": "text", "text": "${file.name}", "role": "body", "lineLimit": 1 },
                  { "type": "text", "text": "${date.relative(file.modifiedAt)}", "role": "caption", "foreground": "tertiary" }
                ]
              },
              {
                "type": "button",
                "icon": "magnifyingglass",
                "action": { "type": "revealFile", "path": "${file.path}" }
              }
            ]
          }
        }
      }
    ]
  },
  "empty": {
    "type": "empty",
    "icon": "tray",
    "title": "No files",
    "subtitle": "Choose another folder in widget settings."
  },
  "status": {
    "tooltip": "Recent files: ${count(transforms.visible)} items"
  }
}
```

실행 흐름:

1. 호스트가 `settings.folder`와 `settings.limit`를 보간하고 `fs.directory` source를 실행한다.
2. `watch: true`이면 같은 경로를 FSEvents 감시에 연결한다.
3. source 결과의 `items`가 `transforms.visible`에 바인딩된다.
4. `view`의 문자열 보간과 `forEach`가 평가되어 UINode 트리가 생성된다.
5. `fileThumbnail`은 렌더러가 비동기로 해석하고, 실패하면 파일 아이콘 계열 렌더링으로 대체될 수 있다.
6. `drag.filePath`가 있는 row는 Finder나 다른 앱으로 drag-out할 수 있다.
7. `revealFile` 액션은 Finder에서 파일을 표시한다.
8. `status.tooltip`은 메뉴바 status item tooltip에 사용된다.

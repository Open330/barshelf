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
| `system` | `metrics`, `detail`, `sensors`, `io`, `mount`, `interface` | CPU/메모리/디스크/센서/네트워크 측정값 |
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
      "with": { "metrics": ["cpu", "memory", "disk", "sensors", "network"], "detail": false, "mount": "/" }
    }
  }
}
```

| `with` 필드 | 설명 |
| --- | --- |
| `metrics` | 읽을 그룹 배열: `cpu`, `memory`, `disk`, `sensors`, `network`. 생략하면 위젯이 허가받은 전부. |
| `detail` | `true`면 `cpu.cores[]`와 `sensors.list[]`까지 채운다. 기본 샘플의 약 3배 비용. |
| `sensors` | 이 위젯이 실제로 보여주는 센서 판독값. 읽을 온도 키를 그만큼만 좁힌다. |
| `io` | `true`면 `disk.read`/`disk.write`(bytes/s)도 채운다. 저장장치 드라이버를 도는 IOKit 레지스트리 조회라, 실제로 보여줄 때만 켠다. 기본 `false`. |
| `mount` | `disk` 그룹이 볼 마운트 포인트. 기본 `"/"`. |
| `interface` | `network` 그룹이 볼 인터페이스. 생략하거나 `all`이면 물리 인터페이스를 합산한다. |

### 센서 샘플 좁히기

SMC 키는 하나하나가 별도의 IOKit 왕복(약 0.16 ms)이고, Mac이 공개하는 키는
위젯 하나가 보여주는 것보다 훨씬 많다. Apple Silicon 노트북 기준 요약 대상만
46개이고 그중 23개가 GPU다. 메뉴바에 CPU 온도 하나를 띄우는 위젯에게 나머지
28개는 쓸모가 없다.

`sensors`에 실제로 표시하는 판독값 이름을 적으면 그만큼만 읽는다. 값 하나
또는 배열을 받는다.

| 값 | 읽는 것 |
| --- | --- |
| `cpu` / `gpu` / `battery` | 해당 컴포넌트의 온도 키만(`cpuMax` 등도 이 그룹에서 나온다). |
| `key:<KEY>` | 그 센서 하나만, 따로 읽어 `sensors.picked`에 담는다. 온도 그룹은 읽지 않는다. |
| `power` / `fan` / `fanUsage` / `none` | 온도는 전혀 읽지 않는다(팬·전력은 자기 키에서 온다). |
| `peak` / `all` / `list` / 생략 / **모르는 이름** | 전부. |

모르는 이름이 전부로 떨어지는 것은 의도된 설계다. 호스트가 해석하지 못한
힌트 때문에 판독값이 조용히 비는 일은 없어야 한다 — 느려질 수는 있어도
틀려서는 안 된다.

`key:<KEY>`의 KEY는 `sensors.list[].key`에 나오는 값 그대로다(SMC 키, 또는
SMC 온도가 없는 Mac에서는 HID 센서 이름). 접두사는 정확히 소문자 `key:`여야
한다. 배열 안의 `key:` 항목은 순서대로 최대 8개까지 읽어 `sensors.pickedList`에
키마다 한 칸씩 담고, 이 Mac에 없는 키의 칸은 `null`이다 — 그래서 두 번째로
요청한 센서는 앞의 키가 없어도 늘 `pickedList.1`이다. 첫 칸은 인덱스 없이
`sensors.picked`로도 읽을 수 있다.

`peak`은 *그 샘플이 실제로 읽은* 센서 중 최고값이다. 그룹을 좁힌 위젯은
자기가 요청한 범위의 최고값을 받는다. `detail: true`는 카드의 전체 목록이
목적이므로 `sensors`보다 우선해 모든 그룹을 읽는다.

번들 Sensors 위젯이 이 패턴을 쓴다.

```json
"with": {
  "metrics": ["sensors"],
  "detail": "${coalesce(widget.visible, true)}",
  "sensors": [
    "${if(coalesce(widget.visible, true), 'all', coalesce(settings.menuBarSensor, 'cpu'))}",
    "${coalesce(settings.menuBarSensor, 'cpu')}",
    "${coalesce(settings.menuBarSecondary, 'none')}"
  ]
}
```

첫 항목이 그룹을 정하고, 뒤의 두 항목은 사용자가 고른 판독값이 `key:`일 때
그 센서를 읽게 한다(`all`이 섞인 배열도 `key:` 항목은 그대로 읽는다).

카드가 닫혀 있으면 메뉴바가 보여주는 판독값 하나만 읽고, 열리면 전부 읽는다.
이 한 쌍이 리프레시 한 번을 약 27 ms에서 약 4 ms로 줄인다. `coalesce` 기본값은
`widget.visible`을 모르는 구버전 호스트에서도 위젯이 정상 동작하게 한다 —
거기서는 늘 그랬듯 전부 샘플링한다.

출력 규약: **퍼센트는 0~100**, 바이트는 바이트, 온도는 °C, 그리고 이 머신이
제공하지 않는 값은 0이 아니라 `null`이다.

| 경로 | 설명 |
| --- | --- |
| `cpu.usage` / `.user` / `.system` / `.nice` / `.idle` | 직전 샘플 이후 구간의 CPU 점유율. |
| `cpu.coreCount`, `cpu.loadAverage.{1m,5m,15m}` | 코어 수와 load average. |
| `cpu.cores[]` | 코어별 `usage`. `detail: true`일 때만. |
| `cpu.coreMax` | 가장 바쁜 코어의 `usage`. 단일 스레드 작업이 전체 평균에 묻히지 않게. `detail` 없이도 채우고, 틱 카운터를 못 읽은 샘플에서만 `null`. |
| `memory.{total,used,free,app,wired,compressed,cached,usage}` | Activity Monitor의 "사용 중 메모리"와 같은 계산식(app + wired + compressed). |
| `memory.pressure` | `"normal"` \| `"warning"` \| `"critical"` \| `"unknown"`. |
| `memory.swap.{total,used,free,usage}` | 스왑. |
| `disk.{mount,total,used,free,usage}` | `df`와 같은 기준(예약 블록은 used로 계산). |
| `disk.{read,write}` | 모든 저장장치(마운트한 디스크 이미지는 제외 — 호스트 디스크와 이중 집계되므로)의 읽기/쓰기 bytes/s. `io: true`일 때만, 첫 샘플은 `null`. |
| `network.{available,interface,download,upload,received,sent,address}` | 네트워크 카운터. `download`/`upload`은 bytes/s이고 첫 샘플은 이전 카운터가 없어 `null`이다. `received`/`sent`는 누적 bytes, `address`는 로컬 주소다. |
| `sensors.available` | 어떤 센서도 읽지 못하면 `false`. 샌드박스 빌드와 VM이 여기 해당한다. |
| `sensors.{cpu,gpu,battery,peak}` | °C. CPU는 코어 다이 센서들의 평균, `peak`은 요약 센서 중 최고값. |
| `sensors.{cpuMax,gpuMax,batteryMax}` | °C. 각 컴포넌트에서 가장 뜨거운 센서. 평균 대신 최악의 코어를 보여줄 때. |
| `sensors.picked`, `sensors.pickedList[]` | `{key, name, kind, value, unit}`. `sensors`에 `key:<KEY>`로 요청한 센서들(요청 순서, 키마다 한 칸, 없는 센서는 `null`), `picked`는 첫 칸. |
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
| widget | `${widget.size}` (현재 카드 크기 `XS`/`S`/`M`/`L` — 크기별 뷰 분기용), `${widget.visible}` (아래) |
| forEach 변수 | `${file.path}`, `${file.name}` |

표현식의 리터럴은 숫자(`42`, `-1`), 문자열(`'ok'` 또는 `"ok"`), `true`/`false`/`null`을 지원한다.
문자열 리터럴 덕분에 `eq(status, 'success')`처럼 상수와 비교할 수 있다.

### `widget.visible` — 아무도 안 볼 때는 덜 하기

`${widget.visible}`은 **지금 이 위젯의 카드가 화면에 있는지**를 알려준다.
셸프가 열려 있고 이 위젯의 페이지가 보이거나, 이 위젯이 자기 메뉴바 항목의
팝오버로 떠 있으면 `true`다.

메뉴바에 올린 위젯은 셸프가 닫혀 있어도 계속 리프레시한다. 그동안 카드에만
쓰이는 데이터를 모으는 것은 전부 낭비다. 소스 파라미터에서 읽으면 애초에
가져오지 않을 수 있다.

```json
"with": { "metrics": ["sensors"], "detail": "${widget.visible}" }
```

호스트는 워크플로가 이 값을 읽는지 보고 있다가, 카드가 열리는 순간 다시
평가한다. 다음 tick까지 싼 결과를 보여주고 있지 않는다.

구버전 호스트에는 `widget.visible`이 아예 없다(`null`). 위젯을 레지스트리로
배포한다면 `coalesce(widget.visible, true)`로 감싸라 — 거기서는 늘 그랬듯
전부 하는 쪽으로 떨어진다.

지원 내장 함수는 다음과 같다. **0.3.11+** 표시가 있는 함수를 쓰는 위젯은
`widget.json`에 `"minHostVersion": "0.3.11"`을 선언해야 한다 — 그보다 오래된
BarShelf에는 그 함수가 없어 워크플로 평가가 "unknown function" 오류로 실패하고
위젯이 오류 카드가 된다. 선언하면 0.3.11 이상 호스트가 더 낮은 버전에서의
설치·실행을 막고 "업데이트하라"고 알려 준다(0.3.11 이전 호스트는 이 필드 자체를
모르므로, 번들 위젯처럼 앱과 함께 배포되는 경로가 가장 안전하다).

| 함수 | 설명 |
| --- | --- |
| `now()` | 현재 시각을 Unix epoch milliseconds로 반환한다. |
| `count(list)` | 목록 길이를 반환한다. |
| `date.relative(ms)` | epoch milliseconds를 상대 시간 텍스트로 변환한다. |
| `file.basename(path)` / `file.extension(path)` | 경로의 파일명 / 확장자. |
| `text.truncate(s,n)` | 문자열을 최대 길이로 줄인다. |
| `concat(a,b,...)` | 인자들의 문자열 표현을 이어붙인다. `${}` **안에서** 문자열을 만드는 유일한 방법이라 `if(...)`의 각 가지에 단위를 붙일 때 쓴다. |
| `coalesce(a,b,...)` | 첫 번째 non-null·non-empty 값을 반환한다(그 뒤는 평가하지 않는다). |
| `default(v, fallback)` | `v`가 falsy면 `fallback`. |
| `if(cond, a, b)` | `cond`가 truthy면 `a`, 아니면 `b`. 고른 가지만 평가한다. |
| `switch(v, c1, r1, c2, r2, …, fallback)` | `v`와 같은 첫 `c`의 짝 `r`, 없으면 `fallback`(없으면 `null`). 설정으로 여러 판독값 중 하나를 고를 때 `if` 중첩 대신 쓴다. 일치한 결과만 평가한다. **BarShelf 0.3.11+** |
| `get(obj, key)` | 실행 시에 정해지는 키로 필드를 읽는다. 배열이면 숫자 인덱스. 없으면 `null`. 예: `get(sources.data.sensors, settings.pick)`. **BarShelf 0.3.11+** |
| `not`, `and`, `or` | 불리언 로직. `and`/`or`는 결과가 정해지면 나머지를 평가하지 않는다. falsy: `null`·`false`·`0`·`""`·빈 배열·빈 객체. |
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

  `enum`에 `"optionsSource": "system.sensors"`를 주면 호스트가 이 Mac에서 읽을
  수 있는 센서 전부를 `options` 뒤에 붙인다. 저장되는 값은 `key:<KEY>`이고,
  이 값을 그대로 `system` 소스의 `sensors`에 넘기면 그 센서 하나만 읽는다.
  다른 Mac에서 고른 센서가 이 Mac에 없으면 피커가 "(not on this Mac)"로 보여준다.
  이 이름을 모르는 호스트는 `options`만 보여준다.

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

`status.metrics`는 관련 있는 두 측정값을 하나의 메뉴바 항목에 담는 일반 형식이다.
각 항목은 `{ "label", "value", "tint"?, "active"?, "accessibilityLabel"? }`이며,
문자열과 `active`는 같은 템플릿 컨텍스트에서 평가된다. label/value는 생략하면 빈
문자열이고, 빈 값이라도 `active: true`면 활동 점으로 남는다. 디스크 read/write처럼
어느 한 위젯에 묶이지 않는 두 값을 나타낼 때 쓴다.

```json
"status": {
  "metrics": [
    { "label": "Read", "value": "${sources.disk.readRate}", "tint": "accent",
      "active": "${gt(number(sources.disk.readRate), 0)}", "accessibilityLabel": "Disk read ${sources.disk.readRate}" },
    { "label": "Write", "value": "${sources.disk.writeRate}", "tint": "warning",
      "active": "${gt(number(sources.disk.writeRate), 0)}", "accessibilityLabel": "Disk write ${sources.disk.writeRate}" }
  ]
}
```

`statusItem.style: "metrics"`로 이 두 metric을 전용 menu-bar item에 표시한다.
시각적으로 값을 숨길 때도 `accessibilityLabel`에는 충분한 설명을 제공해야 한다.

숫자를 문자열로 미리 조립할 필요는 없다. metric에 안정적인 `id`, `number`,
`format`, `unit`, `precision`을 주면 host가 같은 규칙으로 포맷한다. `percent`는
0–100, `bytes`/`bytesPerSecond`는 SI 1000 단위이며 `number: null`은 알 수 없는
값으로 표시한다. CPU/RAM/Power는 다음처럼 같은 일반 형식을 쓴다.

```json
"status": {
  "metrics": [
    { "id": "cpu", "label": "CPU", "number": "${sources.data.cpu.usage}", "format": "percent", "precision": 0 },
    { "id": "ram", "label": "RAM", "number": "${sources.data.memory.used}", "format": "bytes", "precision": 1 }
  ],
  "presentation": { "showValues": true, "showUnits": true, "metricOrder": ["cpu", "ram"] }
}
```

Power uses `{"id":"power","number":"${sources.data.sensors.power}","unit":"W","precision":0}` —
menu bar readings are whole numbers; the person can raise Decimals per item.
`presentation` may make `showValues`, `showUnits`, `precision`, `valueWidth` and
`digits` dynamic templates; `color`, `width`, `alignment`, `numberAlignment`, `weight` and `size` may be
templates too (an unknown value reads as unset). `metricOrder` and `metricOverrides`
are literal stable-id settings. User choices override render values, which override
the manifest's `statusItem.presentation` defaults.

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
빈 `spacer`를) 확장한다. 미선택 가지는 평가되지 않는다.

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

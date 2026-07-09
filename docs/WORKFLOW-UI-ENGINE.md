# BarShelf Workflow UI Engine

BarShelf의 큰 UI 엔진은 기존 `workflow.json` 런타임을 버리는 방향이 아니라, 그 위에 시각적 authoring layer를 얹는 방향으로 단계적으로 간다. 핵심 원칙은 간단하다: 사용자는 노드와 컴포넌트로 만들고, 호스트는 검증 가능한 `WorkflowDefinition`과 `UINode`만 실행한다.

## Phase 1: Graph Core

목표는 Builder 내부에 `WorkflowGraph` 모델을 추가하고, 이를 현재 런타임 계약인 `WorkflowDefinition`으로 컴파일하는 것이다.

- `source`, `transform`, `display` 노드를 보존한다.
- edge는 데이터 흐름을 표현한다.
- transform의 `from`이 비어 있으면 단일 incoming edge에서 자동 추론한다.
- 결과물은 기존 `workflow.json`이므로 현재 위젯 실행, 권한, 검증 경로를 그대로 쓴다.

이 단계는 캔버스 UI 없이도 테스트 가능해야 한다. 즉, 노드 모델을 저장하고 컴파일한 뒤 `WorkflowEngine.evaluate`까지 통과해야 한다.

## Phase 2: Builder Canvas

Builder는 지금의 폼 중심 생성기를 유지하면서, 고급 모드에서 그래프 캔버스를 제공한다.

- Source 노드: Command, HTTP JSON, Paste JSON, Folder, Text.
- Transform 노드: Assign, Filter, Sort, Limit.
- Display 노드: List, Table, Value, Text, Media Row, Meter, Stat Card.
- 노드 inspector에서 각 노드의 `with`, display template, preview data를 수정한다.

초기 UX는 "폼으로 시작 -> Graph로 전환"이 좋다. 초보자는 단순 workflow를 만들고, 고급 사용자는 같은 결과를 노드로 확장한다.

## Phase 3: Postprocess And Storage

데이터 gather 이후 postprocess를 명시 노드로 분리한다.

- Map/Select, Join, Group, Aggregate, Threshold, Format Date/Bytes/Percent.
- Per-widget temporary KV storage.
- Per-widget SQLite table storage.
- Redis-compatible local adapter는 이후 옵션으로 둔다.

storage는 manifest 권한으로 명시한다. 기본은 위젯 전용 sandbox 저장소이며, 외부 Redis/SQLite 파일에 직접 접근하는 모델은 권한과 UX가 명확해진 뒤 도입한다.

## Phase 4: UI Component Blocks

현대적인 위젯 표현력을 위해 UINode 위에 reusable block catalog를 둔다.

- Stat card, health meter, sparkline, segmented summary, branded account row.
- File/media tile, compact table, timeline, key-value group.
- 색상, 밀도, 아이콘, accent, threshold를 schema로 제어한다.

Script SDK도 같은 block catalog를 쓰게 해서 script 위젯과 workflow 위젯의 시각적 격차를 줄인다.

## Phase 5: Gallery And Shareable Templates

Gallery는 완성된 widget bundle뿐 아니라 graph template도 다룬다.

- "GitHub release watcher", "Battery health", "Top process", "API status"처럼 데이터 흐름이 보이는 템플릿을 제공한다.
- 템플릿은 sample data와 preview state를 포함한다.
- Export/Import는 `widget.json`, `workflow.json`, `workflow.graph.json`을 함께 다룬다.

## Current Contract

Phase 1의 구현 기준은 다음과 같다.

```json
{
  "schemaVersion": 1,
  "nodes": [
    { "id": "data", "operation": { "type": "source", "use": "value", "with": [{ "name": "Build" }] } },
    { "id": "top", "operation": { "type": "transform", "use": "limit", "with": { "count": 1 } } },
    { "id": "view", "operation": { "type": "display" } }
  ],
  "edges": [
    { "from": "data", "to": "top" }
  ],
  "view": {
    "type": "list",
    "items": {
      "forEach": "$.transforms.top",
      "as": "row",
      "template": { "type": "text", "text": "${row.name}" }
    }
  }
}
```

컴파일 결과는 기존 workflow와 같다.

```json
{
  "schemaVersion": 1,
  "kind": "workflow",
  "sources": {
    "data": { "use": "value", "with": [{ "name": "Build" }] }
  },
  "transforms": {
    "top": { "use": "limit", "from": "$.sources.data", "with": { "count": 1 } }
  },
  "view": {
    "type": "list",
    "items": {
      "forEach": "$.transforms.top",
      "as": "row",
      "template": { "type": "text", "text": "${row.name}" }
    }
  }
}
```

이 방식이면 UI 엔진을 키우더라도 런타임 실행 모델은 계속 작고 검증 가능하게 유지된다.

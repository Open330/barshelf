# 위젯 배포하기

이 문서는 MenuBucket 위젯 제작자가 GitHub 저장소, `.zip`, `.mbw` 아카이브로 위젯을 배포할 때 따라야 할 구조와 체크리스트를 정리한다.

관련 문서:

- 사용자 설치 가이드: [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)
- manifest 스펙: [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)
- workflow DSL: [`docs/WORKFLOW.md`](WORKFLOW.md)
- script 런타임: [`docs/SCRIPT-RUNTIME.md`](SCRIPT-RUNTIME.md)
- mbk CLI 레퍼런스: [`docs/MBK.md`](MBK.md)
- 레지스트리 운영 규약: [`docs/REGISTRY.md`](REGISTRY.md)

## mbk로 만들기 → 검증 → 패키징

`mbk` CLI를 쓰면 템플릿 생성부터 `.mbw` 패키징까지 배포 준비를 터미널에서 끝낼 수 있다. 전체 레퍼런스는 [`docs/MBK.md`](MBK.md)에 있다.

```bash
# 1. 템플릿에서 시작 (--kind exec|workflow|script, 기본 exec)
mbk new my-clock

# 2. manifest 검증 — 오류는 파일:필드 단위로 출력된다
mbk validate ./my-clock

# 3. .mbw 아카이브 생성 (widget.json의 sha256을 manifest.sha256으로 포함)
mbk pack ./my-clock -o my-clock.mbw

# 4. pack 결과물도 그대로 검증할 수 있다
mbk validate my-clock.mbw
```

`mbk new`는 생성 직후 `mbk validate`를 자동 실행하므로 템플릿 상태에서 항상 green으로 시작한다. 만들어진 `.mbw` 파일은 GitHub Release 자산 등 임의의 URL에 올려 배포할 수 있고, 사용자는 그 URL을 앱 또는 `mbk install <url>`로 설치한다.

## 저장소 구조

MenuBucket 설치기는 아카이브 안에서 `widget.json`을 포함한 모든 디렉터리를 후보로 찾는다. 단일 위젯 저장소는 루트에 `widget.json`을 둘 수 있다.

```text
my-clock-widget/
  widget.json
  clock.sh
  README.md
```

여러 위젯을 한 저장소에서 배포하려면 `widgets/` 아래에 위젯별 디렉터리를 둔다.

```text
menubucket-widgets/
  README.md
  widgets/
    clock/
      widget.json
      clock.sh
    files/
      widget.json
      workflow.json
```

GitHub URL이 `/tree/{branch}/{subdir}` 형식이면 설치기는 그 `subdir` 안에서만 `widget.json`을 찾는다.

## manifest 필수값

모든 위젯 디렉터리는 `widget.json`을 가져야 한다. `id`와 `schemaVersion`은 URL 설치 후보 검증의 필수 필드다.

```json
{
  "$schema": "https://menubucket.dev/schema/widget-0.1.json",
  "schemaVersion": 1,
  "id": "dev.example.clock",
  "name": "Clock",
  "version": "0.1.0",
  "icon": "clock",
  "bucket": { "group": "Demo", "order": 10, "size": "S" },
  "entry": { "kind": "exec" },
  "source": {
    "kind": "exec",
    "command": ["./clock.sh"],
    "timeoutMs": 5000,
    "output": "viewtree"
  },
  "refresh": { "onOpen": true, "interval": 60, "staleAfterSec": 60 },
  "permissions": {
    "exec": [
      {
        "command": "./clock.sh",
        "allowedArgs": [[]],
        "maxOutputBytes": 65536,
        "sensitiveOutput": false
      }
    ],
    "network": [],
    "readPaths": [],
    "env": [],
    "keychain": false
  },
  "settings": []
}
```

스키마 파일은 [`schema/widget-0.1.json`](../schema/widget-0.1.json), UINode 출력 스키마는 [`schema/uinode-0.1.json`](../schema/uinode-0.1.json), workflow 스키마는 [`schema/workflow-0.1.json`](../schema/workflow-0.1.json)에 있다.

## README 설치 스니펫

위젯 README에는 딥링크 버튼과 CLI 명령을 같이 넣는 것을 권장한다. 딥링크의 `url` 값은 percent-encoded URL이어야 한다.

````markdown
[![MenuBucket 설치](https://img.shields.io/badge/MenuBucket-Install-0A84FF)](menubucket://install?url=https%3A%2F%2Fgithub.com%2Fexample%2Fmenubucket-widgets)

CLI 설치:

```bash
MenuBucket.app/Contents/MacOS/menubucket install https://github.com/example/menubucket-widgets
```
````

특정 하위 디렉터리를 설치하게 하려면 원본 URL과 딥링크 URL 모두 `/tree/{branch}/{subdir}`를 가리키게 한다.

```markdown
[![MenuBucket 설치](https://img.shields.io/badge/MenuBucket-Install-0A84FF)](menubucket://install?url=https%3A%2F%2Fgithub.com%2Fexample%2Fmenubucket-widgets%2Ftree%2Fmain%2Fwidgets%2Fclock)
```

## 업데이트와 권한 변경

설치 경로는 `manifest.id`로 고정된다.

```text
~/Library/Application Support/menubucket/widgets/<manifest.id>/
```

같은 `manifest.id`를 다시 설치하면 업데이트로 처리된다. `version`은 사용자에게 변경을 설명하는 표시값으로 쓰이므로 릴리스마다 올리는 것을 권장한다.

권한 선언이 바뀌면 기존 승인 상태가 유지되지 않는다. MenuBucket은 `permissions`의 정규화된 JSON 해시를 저장하므로, `permissions.exec`, `permissions.keychain`, `permissions.notifications`, `permissions.env` 등이 바뀌면 첫 실행 시 다시 승인 카드가 표시된다.

URL 설치기는 권한을 자동 승인하지 않는다. 설치 확인 화면은 요구 권한을 요약하고, 실제 실행 권한은 첫 실행 승인 카드가 게이트한다.

## 배포 전 체크리스트

- `widget.json`에 `schemaVersion: 1`과 안정적인 `id`가 있다.
- `id`는 한번 배포한 뒤 바꾸지 않는다.
- exec 위젯은 `source.command`와 `permissions.exec[].command`/`allowedArgs`가 일치한다.
- 스크립트 파일은 위젯 디렉터리 기준 상대 경로로 실행된다. 예: `["./clock.sh"]`.
- `permissions.keychain: true`는 실제 secret 접근이 필요한 위젯에만 둔다.
- `permissions.notifications: true`는 실제 알림을 보내는 위젯에만 둔다.
- 민감한 stdout은 `permissions.exec[].sensitiveOutput: true`로 선언한다.
- `.zip` 또는 `.mbw` 아카이브는 128MB 다운로드 제한과 256MB 추출 제한 안에 들어간다.
- 아카이브 안에 심볼릭 링크나 `../` 경로 탈출 entry를 넣지 않는다.
- 루트 또는 의도한 하위 디렉터리에서 `widget.json`을 찾을 수 있다.
- README에 딥링크와 CLI 설치 명령을 모두 제공한다.
- `mbk validate <위젯 디렉터리>`(또는 pack한 `.mbw`)가 통과한다.

## 레지스트리에 등재하기

위젯을 URL로 설치 가능하게 배포했다면, 공식 레지스트리에 등재해 앱의 위젯 갤러리에 노출할 수 있다. 레지스트리는 배포 규약 위의 큐레이션 레이어이며, 등재는 선택 사항이다 — 등재하지 않아도 URL 설치는 항상 동작한다.

절차 요약:

1. `mbk validate <위젯 디렉터리>`가 통과하고, 위 배포 전 체크리스트를 만족하는지 확인한다.
2. 레지스트리 저장소의 `registry/index.json`에 entry를 추가하는 PR을 올린다. `id`는 `widget.json`의 `manifest.id`와 정확히 일치해야 하며, `install.url`은 이 문서의 설치 URL 형식([`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md))을 그대로 쓴다.

```jsonc
{
  "id": "dev.example.clock",                    // manifest.id와 일치
  "name": "Clock",
  "description": "간단한 시계 위젯",
  "version": "0.1.0",
  "author": "example",
  "icon": "clock",                              // SF Symbol
  "kind": "exec",                               // exec | workflow | script
  "tags": ["time"],
  "install": { "url": "https://github.com/example/menubucket-widgets/tree/main/widgets/clock" },
  "permissions": { "exec": ["./clock.sh"], "keychain": false, "notifications": false },
  "homepage": "https://github.com/example/menubucket-widgets"
}
```

3. `permissions` 요약은 **표시용**이다. 갤러리 카드에서 사용자에게 위험도를 알리는 신뢰 UX이며, 실제 권한 게이트는 설치 후 첫 실행 승인 카드다. 요약은 manifest 선언과 일치해야 한다.

entry 필드 표, 검증 규칙, 큐레이션 기준(권한 최소화·README 필수 등), PR 리뷰 절차, `MENUBUCKET_REGISTRY`를 이용한 셀프호스팅은 [`docs/REGISTRY.md`](REGISTRY.md)에, JSON Schema는 [`schema/registry-0.1.json`](../schema/registry-0.1.json)에 있다.

## 로컬 검증

개발 중에는 저장소의 `widgets/` 아래에 위젯을 두고 앱을 실행하면 hot reload로 빠르게 확인할 수 있다.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build_app.sh
open dist/MenuBucket.app
```

사용자 설치 경로까지 확인하려면 위젯 디렉터리를 `~/Library/Application Support/menubucket/widgets/<manifest.id>/`로 복사한다. 같은 `manifest.id`가 `./widgets/`에도 있으면 개발 디렉터리가 우선한다.

# mbk CLI 레퍼런스

`mbk`는 BarShelf 위젯을 만들고, 검증하고, 패키징하고, 설치하는 독립 CLI다. GUI 앱 없이 동작하며(순수 CLI), 앱과 같은 Core 디코더·설치 파이프라인을 사용한다.

관련 문서:

- 설치 URL 계약: [`docs/INSTALLING-WIDGETS.md`](INSTALLING-WIDGETS.md)
- 배포 워크플로: [`docs/PUBLISHING.md`](PUBLISHING.md)
- 레지스트리 등재: [`docs/REGISTRY.md`](REGISTRY.md)
- manifest 스펙: [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)

## 서브커맨드 요약

```
mbk install <src>                  # GitHub URL / 로컬 위젯 디렉토리 / .zip·.mbw(경로·URL) / 딥링크
mbk new <name> [--kind exec|workflow|script] [--dir <path>]   # 기본 kind=exec, 기본 dir=./<name>
mbk validate <path>                # widget.json(+workflow.json 있으면) Core 디코더로 검증, 오류를 파일:필드 단위로 출력
mbk pack <dir> [-o <name>.mbw]     # zip(.mbw) 생성 + 아카이브에 manifest.sha256 포함(widget.json의 sha256)
mbk list                           # 설치된 위젯 나열 (id, name, version, kind)
mbk --version / --help
```

| 커맨드 | 인자/옵션 | 동작 |
| --- | --- | --- |
| `mbk install <src>` | GitHub 저장소 URL, **로컬 위젯 디렉토리**, `.zip`/`.mbw`(로컬 경로 또는 URL), `barshelf://install?...` 딥링크 | R05 URL 설치 계약 그대로 다운로드→추출→탐색→설치. 다이얼로그 없이 권한 요약을 stdout에 출력하고, `--yes`가 없으면 stdin 확인 프롬프트를 띄운다. 파이프 등 비인터랙티브 환경이면 자동 진행하고 요약을 출력한다. |
| `mbk new <name>` | `--kind exec\|workflow\|script` (기본 `exec`), `--dir <path>` (기본 `./<name>`) | 템플릿에서 새 위젯 디렉터리를 생성하고, 생성 직후 `mbk validate`를 자동 실행해 green 확인 메시지를 출력한다. |
| `mbk validate <path>` | 위젯 디렉터리 또는 pack된 `.mbw` 파일 | `widget.json`(그리고 `workflow.json`이 있으면 함께)을 Core 디코더로 검증하고, 오류를 파일:필드 단위로 출력한다. `.mbw`를 받으면 안전 추출 후 검증한다. |
| `mbk pack <dir>` | `-o <name>.mbw` (출력 파일명) | 위젯 디렉터리를 zip(`.mbw`)으로 패키징하고, 아카이브에 `manifest.sha256`(widget.json의 sha256)을 포함한다. |
| `mbk list` | — | 설치된 위젯을 id, name, version, kind로 나열한다. |
| `mbk --version` / `mbk --help` | — | 버전/도움말 출력. |

### new 템플릿 3종

| kind | 템플릿 내용 |
| --- | --- |
| `exec` | hello식 셸 스크립트 + manifest |
| `workflow` | recent-files 축소판 (`workflow.json` 포함) |
| `script` | clock-script 축소판 (`import { mb, ui } from "barshelf"`) |

## 출력과 exit 코드

- **exit 0** 성공 / **exit 1** 실패.
- 출력은 사람이 읽는 평문이다(컬러 불필요).
- 오류는 **stderr**로 출력된다.

## 예제 세션

새 위젯을 만들고 검증·패키징해 설치까지 확인하는 흐름:

```bash
# 1. 새 exec 위젯 생성 (생성 직후 validate가 자동 실행된다)
$ mbk new my-clock
Created widget at ./my-clock (kind: exec)
Validating ./my-clock ... OK

# 2. 수정 후 재검증 — 오류는 파일:필드 단위로 출력된다
$ mbk validate ./my-clock
my-clock/widget.json: refresh.interval: expected number, found string
$ echo $?
1

# 3. 고치고 다시 검증
$ mbk validate ./my-clock
OK

# 4. .mbw 아카이브로 패키징
$ mbk pack ./my-clock -o my-clock.mbw
Packed my-clock.mbw (manifest.sha256 included)

# 5. pack된 .mbw도 validate로 검증할 수 있다
$ mbk validate my-clock.mbw
OK

# 6. URL 또는 로컬 아카이브로 설치 — 권한 요약을 보여주고 확인을 받는다
$ mbk install https://github.com/example/barshelf-widgets/tree/main/widgets/clock
Widget: Clock (dev.example.clock) 0.1.0
Permissions: exec ./clock.sh
Install? [y/N] y
Installed to ~/Library/Application Support/barshelf/widgets/dev.example.clock

# 비인터랙티브(파이프/CI)에서는 자동 진행 + 요약 출력, 또는 --yes로 확인 생략
$ mbk install --yes https://github.com/example/barshelf-widgets

# 7. 설치된 위젯 확인
$ mbk list
dev.example.clock  Clock  0.1.0  exec
```

메시지 문구는 예시이며 릴리스에 따라 달라질 수 있다. 계약으로 보장되는 것은 서브커맨드·옵션·exit 코드·stderr 오류 출력이다.

## 앱 CLI와의 관계

기존 앱 바이너리의 `BarShelf.app/Contents/MacOS/barshelf install <url>` 인자 모드는 그대로 유지된다. `mbk install`은 같은 설치 파이프라인을 GUI 없이 사용하는 독립 실행 파일이다. 어느 쪽으로 설치해도 결과는 동일하다.

## 빌드

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product mbk
swift run mbk --help
```

앱 번들 빌드 스크립트(`scripts/build_app.sh`)는 `dist/`에 `mbk` 바이너리도 함께 복사한다.

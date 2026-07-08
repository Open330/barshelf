# 위젯 설치하기

MenuBucket의 URL 설치 v1은 GitHub 저장소, 직접 아카이브, 딥링크를 같은 설치 파이프라인으로 처리한다. 설치된 위젯은 `~/Library/Application Support/menubucket/widgets/<manifest.id>/`에 복사되고, 앱이 실행 중이면 hot reload로 자동 반영된다.

관련 문서:

- 처음 시작하기: [`docs/GETTING-STARTED.md`](GETTING-STARTED.md)
- 제작자 배포 가이드: [`docs/PUBLISHING.md`](PUBLISHING.md)
- manifest 스펙: [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)

## 지원 URL

### GitHub 저장소

저장소 전체를 설치한다.

```text
https://github.com/example/menubucket-widgets
```

특정 branch 또는 저장소 안의 하위 디렉터리만 설치할 수도 있다.

```text
https://github.com/example/menubucket-widgets/tree/main/widgets/clock
```

MenuBucket은 GitHub API를 사용하지 않고, GitHub URL을 다음 다운로드 URL로 변환한다.

```text
https://codeload.github.com/{user}/{repo}/zip/refs/heads/{branch}
```

branch가 없으면 `main`을 먼저 시도하고, 실패하면 `master`를 폴백한다. `/tree/{branch}/{subdir}` URL이면 압축 해제 후 해당 `subdir` 안에서만 위젯을 찾는다.

### 직접 아카이브

`.zip` 또는 `.mbw` 아카이브 URL을 직접 설치할 수 있다.

```text
https://example.com/menu-widgets.zip
https://example.com/clock.mbw
```

아카이브를 임시 디렉터리에 풀고, repo 루트, 서브디렉터리, 멀티 위젯 저장소를 모두 지원하기 위해 `widget.json`을 포함한 모든 디렉터리를 후보로 찾는다.

### 딥링크

웹사이트나 README 버튼은 `menubucket://install?url=<percent-encoded-url>` 형식을 사용한다.

```text
menubucket://install?url=https%3A%2F%2Fgithub.com%2Fexample%2Fmenubucket-widgets
```

앱 번들의 `Info.plist`에는 `menubucket` URL 스킴이 등록되고, `AppDelegate.application(_:open:)` 진입점이 URL을 같은 설치 흐름으로 넘긴다.

## 설치 경로

### 메뉴바에서 설치

1. 메뉴바의 MenuBucket 아이콘을 우클릭한다.
2. `Install Widget from URL...`을 선택한다.
3. GitHub URL, `.zip`, `.mbw` URL 중 하나를 붙여 넣는다.
4. 설치 확인 화면에서 위젯 이름, 버전, 요구 권한 요약을 확인하고 설치한다.

<!-- 스크린샷 자리: 메뉴바 우클릭 메뉴의 Install Widget from URL... 항목 -->
<!-- 스크린샷 자리: URL 입력 다이얼로그 -->

### 딥링크로 설치

브라우저에서 `menubucket://install?url=...` 링크를 열면 MenuBucket이 설치 확인 화면을 표시한다. 링크 안의 `url` 값은 반드시 percent-encoded URL이어야 한다.

### CLI로 설치

GUI 없이 설치하고 종료하려면 앱 번들 안의 실행 파일을 사용한다.

```bash
MenuBucket.app/Contents/MacOS/menubucket install https://github.com/example/menubucket-widgets
```

로컬 빌드 산출물에서 실행할 때는 다음처럼 경로를 붙인다.

```bash
dist/MenuBucket.app/Contents/MacOS/menubucket install https://github.com/example/menubucket-widgets
```

CLI 모드는 설치 확인 다이얼로그를 띄우지 않고 진행하며, 권한 요약을 stdout에 출력한다. 설치 성공은 exit code `0`, 실패는 exit code `1`로 종료한다. 이 명령은 향후 `mbk` CLI의 기반이다.

## 설치 중 확인하는 내용

각 후보 디렉터리는 먼저 `widget.json` manifest로 디코딩된다. `id`와 `schemaVersion`은 필수이며, 스키마는 [`schema/widget-0.1.json`](../schema/widget-0.1.json)을 따른다.

설치 확인 화면은 위젯별로 다음 정보를 보여준다.

- 위젯 이름과 버전
- exec 권한: 실행할 command와 허용 인자 패턴
- Keychain 권한: `permissions.keychain: true` 여부
- 알림 권한: `permissions.notifications: true` 여부

기존 위젯과 같은 `manifest.id`를 설치하면 새 설치가 아니라 업데이트로 표시된다. 파일은 `~/Library/Application Support/menubucket/widgets/<manifest.id>/`에 복사된다.

설치가 끝나면 완료 알림에 성공한 위젯 수와 실패 사유가 표시된다.

## 권한 승인

URL 설치는 파일을 배치할 뿐 권한을 자동 승인하지 않는다. 설치 후 첫 실행 때 MenuBucket의 기존 권한 승인 카드가 나타나며, 사용자가 승인해야 위젯이 실행된다.

manifest의 `permissions`가 바뀌면 저장된 권한 해시가 달라져 다시 승인 대기 상태가 된다. 업데이트가 같은 `manifest.id`를 유지하더라도 권한 변경은 재승인을 요구한다.

<!-- 스크린샷 자리: 권한 승인 카드의 exec/keychain/notifications 요약 -->

## 보안 제한

URL 설치 v1은 다음 제한을 적용한다.

- 다운로드 크기 제한: 128MB
- 압축 해제 후 총 크기 제한: 256MB
- zip entry의 `../` 경로 탈출 차단
- 심볼릭 링크 무시
- 자동 권한 승인 금지

## 문제 해결

### GitHub 저장소가 설치되지 않는다

branch를 지정하지 않은 URL은 `main`을 먼저 받고 실패하면 `master`를 시도한다. 저장소 기본 branch가 다른 이름이면 `/tree/{branch}` URL을 사용한다.

```text
https://github.com/example/menubucket-widgets/tree/release/widgets/clock
```

### 아카이브 안에 위젯이 여러 개 있다

정상이다. MenuBucket은 `widget.json`을 포함한 모든 디렉터리를 찾아 멀티 위젯으로 설치한다. 특정 하위 디렉터리만 설치하려면 GitHub `/tree/{branch}/{subdir}` URL을 사용한다.

### 설치는 됐지만 위젯이 실행되지 않는다

팝오버에서 해당 위젯의 권한 승인 카드를 확인한다. `Approve`를 누르기 전에는 exec, Keychain, notifications 권한이 실행되지 않는다.

### 같은 위젯을 다시 설치하면 어떻게 되나

`manifest.id`가 같으면 `~/Library/Application Support/menubucket/widgets/<manifest.id>/` 위치를 업데이트한다. 권한 선언이 같으면 기존 승인 상태가 유지되고, 권한 선언이 바뀌면 다시 승인이 필요하다.

### 개발 중인 `./widgets/`와 충돌한다

개발 모드에서는 현재 작업 디렉터리의 `./widgets/`가 사용자 설치 경로보다 먼저 로드된다. 같은 `manifest.id`가 양쪽에 있으면 `./widgets/` 쪽이 우선한다.

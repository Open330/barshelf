# BarShelf 앱 릴리스

앱 자체를 릴리스하는 절차다. **위젯** 배포는 [`PUBLISHING.md`](PUBLISHING.md)를
본다.

이 문서가 생긴 이유: 0.1.4는 `APP_VERSION`과 RELEASE_NOTES까지 준비됐지만
릴리스가 나가지 않았고, README만 "현재 v0.1.4 빌드는 서명·공증됨"이라고 몇 달
동안 광고했다. 존재하지 않는 자산을 찾게 만들었고, 그 미출시 빌드를 쓰는 사람은
업데이트 확인에서 영원히 "up to date"를 봤다. 이제
`scripts/check-release-versions.py`가 CI에서 그 어긋남을 막고, 아래 순서가 무엇을
언제 올려야 하는지를 정한다.

## 전제

- **Developer ID Application** 인증서 (`security find-identity -v -p codesigning`)
- **App Store Connect API 키** — `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8`
- Apple Silicon 호스트 (릴리스는 arm64 전용)

`scripts/release.sh`는 fail-closed다. 위 조건이 없으면 공개 릴리스를 만들지
않는다. 로컬 패키징만 필요하면
`VERSION=X.Y.Z NOTARIZE=0 ALLOW_UNNOTARIZED=1 SIGN_IDENTITY=- bash scripts/release.sh`.

## 버전 규칙

0.x 단계에서는:

- **patch** — 버그 수정, 위젯 내용 변경.
- **minor** — manifest/workflow 스키마 확장(새 권한 키, 새 source, 새 표현식
  함수), 새 UI 표면, 새 번들 위젯.

## 순서

릴리스 **전**에 올리는 것과 **후**에 올리는 것을 구분하는 게 핵심이다. 문서의
버전 문구는 *다운로드 가능한* 빌드를 가리키므로, 자산이 실제로 올라간 뒤에
바꾼다.

0. **full Xcode가 활성화돼 있어야 한다.** SwiftUI의 `@State`는 매크로이고 그
   플러그인은 Xcode에만 들어 있다. Command Line Tools만으로 빌드하면 SwiftUI
   뷰 안에서 `cannot assign to property: 'self' is immutable` 같은 엉뚱한
   에러가 난다. `build_app.sh`가 시작 전에 확인하고 막지만, 미리 맞춰두면
   좋다: `sudo xcode-select -s /Applications/Xcode.app`.
1. `main`이 CI 그린인지 확인한다.
2. `RELEASE_NOTES.md`를 이번 버전 내용으로 작성한다. 이 파일은 항상 **다음
   릴리스**를 서술하며, GitHub 릴리스 본문에 그대로 붙여 넣는다.
3. `scripts/build_app.sh`의 `APP_VERSION` 기본값이 이번 버전인지 확인한다.
   개발 빌드가 보고하는 버전이라, 기능 작업을 시작할 때 미리 올려둬도 된다.
4. **먼저 태그를 만든다.** 산출물이 그 태그에서 나왔다는 걸 보장하기 위해서고,
   `release.sh`가 이를 강제한다 — 워킹 트리가 더럽거나 `HEAD`가 태그가 아니면
   빌드를 거부한다(로컬 무공증 패키징은 예외).

   ```bash
   git tag -a vX.Y.Z -m "BarShelf X.Y.Z"
   ```
5. 빌드·서명·공증·패키징:

   ```bash
   VERSION=X.Y.Z \
   SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
   ASC_KEY_ID=… ASC_ISSUER_ID=… \
   bash scripts/release.sh
   ```

   산출물은 `dist/release/`에 `BarShelf-X.Y.Z-arm64.zip`,
   `barshelf-cli-X.Y.Z-arm64.tar.gz`, `SHA256SUMS`. 스크립트가
   `RELEASED_VERSION`도 함께 갱신한다 — 공증된 공개 릴리스일 때만. 번들에는
   빌드한 커밋이 `BarShelfSourceCommit`으로 각인되고, 설정 창의 **Source** 행에
   표시된다.
6. 태그를 밀고 릴리스를 만든다. `release.sh`는 여기까지 하지 않는다.
   **자가 업데이터가 생긴 뒤로는 `--prerelease`로 시작하는 걸 권장한다** —
   업데이터는 GitHub의 `latest`를 보는데, pre-release는 거기 들어가지 않으므로
   직접 검증할 시간을 벌 수 있다:

   ```bash
   git push origin vX.Y.Z
   gh release create vX.Y.Z dist/release/* --prerelease \
     --title "BarShelf X.Y.Z" --notes-file RELEASE_NOTES.md
   ```
7. **검증한다.** CI의 `Verify Release` 워크플로가 릴리스 게시 시 자동으로 돌고,
   수동으로도 돌릴 수 있다:

   ```bash
   bash scripts/verify-release.sh vX.Y.Z
   ```

   체크섬, 번들 버전이 태그와 일치하는지, 더티 트리에서 빌드되지 않았는지,
   서명·공증·Gatekeeper, 그리고 **자가 업데이터가 요구하는 Developer ID
   요구문**까지 확인한다. 마지막 항목이 실패하면 모든 클라이언트가 그 업데이트를
   거부한다.
8. 자가 업데이터의 수락 경로를 확인한다. **0.2.0에서는 건너뛴다** — 0.1.3에는
   Install and Relaunch 버튼 자체가 없어서(그 버전의 업데이터는 릴리스 페이지를
   열 뿐이다) 아무도 0.2.0으로 자가 업데이트할 수 없고, 따라서 잘못된 자동
   설치 위험도 없다. 0.2.1부터는 [업데이트 리허설](#업데이트-리허설)을 먼저
   돌린다. CI 테스트는 이 경로를 건너뛰므로(러너에 Developer ID 번들이 없다)
   리허설이 유일한 사전 검증이다.
9. 문제없으면 pre-release를 해제해 전체에 푼다:
   `gh release edit vX.Y.Z --prerelease=false --latest`

   `open330/homebrew-tap`의 `sync-upstream` 워크플로가 하루 한 번 돌며
   cask와 `barshelf-cli` formula를 여기에 맞춘다. 즉시 반영하려면
   `gh workflow run sync-upstream.yml --repo Open330/homebrew-tap`.
   7번의 `verify-release.sh`가 뒤처진 탭을 실패로 잡는다.
10. 이제 문서의 버전 문구를 갱신한다 — `README.md`, `docs/INSTALL.md`,
    `site/index.html`. 갱신된 cask와 함께 커밋한다.
11. `python3 scripts/check-release-versions.py`가 통과하는지 확인한다. 통과하지
    않으면 10번이 덜 된 것이다.

## 업데이트 리허설

0.2.1부터는 잘못된 릴리스가 **자동으로 설치**된다. 그런데 업데이터는
`/releases/latest`를 읽고 pre-release는 거기서 빠지므로, pre-release로는
업데이트를 테스트할 수 없다 — 테스트하려면 실제 `latest`로 올려야 하고 그 순간
모두에게 나간다.

그래서 업데이트가 읽을 저장소를 바꿀 수 있게 해뒀다. **URL이 아니라
`owner/repo` 쌍만** 받으므로 피드는 항상 api.github.com으로만 해석되고,
다운로드를 다른 호스트로 돌릴 수는 없다. 또한 외부 코드를 설치하는 통로도 아니다
— 무엇을 찾아내든 **실행 중인 빌드와 같은 Developer ID 팀** 서명이어야 교체된다.

```bash
# 설치된 앱에 적용 (재시작 후 유효)
defaults write com.barshelf.app BarShelfUpdateRepository "<owner>/<staging-repo>"

# 터미널에서 띄울 때만
BARSHELF_UPDATE_REPO="<owner>/<staging-repo>" /Applications/BarShelf.app/Contents/MacOS/barshelf-app
```

override가 걸려 있으면 설정 창의 **Update source** 행과 업데이트 알림에
주황색으로 표시된다 — 잊고 방치해 진짜 채널에서 이탈하는 일이 없도록.

리허설 절차:

1. 스테이징 저장소에 다음 버전을 **정식 릴리스**로 올린다(그 저장소의
   `latest`가 되어야 하므로 pre-release가 아니어야 한다). 자산은 진짜와 같은
   방식으로 서명·공증한다 — 서명이 다르면 검증 단계를 통과하지 못해 리허설의
   의미가 없다.
2. 현재 버전이 설치된 맥에서 override를 걸고 **Check for Updates…** →
   **Install and Relaunch**.
3. 교체·재실행되고 버전이 올라가는지 확인한다.
4. `defaults delete com.barshelf.app BarShelfUpdateRepository`로 되돌린다.

되돌리는 걸 잊으면 그 맥은 스테이징 저장소만 따라간다. 설정 창의 주황색 행이
그걸 알려준다.

## 자가 업데이트가 거는 제약

앱이 스스로 업데이트할 수 있으므로(`UpdateChecker` + `MenubucketCore.UpdateInstaller`)
릴리스 절차가 지켜야 할 것이 두 가지 생겼다.

- **앱 자산 이름을 바꾸지 않는다.** 업데이터는 `BarShelf-<version>-arm64.zip`을
  정확히 그 이름으로 찾는다. 이름이 바뀌면 자가 업데이트는 오류 없이 조용히
  수동 다운로드로 떨어진다. `UpdateCheckerTests`가 `release.sh`의 명명 규칙을
  검사해 이 어긋남을 CI에서 잡는다.
- **CLI 자산 이름과 tar 레이아웃도 바꾸지 않는다.** `barshelf upgrade`는
  `barshelf-cli-<version>-arm64.tar.gz`를 그 이름으로 찾고, 그 안의 `barshelf`와
  `bsf`를 **멤버 이름으로** 꺼낸다(디렉터리로 감싸면 찾지 못한다).
  `UpgradeCommandTests`가 `release.sh`의 명명과 `tar -czf … barshelf bsf` 한 줄을
  검사해 CI에서 잡는다.
- **탭이 따라왔는지 확인한다.** cask와 formula는 `open330/homebrew-tap`에
  있고 `sync-upstream`이 하루 한 번 당겨온다. 뒤처지면 Homebrew 사용자에게
  업데이트 경로가 **사라진다** — 앱은 brew로 올리라 하고, brew는 이미
  최신이라고 답한다. 실제로 0.1.3에서 세 릴리스 동안 그랬다.
- **앱 시작 시 영수증을 쓰는 코드를 지우지 않는다.** 업데이터는 교체한 빌드를
  종료하기 전에 `launch-receipt.json`이 갱신되기를 기다린다. 이 기록이 없으면
  모든 자가 업데이트가 "did not start"로 실패한다(안전한 방향이지만 쓸모없다).
- **formula의 URL에 버전을 그대로 적는다.** `#{version}` 보간으로 바꾸면
  `brew bump-formula-pr`가 치환할 자리를 찾지 못해 sync가 조용히 실패한다
  (cask는 반대로 보간이 정상이다).
- **cask에 `auto_updates true`를 넣지 않는다.** BarShelf는 Homebrew로 설치된
  복사본을 감지해 `brew upgrade --cask barshelf`로 안내하고 스스로 교체하지
  않는다. 여기에 `auto_updates true`를 선언하면 `brew upgrade`가 그 복사본을
  건너뛰어, 결국 아무 업데이트 경로도 남지 않는다.

또한 **공증되지 않은 빌드는 자가 업데이트로 배포될 수 없다.** 서명·공증을
건너뛴 자산은 받는 쪽의 `spctl` 검사에서 거부된다 — 의도된 동작이다.

## 릴리스 후 확인

`scripts/verify-release.sh`가 자산·체크섬·서명·공증·Gatekeeper·업데이터
요구문을 전부 검사하므로, 손으로 확인할 건 그 바깥의 것들만 남는다.

- `brew upgrade --cask barshelf`가 새 버전을 집는지.
- 이전 버전을 실행한 채로 **Check for Updates…** → **Install and Relaunch**가
  교체·재실행까지 끝내는지.
- 이전 버전 CLI에서 `barshelf upgrade`가 CLI와 앱을 모두 올리는지. 앱과 같은
  검증 코드를 쓰지만 CLI 바이너리에는 Gatekeeper 판정을 쓸 수 없으므로(단독
  Mach-O는 티켓을 스테이플할 수 없다) 공증이 실제로 통과했는지는 여기서 다시
  확인할 수 없다 — `verify-release.sh`의 CDHash 대조가 그 역할을 한다.
- 직전 릴리스를 지우지 않는다 — 자가 업데이트가 잘못됐을 때의 유일한
  다운그레이드 경로다.

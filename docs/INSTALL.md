# BarShelf 설치 가이드

BarShelf은 macOS **메뉴바 앱**(`BarShelf.app`)과 선택 설치하는 개발자용 CLI(`barshelf`)로 배포된다.

- 요구 사항: **macOS 13 (Ventura) 이상**, Apple Silicon(arm64) — 현재 릴리스는 arm64 빌드만 제공
- 스크립트 위젯을 쓰려면 [Deno](https://deno.land) 필요 (`brew install deno`) — 없어도 exec/workflow 위젯은 전부 동작

## 방법 A — GitHub Releases (권장)

1. [Releases](https://github.com/Open330/barshelf/releases)에서 `BarShelf-<버전>-arm64.zip` 다운로드
2. 압축 해제 후 `BarShelf.app`을 `/Applications`로 이동
3. 현재 **v0.3.11은 Developer ID 서명·Apple 공증·티켓 스테이플을 통과한 빌드**이므로 일반 더블클릭으로 실행한다.
4. 메뉴바에 아이콘이 나타나면 클릭 → 온보딩 시작. 로그인 시 자동 실행은 시스템 설정 → 일반 → 로그인 항목에서 추가

> 릴리스 설명과 `SHA256SUMS`를 함께 확인한다. v0.3.11 앱은 최종 ZIP을 다시 풀어 `codesign`, `stapler`, `spctl`, `syspolicy_check` 배포 검사를 통과했다.

### barshelf CLI (선택)

위젯 제작·검증·패키징용 커맨드라인 도구다. **앱 번들 안에 들어있지 않고**,
Releases의 **별도 에셋 `barshelf-cli-<버전>-arm64.tar.gz`**로 배포된다.

```bash
# Releases에서 barshelf-cli-<버전>-arm64.tar.gz 와 SHA256SUMS 다운로드 후
shasum -a 256 -c SHA256SUMS --ignore-missing   # 체크섬 검증
tar -xzf barshelf-cli-*-arm64.tar.gz
codesign --verify --strict barshelf bsf             # 바이너리 무결성 확인
sudo mv barshelf bsf /usr/local/bin/
barshelf --version
```

> v0.3.11 CLI는 Developer ID로 서명되고 Apple 공증 티켓에 각 바이너리의
> CDHash가 등록된다. 릴리스 스크립트는 최종 TAR의 CDHash까지 대조하며,
> 미공증 산출물은 `dist/local-release/`에만 생성한다.

설치한 뒤로는 `barshelf upgrade`가 CLI와 앱을 함께 최신 릴리스로 올린다
(`--check`로 확인만). Homebrew로 설치한 앱은 `brew upgrade --cask barshelf`로
안내하고, 로컬 빌드는 거부한다 — 자세한 규칙은
[`docs/CLI.md`](CLI.md#자가-업데이트).

사용법: [`docs/CLI.md`](CLI.md)

## 방법 B — 소스 빌드

Xcode(Command Line Tools만으로는 테스트 불가)와 Swift 5.9+ 필요:

```bash
git clone git@github.com:Open330/barshelf.git
cd barshelf
bash scripts/build_app.sh          # dist/BarShelf.app + dist/barshelf + dist/bsf 생성
open dist/BarShelf.app
```

개발 모드로 바로 실행하려면 (`./widgets/` 예제가 즉시 로드됨):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run barshelf-app
```

로컬 검증용 패키지(zip/tar.gz + SHA256SUMS) 생성:

```bash
VERSION=0.3.11 NOTARIZE=0 ALLOW_UNNOTARIZED=1 SIGN_IDENTITY=- bash scripts/release.sh
```

공개 릴리스는 `VERSION`, Developer ID Application `SIGN_IDENTITY`, App Store
Connect 공증 환경 변수(`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`)를 모두
설정해야 한다. 하나라도 없으면 스크립트가 실패한다.

## 방법 C — Homebrew tap

cask와 CLI formula는 [`open330/homebrew-tap`](https://github.com/Open330/homebrew-tap)에
있다 — Open330의 다른 프로젝트와 같은 탭이다.

```bash
brew tap open330/tap
brew install --cask barshelf      # 앱
brew install barshelf-cli         # CLI (barshelf, bsf) — 선택
```

탭을 영구적으로 추가하지 않으려면 `brew install --cask open330/tap/barshelf`.

최신 Homebrew는 서드파티 탭의 항목을 처음 쓸 때 신뢰를 요구한다. `Refusing to
load formula ... from untrusted tap`이 나오면 안내대로
`brew trust --formula open330/tap/barshelf-cli` (또는 `brew trust open330/tap`)를
한 번 실행한다. 릴리스로 파일이 바뀌면 신뢰가 다시 필요할 수 있다.

업데이트는 `brew upgrade --cask barshelf`, 제거는 `brew uninstall --cask barshelf`.

> `brew upgrade`는 번들만 교체하므로 **실행 중이던 앱은 옛 빌드 그대로**다. cask에
> `uninstall quit:`가 있지만 Homebrew가 앱을 종료하려면 Automation 권한이 필요하고,
> 없으면 조용히 넘어간다(이 맥에서 실제로 그랬다). 업그레이드 후 메뉴바 아이콘을
> 종료했다가 다시 열어라.
현재 cask는 서명·공증된 v0.3.11 자산과 검증된 SHA-256을 사용한다.

> 이 저장소에도 cask 사본이 있었지만 삭제했다. 탭의 사본과 갈라져 0.1.3에 멈춰
> 있었고, 그 결과 탭으로 설치한 사람은 앱에게 "brew로 올려라"라는 말을 듣고
> brew에게 "이미 최신이다"라는 답을 들었다 — 업데이트 경로가 아예 없었다. 이제
> 탭이 유일한 사본이고, 릴리스가 `.github/workflows/tap-bump.yml`로 갱신하며
> `scripts/verify-release.sh`가 뒤처지면 실패한다.

## 업데이트

메뉴바 우클릭의 **Check for Updates…** 가 GitHub Releases를 확인한다. 새 버전이
있으면 어떻게 설치할지는 이 복사본이 어떤 상태인지에 따라 달라진다.

| 설치 형태 | 동작 |
| --- | --- |
| Developer ID 서명된 릴리스를 쓰기 가능한 위치에 둔 경우 | **Install and Relaunch** 로 앱이 직접 받아서 교체하고 재실행한다. |
| Homebrew cask로 설치한 **그 복사본** | 자가 업데이트하면 brew 기록과 어긋나므로 `brew upgrade --cask barshelf` 명령을 안내한다(복사 버튼 제공). cask가 설치돼 있어도 다른 위치에서 실행 중인 복사본은 정상적으로 자가 업데이트한다. |
| App Store(샌드박스) 빌드 | Store가 업데이트를 관리하므로 관여하지 않는다. |
| 로컬 빌드 | 교체하지 않고 릴리스 페이지를 연다. ad-hoc 서명뿐 아니라 **기여자의 Apple Development 인증서로 서명된 빌드도 포함**된다 — 그건 릴리스 신원이 아니라서 업데이트를 대조할 기준이 못 된다. |
| 쓰기 권한이 없는 위치 | 마찬가지로 릴리스 페이지를 연다. |

자가 업데이트가 받은 빌드는 **교체 전에** 두 가지를 통과해야 한다.

1. **같은 개발자의 Developer ID 서명** — 팀 ID는 *지금 실행 중인* 빌드의 것이고,
   요구문은 Developer ID Application 인증서까지 못박는다(leaf
   `1.2.840.113635.100.6.1.13`, 중간 `1.2.840.113635.100.6.2.6`). 팀 OU만
   확인하면 같은 팀의 **Apple Development** 인증서도 통과해버린다. 검사에는
   `kSecCSStrictValidate`를 걸어, 서명이 덮지 않는 파일이 번들 루트에 끼어든
   비표준 레이아웃도 거부한다. 릴리스 옆에 같이 올라온 체크섬은 신뢰 근거가
   되지 못한다 — zip을 내려주는 쪽이 해시도 내려주기 때문이다.
2. **같은 제품인지** — `CFBundleIdentifier`가 일치해야 한다. 같은 개발자가
   서명한 *다른* 앱은 이 앱의 업데이트가 아니다.
3. **macOS 자체 판정** — `spctl --assess --type execute`. 공증이 철회된 빌드를
   교체 *전에* 걸러낸다. 이 조회는 네트워크를 타므로 타임아웃을 두고, 시간이
   초과되면 "통과"가 아니라 "거부"로 처리한다.

받는 과정 자체도 이 저장소가 위젯 설치에 쓰는 것과 같은 가드를 지난다: HTTPS
전용, 리다이렉트는 GitHub 자체 호스트로 제한, 크기 상한, 그리고 언제든 누를 수
있는 **Cancel**. 압축 해제 전에는 zip 중앙 디렉터리를 먼저 읽어 경로 이탈
항목과 과도한 크기를 걸러낸다 — 서명 검증은 풀어본 뒤에야 가능하므로, 그 전에
경계를 두는 쪽이 `ditto`에 검증되지 않은 바이트를 그냥 넘기는 것보다 낫다.

어느 단계든 실패하면 설치된 복사본은 **손대지 않은 채로** 남고, 릴리스 페이지를
여는 기존 동작으로 되돌아간다.

## 설치 확인 체크리스트

- [ ] 메뉴바 아이콘 클릭 → 팝업에 첫 실행 위젯(Today / Recent Files / Quick Shelf) 표시
- [ ] 우클릭 메뉴에 Widget Gallery… / Install Widget from URL… / Refresh All 표시
- [ ] `barshelf list` 실행 시 설치된 위젯 목록 출력
- [ ] (선택) `brew install deno` 후 clock-script 위젯 동작

## 문제 해결

| 증상 | 해결 |
|---|---|
| "확인되지 않은 개발자" 경고 | v0.3.11 이상인지와 `SHA256SUMS`를 확인한 뒤 공식 Releases에서 다시 다운로드. 계속되면 이슈에 macOS 버전과 `spctl -a -vv -t exec BarShelf.app` 결과 첨부 |
| 아이콘이 안 보임 | 메뉴바 공간 부족 — 다른 아이콘 정리 후 재실행 |
| script 위젯에 "Install Deno" 카드 | `brew install deno` 후 위젯 카드에서 Refresh |
| otpeek 위젯 패스워드 오류 | [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)의 Keychain 설정(`security add-generic-password …`) 참조 |
| 위젯이 안 나타남 | `~/Library/Application Support/barshelf/widgets/<id>/widget.json` 존재 확인 후 `barshelf validate <경로>` |

## 배포 로드맵

| 단계 | 상태 |
|---|---|
| GitHub Releases | ✅ v0.3.11 서명·공증 산출물 준비 완료 |
| Developer ID 서명 + 공증 | ✅ 앱/CLI Accepted, 앱 티켓 스테이플 및 배포 검사 통과 |
| 자가 업데이트 | ✅ 앱은 **Check for Updates…**, 터미널은 `barshelf upgrade` — Sparkle 없이 직접 구현(런타임 의존성 0). Homebrew 설치본은 `brew upgrade`로 안내 |
| Homebrew cask (`brew install --cask barshelf`) | ✅ v0.3.11 체크섬 반영 |
| Mac App Store | ❌ 계획 없음 — 임의 CLI 실행이 샌드박스와 충돌 (라이트 에디션만 장기 검토) |

# BarShelf 설치 가이드

BarShelf은 macOS **메뉴바 앱**(`BarShelf.app`)과 선택 설치하는 개발자용 CLI(`barshelf`)로 배포된다.

- 요구 사항: **macOS 13 (Ventura) 이상**, Apple Silicon(arm64) — 현재 릴리스는 arm64 빌드만 제공
- 스크립트 위젯을 쓰려면 [Deno](https://deno.land) 필요 (`brew install deno`) — 없어도 exec/workflow 위젯은 전부 동작

## 방법 A — GitHub Releases (권장)

1. [Releases](https://github.com/Open330/barshelf/releases)에서 `BarShelf-<버전>-arm64.zip` 다운로드
2. 압축 해제 후 `BarShelf.app`을 `/Applications`로 이동
3. 현재 **v0.1.3은 Developer ID 서명·Apple 공증·티켓 스테이플을 통과한 빌드**이므로 일반 더블클릭으로 실행한다.
4. 메뉴바에 아이콘이 나타나면 클릭 → 온보딩 시작. 로그인 시 자동 실행은 시스템 설정 → 일반 → 로그인 항목에서 추가

> 릴리스 설명과 `SHA256SUMS`를 함께 확인한다. v0.1.3 앱은 최종 ZIP을 다시 풀어 `codesign`, `stapler`, `spctl`, `syspolicy_check` 배포 검사를 통과했다.

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

> v0.1.3 CLI는 Developer ID로 서명되고 Apple 공증 티켓에 각 바이너리의
> CDHash가 등록된다. 릴리스 스크립트는 최종 TAR의 CDHash까지 대조하며,
> 미공증 산출물은 `dist/local-release/`에만 생성한다.

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
VERSION=0.1.3 NOTARIZE=0 ALLOW_UNNOTARIZED=1 SIGN_IDENTITY=- bash scripts/release.sh
```

공개 릴리스는 `VERSION`, Developer ID Application `SIGN_IDENTITY`, App Store
Connect 공증 환경 변수(`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`)를 모두
설정해야 한다. 하나라도 없으면 스크립트가 실패한다.

## 방법 C — Homebrew tap

cask 정의(`Casks/barshelf.rb`)가 메인 저장소에 포함돼 있어 별도 `homebrew-barshelf` 저장소 없이
명시적 URL tap으로 바로 설치할 수 있다:

```bash
brew tap Open330/barshelf https://github.com/Open330/barshelf
brew install --cask barshelf
```

업데이트는 `brew upgrade --cask barshelf`, 제거는 `brew uninstall --cask barshelf`.
현재 cask는 서명·공증된 v0.1.3 자산과 검증된 SHA-256을 사용한다.

## 설치 확인 체크리스트

- [ ] 메뉴바 아이콘 클릭 → 팝업에 첫 실행 위젯(Today / Recent Files / Quick Shelf) 표시
- [ ] 우클릭 메뉴에 Widget Gallery… / Install Widget from URL… / Refresh All 표시
- [ ] `barshelf list` 실행 시 설치된 위젯 목록 출력
- [ ] (선택) `brew install deno` 후 clock-script 위젯 동작

## 문제 해결

| 증상 | 해결 |
|---|---|
| "확인되지 않은 개발자" 경고 | v0.1.3 이상인지와 `SHA256SUMS`를 확인한 뒤 공식 Releases에서 다시 다운로드. 계속되면 이슈에 macOS 버전과 `spctl -a -vv -t exec BarShelf.app` 결과 첨부 |
| 아이콘이 안 보임 | 메뉴바 공간 부족 — 다른 아이콘 정리 후 재실행 |
| script 위젯에 "Install Deno" 카드 | `brew install deno` 후 위젯 카드에서 Refresh |
| otpeek 위젯 패스워드 오류 | [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)의 Keychain 설정(`security add-generic-password …`) 참조 |
| 위젯이 안 나타남 | `~/Library/Application Support/barshelf/widgets/<id>/widget.json` 존재 확인 후 `barshelf validate <경로>` |

## 배포 로드맵

| 단계 | 상태 |
|---|---|
| GitHub Releases | ✅ v0.1.3 서명·공증 산출물 준비 완료 |
| Developer ID 서명 + 공증 | ✅ 앱/CLI Accepted, 앱 티켓 스테이플 및 배포 검사 통과 |
| Sparkle 자동 업데이트 | ⏳ 공증 릴리스 이후 검토 |
| Homebrew cask (`brew install --cask barshelf`) | ✅ v0.1.3 체크섬 반영 |
| Mac App Store | ❌ 계획 없음 — 임의 CLI 실행이 샌드박스와 충돌 (라이트 에디션만 장기 검토) |

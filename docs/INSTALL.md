# BarShelf 설치 가이드

BarShelf은 macOS **메뉴바 앱**(`BarShelf.app`)과 선택 설치하는 개발자용 CLI(`mbk`)로 배포된다.

- 요구 사항: **macOS 13 (Ventura) 이상**, Apple Silicon(arm64) — 현재 릴리스는 arm64 빌드만 제공
- 스크립트 위젯을 쓰려면 [Deno](https://deno.land) 필요 (`brew install deno`) — 없어도 exec/workflow 위젯은 전부 동작

## 방법 A — GitHub Releases (권장)

1. [Releases](https://github.com/jiunbae/menubucket/releases)에서 `BarShelf-<버전>-arm64.zip` 다운로드
2. 압축 해제 후 `BarShelf.app`을 `/Applications`로 이동
3. **더블클릭으로 실행**한다. 릴리스는 **Developer ID 서명 + Apple 공증**되어 있어 Gatekeeper 우회 조작이 필요 없다.
4. 메뉴바에 아이콘이 나타나면 클릭 → 온보딩 시작. 로그인 시 자동 실행은 시스템 설정 → 일반 → 로그인 항목에서 추가

> 소스에서 직접 빌드한 결과물은 ad-hoc 서명이라 공증되지 않는다. 그 경우에만 첫 실행 시 우클릭 → 열기가 필요하다.

### mbk CLI (선택)

위젯 제작·검증·패키징용 커맨드라인 도구:

```bash
# Releases에서 mbk-<버전>-arm64.tar.gz 다운로드 후
tar -xzf mbk-*-arm64.tar.gz
sudo mv mbk /usr/local/bin/
mbk --version
```

사용법: [`docs/MBK.md`](MBK.md)

## 방법 B — 소스 빌드

Xcode(Command Line Tools만으로는 테스트 불가)와 Swift 5.9+ 필요:

```bash
git clone git@github.com:jiunbae/menubucket.git
cd menubucket
bash scripts/build_app.sh          # dist/BarShelf.app + dist/mbk 생성
open dist/BarShelf.app
```

개발 모드로 바로 실행하려면 (`./widgets/` 예제가 즉시 로드됨):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run menubucket
```

릴리스 패키지(zip/tar.gz + SHA256SUMS) 생성: `bash scripts/release.sh`

## 설치 확인 체크리스트

- [ ] 메뉴바 아이콘 클릭 → 팝업에 번들 위젯(Demo/hello 등) 표시
- [ ] 우클릭 메뉴에 Widget Gallery… / Install Widget from URL… / Refresh All 표시
- [ ] `mbk list` 실행 시 설치된 위젯 목록 출력
- [ ] (선택) `brew install deno` 후 clock-script 위젯 동작

## 문제 해결

| 증상 | 해결 |
|---|---|
| "확인되지 않은 개발자" 경고 | 위 3번 — 우클릭 열기 또는 `xattr -dr com.apple.quarantine` |
| 아이콘이 안 보임 | 메뉴바 공간 부족 — 다른 아이콘 정리 후 재실행 |
| script 위젯에 "Install Deno" 카드 | `brew install deno` 후 위젯 카드에서 Refresh |
| otpeek 위젯 패스워드 오류 | [`docs/WIDGET-SPEC.md`](WIDGET-SPEC.md)의 Keychain 설정(`security add-generic-password …`) 참조 |
| 위젯이 안 나타남 | `~/Library/Application Support/barshelf/widgets/<id>/widget.json` 존재 확인 후 `mbk validate <경로>` |

## 배포 로드맵

| 단계 | 상태 |
|---|---|
| GitHub Releases (공증 zip) | ✅ 현재 |
| Developer ID 서명 + 공증 | ✅ 완료 — v0.1.0부터 공증 배포 (`SIGN_IDENTITY`+`SIGN_KEYCHAIN`+`NOTARIZE=1`) |
| Sparkle 자동 업데이트 | ⏳ 공증 이후 |
| Homebrew cask (`brew install --cask menubucket`) | ⏳ 공증 이후 (cask는 공증 빌드 권장) |
| Mac App Store | ❌ 계획 없음 — 임의 CLI 실행이 샌드박스와 충돌 (라이트 에디션만 장기 검토) |

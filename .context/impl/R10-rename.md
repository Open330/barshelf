# R10 — 실행파일 rename + CI + Homebrew tap

작업일: 2026-07-08 (커밋 안 함)

## 1. 실행파일 제품명 rename menubucket → barshelf
- `Package.swift`: `.executable(name:"menubucket"…)` → `name:"barshelf"`. 모듈/타깃명(MenubucketApp·MenubucketCore·MbkKit·MbkCLI), `mbk` 제품은 그대로 유지.
- `scripts/build_app.sh`: `PRODUCT_NAME`/`EXECUTABLE_NAME` 기본값 `menubucket` → `barshelf`. 번들 실행파일이 `Contents/MacOS/barshelf`로 생성됨.
- `scripts/Info.plist.template`: 변경 불필요 — `CFBundleExecutable`=`__EXECUTABLE_NAME__`(build_app.sh가 barshelf로 치환). URL scheme은 barshelf+menubucket 둘 다 유지(하위호환).
- `Sources/MenubucketApp/main.swift`: 주석 `menubucket install` → `barshelf install`. (인자 모드 로직은 실행파일명 무관, 변경 없음)
- `docs/INSTALL.md`: `swift run menubucket`→`swift run barshelf`, `cd menubucket`→`cd barshelf`, 로드맵 cask 이름 `menubucket`→`barshelf`.
- `docs/MBK.md`: `MacOS/menubucket install`→`MacOS/barshelf install`.
- README.md에는 menubucket 참조 없음(변경 없음).
- 주의: docs/INSTALLING-WIDGETS.md·PUBLISHING.md·GETTING-STARTED.md에도 `MacOS/menubucket` 참조가 남아있으나 소유 범위 밖이라 미변경(다른 에이전트 담당).

## 2. CI Node20 deprecation
- `.github/workflows/ci.yml`: `actions/checkout@v4` → `@v5`. setup-xcode@v1 유지.

## 3. Homebrew tap 안내
- `docs/INSTALL.md`에 "방법 C — Homebrew tap" 추가:
  `brew tap Open330/barshelf https://github.com/Open330/barshelf && brew install --cask barshelf`.
- cask 정의는 메인 repo `Casks/barshelf.rb`에 존재. 별도 homebrew-barshelf repo 불필요, 명시적 URL tap.

## 검증
- `swift build` OK (Linking barshelf), `swift test` 167 passed / 0 failures.
- `bash -n scripts/build_app.sh` OK.
- `bash scripts/build_app.sh` → `dist/BarShelf.app/Contents/MacOS/barshelf` 생성, Info.plist CFBundleExecutable=barshelf.
- `open` → `pgrep -x barshelf` 정상 상주 확인 후 `pkill -x barshelf`로 정상 종료.

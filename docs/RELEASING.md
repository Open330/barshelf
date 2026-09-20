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

1. `main`이 CI 그린인지 확인한다.
2. `RELEASE_NOTES.md`를 이번 버전 내용으로 작성한다. 이 파일은 항상 **다음
   릴리스**를 서술하며, GitHub 릴리스 본문에 그대로 붙여 넣는다.
3. `scripts/build_app.sh`의 `APP_VERSION` 기본값이 이번 버전인지 확인한다.
   개발 빌드가 보고하는 버전이라, 기능 작업을 시작할 때 미리 올려둬도 된다.
4. 빌드·서명·공증·패키징:

   ```bash
   VERSION=X.Y.Z \
   SIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
   ASC_KEY_ID=… ASC_ISSUER_ID=… \
   bash scripts/release.sh
   ```

   산출물은 `dist/release/`에 `BarShelf-X.Y.Z-arm64.zip`,
   `barshelf-cli-X.Y.Z-arm64.tar.gz`, `SHA256SUMS`. 스크립트가
   `Casks/barshelf.rb`의 `version`/`sha256`도 함께 갱신한다 — 공증된 공개
   릴리스일 때만.
5. 태그를 밀고 릴리스를 만든다. `release.sh`는 여기까지 하지 않는다:

   ```bash
   git tag -a vX.Y.Z -m "BarShelf X.Y.Z" && git push origin vX.Y.Z
   gh release create vX.Y.Z dist/release/* \
     --title "BarShelf X.Y.Z" --notes-file RELEASE_NOTES.md
   ```
6. 이제 문서의 버전 문구를 갱신한다 — `README.md`, `docs/INSTALL.md`,
   `site/index.html`. 갱신된 cask와 함께 커밋한다.
7. `python3 scripts/check-release-versions.py`가 통과하는지 확인한다. 통과하지
   않으면 6번이 덜 된 것이다.

## 릴리스 후 확인

- `gh release view vX.Y.Z` — 자산 3종이 있는지.
- 받은 zip에 대해 `codesign -vvv --deep --strict`, `stapler validate`,
  `spctl -a -vv -t exec`.
- `SHA256SUMS`가 올라간 자산과 맞는지.
- `brew upgrade --cask barshelf`가 새 버전을 집는지.
- 이전 버전을 실행한 채로 **Check for Updates…** 가 새 버전을 알리는지.

# R06 통합 검증 노트 (메인 세션)

3트랙 병합 후 검증: 테스트 **133/133**, `bash scripts/build_app.sh` → `dist/MenuBucket.app` + `dist/mbk`, GUI 스모크 OK.
(Codex는 사용량 한도로 7/12까지 불가 — Track C는 Claude로 대체 수행.)

## 에이전트 조율 포인트 처리 (메인 세션 직접 수정)

1. **zip 실행권한 복원** — `SafeZipExtractor`가 POSIX 퍼미션을 버려 zip 설치된 exec 위젯의 `.sh`가 실행 불가였음. shebang(`#!`) 파일에 0o755 복원 추가. 실검증: `mbk pack→install` 후 `widget.sh`가 `-rwxr-xr-x`.
2. **registry 번들 폴백** — `build_app.sh`에 `registry/` → `Resources/registry/` rsync 추가 (GalleryView가 이미 이 경로를 폴백으로 탐색).
3. **스키마 `_comment` 키** — `schema/registry-0.1.json`의 widgets.items에 `additionalProperties` 제약 없음 → 샘플 index.json의 `_comment` 허용 확인, 수정 불필요.

## mbk 라운드트립 실측 (dist/mbk)

`new demo-widget --kind exec` → `validate`(OK) → `pack`(manifest.sha256 포함) → `validate demo.mbw`(OK) → `install file://…/demo.mbw --yes`(설치+권한 요약 출력) → `list`(demo-widget 표시) → 정리. 전 단계 exit 0.

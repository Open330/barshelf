# Glossary

The words BarShelf shows people, in English and Korean. Use these in UI
strings, widget localisations, and user docs. `CatalogStyleTests` fails on the
Korean forms marked "not".

## Terms

| English | Korean | Not | Meaning |
|---|---|---|---|
| Refresh | 새로고침 | 갱신, 새로 고침 | Run a widget again to get new data. |
| window | 창 | 윈도우 | Any macOS window, the BarShelf window included. |
| popup | 팝업 | popover, 팝오버 | What opens from the menu bar icon. |
| Shelf | 선반 | | Only the arrangement of widgets and pages, and its page in the BarShelf window. Not the popup: "while the popup is closed", not "while the shelf is closed". |
| copy (of a widget) | 사본 | instance, 복사본, 인스턴스 | A second widget made with Duplicate. |
| Gallery | 갤러리 | "Gallery" inside Korean | The page for finding and installing widgets. |
| online widget list | 온라인 위젯 목록 | registry, 레지스트리 | Where the Gallery's widgets come from. |
| allow | 허용 | 허락 | Granting a widget a permission. |
| item | 항목 | 아이템 | A menu bar item, a Dock item, a vault item. |
| Dock styles: Classic, Cards | 클래식, 카드 | Shelf | The two looks of the BarShelf Dock. |

Internal names (workflow, manifest, transform, registry, instance, exit codes,
widget IDs) stay out of everyday copy. They are fine in the Create page, the
CLI, and developer docs.

## Paths and buttons

- Separate steps of a path with " ▸ ": `System Settings ▸ Privacy & Security ▸ Accessibility`,
  `BarShelf ▸ Menu Bar`. Not › or →. Pages of the BarShelf window are `BarShelf ▸ <page>`.
- A button or menu item that opens a dialog or asks for more input ends in "…":
  "Add Widget…", "Settings…".

## Korean style

- Instructions end in -세요: "허용하세요", "다시 시도하세요". Not -십시오.
- Statements and descriptions end in -합니다/-습니다.
- Confirmation questions end in -할까요?: "위젯을 제거할까요?". Not -하겠습니까?/-하시겠습니까?.
- Short labels and buttons stay as nouns or verb stems, as in macOS: "위젯 추가", "새로고침".
- Write natural Korean, and check particles when a word changes: 창을, 팝업이, 사본을.

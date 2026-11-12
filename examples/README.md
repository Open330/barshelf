# Examples

Small widgets that show how to write one, plus a few that a gallery widget has
since replaced. They are not in the gallery and the app does not bundle them;
CI still validates every manifest here.

| Example | Layer | Shows |
|---|---|---|
| [hello](hello) | exec | The smallest widget: a shell script that prints a UINode tree. |
| [clock-script](clock-script) | script | The Deno runtime, the typed SDK, a timer and stored state. |
| [visit-counter](visit-counter) | workflow | Persisting a value between refreshes. |
| [downloads-watch](downloads-watch) | workflow | A file-system refresh trigger. The gallery's **Downloads** widget covers the same ground. |
| [local-time](local-time) | workflow | A clock computed without running a command. See **Clock** and **World Clock** in the gallery. |
| [top-processes](top-processes) | workflow | The native process list. **System** now shows it on its own card. |
| [battery](battery) | script | A script widget around `pmset`. The gallery ships the workflow **Battery** instead. |

Install one from a checkout:

```bash
barshelf install ./examples/hello
```

Already installed one of these from an earlier BarShelf? It keeps working; it
just no longer updates with the app.

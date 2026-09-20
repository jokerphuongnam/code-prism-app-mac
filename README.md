# code-prism-app-mac

macOS **SwiftUI + SceneKit** viewer for [Code Prism](https://github.com/jokerphuongnam) graphs.

This app **does not parse source**. It only:

1. Opens a project folder  
2. Installs / runs a **language backend** (`*-prism`)  
3. Reads **SoT** under `<project>/.codeprism/` (fallback: `.swiftprism/`)

## SoT contract

```text
<project>/.codeprism/
  prism-context.json     # interchange (signatures + dependencyIndex or flat nodes)
  graph.sqlite           # preferred query DB (optional)
  codeprism-config.json  # optional paths
```

## Backends

| Backend | Repo | Languages |
|---------|------|-----------|
| Swift | [swift-prism](https://github.com/jokerphuongnam/swift-prism) | Swift |
| Marlin | [marlin-prism](https://github.com/jokerphuongnam/marlin-prism) | `.marlin` |
| Kotlin | [kotlin-prism](https://github.com/jokerphuongnam/kotlin-prism) | Kotlin |
| JS/TS | [js-prism](https://github.com/jokerphuongnam/js-prism) | JavaScript / TypeScript |

Install binaries into:

`~/Library/Application Support/SwiftPrism/backends/<id>/<binary>`

(or set `CODE_PRISM_BACKEND_<ID>` env).

## Run

```bash
cd ~/Documents/Code/code-prism-app-mac
xcodegen generate   # if needed
open SwiftPrismApp.xcodeproj
```

Demo: **LiteTrace** at `~/Documents/Code/iOS/LiteTrace` → Install backend → Analyze → SoT.

## Related

- [code-prism-vs-code](https://github.com/jokerphuongnam/code-prism-vs-code) — VS Code extension (same SoT)

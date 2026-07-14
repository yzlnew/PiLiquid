# AGENTS.md

Guidance for agents working on Pi Liquid.

## UI / Animation

- 非必要不动画。交互优先即时响应，尽可能快——能 snap 就不要 slide/fade。
- 默认不给状态更新加隐式动画（例如进度环、计数、列表项）；需要时用 `.transaction { $0.animation = nil }` 或不设置动画。
- 视图里有 `WKWebView`（如 Markdown 消息）时，绝对避免在 resize/move 时逐帧动画——webview 会逐帧重排/重绘导致掉帧。优先让布局一次到位（snap），而不是动画过渡。
- 确实需要动画时保持短促克制，参考既有时长（0.12–0.22s ease-out）。

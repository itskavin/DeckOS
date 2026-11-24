# AI Limits — third-party notices

The AI Limits backend (`DeckOS/Services/AiLimits`) is original C# code. Parts of it
re-implement protocol handling, normalization rules and data-safety patterns studied
in the MIT-licensed projects below. No source files were copied or vendored. They are
credited here, and in comments at each adapted spot, under their MIT terms.

| Project (pinned commit) | What DeckOS adapts | Where |
| --- | --- | --- |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) (`a26ca57b`) | `codex -s read-only -a never app-server` launch flags, `initialize` → `initialized` → `account/rateLimits/read` handshake order, duration-based window classification (single 10080-min Pro window → weekly, 5h not applicable), extra-bucket model-pool mapping, camelCase/snake_case decoding | `CodexLocalAdapter.cs`, `CliProxyPassiveAdapter.cs` |
| [Maciek-roboblog/Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) (`c59a83bf`) | statusLine `used_percentage` guard (drop > 101, clamp 100–101), expired-window staleness without auto-zero, `rate_limits` tombstone, pid temp file + atomic rename | `ClaudeStatusLineAdapter.cs`, `IAiLimitsSourceAdapter.cs` |
| [shuv1337/shuvquota](https://github.com/shuv1337/shuvquota) (`709d2db8`) | constructive allow-list DTO rebuilding and control-character text sanitizing | `CliProxyPassiveAdapter.cs`, `IAiLimitsSourceAdapter.cs` (`SanitizeText`) |
| [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (`6eb8554f`, v8.0.48) | read-only use of its management API (`GET /v8/management/credentials`, legacy `GET /v0/management/auth-files`), its documented `quota.signals` / `model_quotas` / `cooldowns` schema and scales, and its brute-force lockout rule (which sets DeckOS's auth circuit) | `CliProxyPassiveAdapter.cs` |
| [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons) (`@lobehub/icons`, MIT) | bundled local SVG path vectors (`openai`, `claude`, `gemini`, `antigravity`, `githubcopilot`, `cursor`, `windsurf`) for local provider identification only (zero runtime fetching) | `app/lib/src/ai_limits/ai_provider_icon.dart` |

DeckOS does **not** use these projects' active polling, OAuth, browser-cookie, PTY or
quota-refresh paths. `onWatch` (GPL-3.0) was reviewed but nothing was taken from it,
and it is not a supported source.

## MIT License (applies to each project above)

```
Copyright (c) 2026 Peter Steinberger
Copyright (c) 2025 Maciej
Copyright (c) 2026 shuv1337
Copyright (c) 2025-2005.9 Luis Pater
Copyright (c) 2025.9-present Router-For.ME
Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

(The CLIProxyAPI copyright years are quoted exactly as they appear upstream.)

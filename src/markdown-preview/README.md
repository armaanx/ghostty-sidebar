# Markdown preview (ghostty-sidebar fork)

Web page used by the GTK file explorer to preview Markdown files. It is
installed to `share/ghostty/markdown-preview/` and shown in a WebKitGTK
view. The app calls `window.ghosttyPreview.render(markdown, options)`.

`vendor/` holds pinned, unmodified copies of third-party libraries
(licenses in `vendor/licenses/`):

| Library | Version | Use |
|---|---|---|
| markdown-it | 14.1.0 | Markdown parser (GFM tables, strikethrough, linkify) |
| markdown-it-footnote | 4.0.0 | Footnotes |
| markdown-it-task-lists | 2.1.1 | Task lists |
| markdown-it-texmath | 1.0.0 | `$math$` / `$$math$$` via KaTeX |
| KaTeX | 0.16.22 | Math rendering |
| DOMPurify | 3.2.6 | HTML sanitizing |
| highlight.js | 11.11.1 | Code highlighting |
| Mermaid | 11.12.0 | Diagrams (loaded only when a file has one) |

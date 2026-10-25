// Markdown preview for the ghostty-sidebar file explorer.
//
// The app loads preview.html once and calls window.ghosttyPreview.render()
// with the file contents and theme. Rendering:
//   markdown-it (GFM tables, strikethrough, linkify, typographer)
//   + footnotes, task lists, KaTeX math ($...$, $$...$$, \(...\), \[...\])
//   -> DOMPurify sanitize -> DOM
//   -> highlight.js for code, Mermaid for ```mermaid blocks (loaded lazily),
//      GitHub alerts (> [!NOTE]), heading anchors, front matter.
// The page has a strict Content-Security-Policy: no inline scripts, no
// network requests other than images.
(function () {
  "use strict";

  const scriptBase = document.currentScript.src.replace(/[^/]*$/, "");
  const content = document.getElementById("content");

  const md = window
    .markdownit({ html: true, linkify: true, typographer: true, breaks: false })
    .use(window.markdownitFootnote)
    .use(window.markdownitTaskLists, { enabled: false, label: true, labelAfter: true })
    .use(window.texmath, {
      engine: window.katex,
      delimiters: ["dollars", "brackets"],
      katexOptions: { throwOnError: false, output: "htmlAndMathml" },
    });

  // Heading ids for in-page links, GitHub style.
  function slugify(text) {
    return text
      .trim()
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s_-]/gu, "")
      .replace(/\s/g, "-");
  }
  md.core.ruler.push("heading_ids", (state) => {
    const seen = new Map();
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].type !== "heading_open") continue;
      const inline = tokens[i + 1];
      const text = inline && inline.children
        ? inline.children.filter((t) => t.type === "text" || t.type === "code_inline").map((t) => t.content).join("")
        : "";
      let slug = slugify(text) || "section";
      const n = seen.get(slug) || 0;
      seen.set(slug, n + 1);
      if (n > 0) slug += "-" + n;
      tokens[i].attrSet("id", slug);
    }
  });

  const purifyConfig = {
    ADD_TAGS: ["eq", "eqn"],
    ADD_ATTR: ["target", "align"],
    FORBID_TAGS: ["style", "form", "button", "textarea", "select"],
  };

  // Front matter (--- yaml --- at the top) is shown as a small code block.
  function splitFrontMatter(src) {
    const m = /^---\r?\n([\s\S]*?)\r?\n(?:---|\.\.\.)\r?\n?/.exec(src);
    if (!m) return { front: null, body: src };
    return { front: m[1], body: src.slice(m[0].length) };
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  // GitHub alerts: > [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION]
  const alertTitles = { note: "Note", tip: "Tip", important: "Important", warning: "Warning", caution: "Caution" };
  function applyAlerts(root) {
    for (const bq of root.querySelectorAll("blockquote")) {
      const p = bq.firstElementChild;
      if (!p || p.tagName !== "P") continue;
      const m = /^\s*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/i.exec(p.textContent);
      if (!m) continue;
      const kind = m[1].toLowerCase();
      // Remove the marker text from the first text node.
      const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
      const first = walker.nextNode();
      if (first) first.textContent = first.textContent.replace(/^\s*\[![A-Za-z]+\]\s*/, "");
      if (p.firstChild && p.firstChild.nodeName === "BR") p.firstChild.remove();
      if (!p.textContent.trim() && !p.querySelector("img")) p.remove();
      const title = document.createElement("p");
      title.className = "markdown-alert-title";
      title.textContent = alertTitles[kind];
      bq.prepend(title);
      bq.classList.add("markdown-alert", "markdown-alert-" + kind);
    }
  }

  function wrapTables(root) {
    for (const table of root.querySelectorAll("table")) {
      if (table.parentElement.classList.contains("table-wrap")) continue;
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      table.replaceWith(wrap);
      wrap.appendChild(table);
    }
  }

  function highlightCode(root) {
    const mermaidBlocks = [];
    for (const code of root.querySelectorAll("pre > code")) {
      const lang = (/(?:^|\s)language-([\w+#.-]+)/.exec(code.className) || [])[1];
      if (lang && lang.toLowerCase() === "mermaid") {
        const div = document.createElement("div");
        div.className = "mermaid";
        div.dataset.source = code.textContent;
        code.parentElement.replaceWith(div);
        mermaidBlocks.push(div);
        continue;
      }
      if (lang && window.hljs.getLanguage(lang)) {
        window.hljs.highlightElement(code);
      } else if (!lang && code.textContent.length < 20000) {
        const r = window.hljs.highlightAuto(code.textContent);
        if (r.relevance >= 5) {
          code.innerHTML = r.value;
          code.classList.add("hljs");
        }
      }
      if (lang) code.parentElement.dataset.lang = lang;
    }
    return mermaidBlocks;
  }

  // Mermaid is ~2.7 MB; only load it when a document has diagrams.
  let mermaidLoad = null;
  let mermaidTheme = null;
  function loadMermaid() {
    if (!mermaidLoad) {
      mermaidLoad = new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = scriptBase + "vendor/mermaid.min.js";
        s.onload = () => resolve(window.mermaid);
        s.onerror = () => reject(new Error("could not load Mermaid"));
        document.head.appendChild(s);
      });
    }
    return mermaidLoad;
  }

  let renderGen = 0;
  async function renderMermaid(blocks, dark, gen) {
    if (blocks.length === 0) return;
    let mermaid;
    try {
      mermaid = await loadMermaid();
    } catch (e) {
      for (const b of blocks) showMermaidError(b, e.message);
      return;
    }
    const theme = dark ? "dark" : "default";
    if (mermaidTheme !== theme) {
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme,
        fontFamily: getComputedStyle(document.body).fontFamily,
      });
      mermaidTheme = theme;
    }
    for (let i = 0; i < blocks.length; i++) {
      if (gen !== renderGen) return;
      const block = blocks[i];
      try {
        const { svg } = await mermaid.render("mermaid-" + gen + "-" + i, block.dataset.source);
        if (gen !== renderGen) return;
        block.innerHTML = svg;
      } catch (e) {
        showMermaidError(block, (e && e.message) || String(e));
        // Mermaid leaves a temporary element behind on errors.
        const stray = document.getElementById("dmermaid-" + gen + "-" + i);
        if (stray) stray.remove();
      }
    }
  }

  function showMermaidError(block, message) {
    block.classList.add("mermaid-error");
    block.innerHTML =
      '<div class="mermaid-error-title">Mermaid diagram error</div><pre>' +
      escapeHtml(message.split("\n").slice(0, 6).join("\n")) +
      "</pre><pre class=\"mermaid-source\">" + escapeHtml(block.dataset.source) + "</pre>";
  }

  function setTheme(t) {
    const root = document.documentElement.style;
    root.setProperty("--fg", t.fg);
    root.setProperty("--muted", t.muted);
    root.setProperty("--border", t.border);
    root.setProperty("--code-bg", t.codeBg);
    root.setProperty("--accent", t.accent);
    if (t.codeFont) root.setProperty("--code-font", '"' + t.codeFont.replace(/"/g, "") + '"');
    document.documentElement.dataset.theme = t.dark ? "dark" : "light";
    document.getElementById("hljs-dark").disabled = !t.dark;
    document.getElementById("hljs-light").disabled = t.dark;
  }

  async function render(src, opts) {
    const gen = ++renderGen;
    const keepY = opts.keepScroll ? window.scrollY : 0;
    if (opts.base) document.querySelector("base").href = opts.base;
    setTheme(opts);

    const { front, body } = splitFrontMatter(src);
    let html = md.render(body);
    if (front !== null) {
      html = '<pre class="front-matter"><code class="language-yaml">' + escapeHtml(front) + "</code></pre>" + html;
    }
    const doc = document.createElement("div");
    doc.innerHTML = window.DOMPurify.sanitize(html, purifyConfig);

    applyAlerts(doc);
    wrapTables(doc);
    for (const img of doc.querySelectorAll("img")) img.loading = "lazy";
    const mermaidBlocks = highlightCode(doc);

    content.replaceChildren(...doc.childNodes);
    window.scrollTo(0, keepY);

    await renderMermaid(mermaidBlocks, opts.dark, gen);
    if (gen === renderGen && opts.keepScroll) window.scrollTo(0, keepY);
  }

  // In-page links scroll instead of navigating. Other links are handled by
  // the app (external links open in the browser, .md links preview).
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href^='#']");
    if (!a) return;
    e.preventDefault();
    const id = decodeURIComponent(a.getAttribute("href").slice(1));
    const el = document.getElementById(id) || document.getElementsByName(id)[0];
    if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  window.ghosttyPreview = { render };
})();

/* Greece — Mermaid diagrams open in a zoom and pan view: drag or scroll to pan, pinch or
   ⌘-scroll to zoom, double-click to zoom in, Fit and 100%, Copy SVG. Esc closes. */
(function () {
  'use strict';
  const greece = window.greece;
  if (!greece) return;

  const ICONS = {
    expand: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M9.5 2.5h4v4M6.5 13.5h-4v-4M13.5 2.5 9 7M2.5 13.5 7 9"/></svg>',
    minus: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M3.5 8h9"/></svg>',
    plus: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M3.5 8h9M8 3.5v9"/></svg>',
    fit: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 6V3.5a1 1 0 0 1 1-1H6M10 2.5h2.5a1 1 0 0 1 1 1V6M13.5 10v2.5a1 1 0 0 1-1 1H10M6 13.5H3.5a1 1 0 0 1-1-1V10"/></svg>',
    copy: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><rect x="5.25" y="5.25" width="8.5" height="8.5" rx="1.75"/><path d="M10.75 5.25v-1.5a1.5 1.5 0 0 0-1.5-1.5h-5.5a1.5 1.5 0 0 0-1.5 1.5v5.5a1.5 1.5 0 0 0 1.5 1.5h1.5"/></svg>',
    close: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="m4 4 8 8m0-8-8 8"/></svg>',
  };

  const MIN_SCALE = 0.1;
  const MAX_SCALE = 8;

  greece.enhance('markdown', (root, kit) => {
    const blocks = root.querySelectorAll('.mermaid-block');
    if (!blocks.length) return;
    blocks.forEach((block) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'mermaid-expand';
      button.title = 'Open Diagram';
      button.setAttribute('aria-label', 'Open Diagram');
      button.innerHTML = ICONS.expand;
      block.appendChild(button);
    });

    let view = null;

    function open(block) {
      const svg = block.querySelector('pre.mermaid svg, svg');
      if (!svg || view) return;
      const box = svg.viewBox && svg.viewBox.baseVal;
      const rect = svg.getBoundingClientRect();
      const width = box && box.width ? box.width : rect.width;
      const height = box && box.height ? box.height : rect.height;
      if (!width || !height) return;

      const overlay = document.createElement('div');
      overlay.className = 'diagram-view';
      overlay.setAttribute('role', 'dialog');
      overlay.setAttribute('aria-label', 'Diagram');
      overlay.innerHTML = `
        <div class="diagram-stage"><div class="diagram-canvas"></div></div>
        <div class="diagram-bar" role="toolbar">
          <button type="button" data-act="out" title="Zoom Out (−)">${ICONS.minus}</button>
          <button type="button" data-act="actual" class="zoom-level" title="Actual Size (1)">100%</button>
          <button type="button" data-act="in" title="Zoom In (+)">${ICONS.plus}</button>
          <span class="sep"></span>
          <button type="button" data-act="fit" title="Zoom to Fit (0)">${ICONS.fit}</button>
          <button type="button" data-act="copy" class="labelled" title="Copy as SVG">${ICONS.copy}<span>Copy SVG</span></button>
          <span class="sep"></span>
          <button type="button" data-act="close" title="Close (Esc)">${ICONS.close}</button>
        </div>`;
      const stage = overlay.querySelector('.diagram-stage');
      const canvas = overlay.querySelector('.diagram-canvas');
      const level = overlay.querySelector('.zoom-level');

      // The diagram itself moves into the view (no duplicate ids), and back on close.
      const holder = svg.parentNode;
      const next = svg.nextSibling;
      const saved = { width: svg.getAttribute('width'), height: svg.getAttribute('height'), style: svg.getAttribute('style') };
      holder.style.minHeight = rect.height + 'px';
      svg.setAttribute('width', width);
      svg.setAttribute('height', height);
      svg.style.maxWidth = 'none';
      canvas.appendChild(svg);
      document.body.appendChild(overlay);
      document.documentElement.classList.add('diagram-open');

      let scale = 1;
      let x = 0;
      let y = 0;
      const apply = () => {
        canvas.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;
        level.textContent = Math.round(scale * 100) + '%';
      };
      const zoomAt = (factor, px, py) => {
        const target = Math.max(MIN_SCALE, Math.min(MAX_SCALE, scale * factor));
        const k = target / scale;
        x = px - (px - x) * k;
        y = py - (py - y) * k;
        scale = target;
        apply();
      };
      const center = () => { const r = stage.getBoundingClientRect(); return [r.width / 2, r.height / 2]; };
      const fit = () => {
        const r = stage.getBoundingClientRect();
        scale = Math.max(MIN_SCALE, Math.min(3, (r.width - 64) / width, (r.height - 64) / height));
        x = (r.width - width * scale) / 2;
        y = (r.height - height * scale) / 2;
        apply();
      };
      const actual = () => {
        const r = stage.getBoundingClientRect();
        scale = 1;
        x = (r.width - width) / 2;
        y = Math.max(32, (r.height - height) / 2);
        apply();
      };
      fit();

      // Panning
      let drag = null;
      stage.addEventListener('pointerdown', (event) => {
        if (event.button !== 0) return;
        drag = { id: event.pointerId, sx: event.clientX, sy: event.clientY, x, y };
        try { stage.setPointerCapture(event.pointerId); } catch (_) { }
        stage.classList.add('dragging');
      });
      stage.addEventListener('pointermove', (event) => {
        if (!drag || event.pointerId !== drag.id) return;
        x = drag.x + event.clientX - drag.sx;
        y = drag.y + event.clientY - drag.sy;
        apply();
      });
      const stop = () => { drag = null; stage.classList.remove('dragging'); };
      stage.addEventListener('pointerup', stop);
      stage.addEventListener('pointercancel', stop);
      stage.addEventListener('dblclick', (event) => {
        const r = stage.getBoundingClientRect();
        zoomAt(event.altKey ? 0.5 : 2, event.clientX - r.left, event.clientY - r.top);
      });

      // Scrolling pans; pinching (or ⌘/⌃-scrolling) zooms around the pointer.
      stage.addEventListener('wheel', (event) => {
        event.preventDefault();
        const r = stage.getBoundingClientRect();
        if (event.ctrlKey || event.metaKey) {
          zoomAt(Math.exp(-event.deltaY * (event.deltaMode === 1 ? 0.05 : 0.0035)), event.clientX - r.left, event.clientY - r.top);
        } else {
          x -= event.deltaX;
          y -= event.deltaY;
          apply();
        }
      }, { passive: false });
      let gestureScale = 1;
      stage.addEventListener('gesturestart', (event) => { event.preventDefault(); gestureScale = 1; });
      stage.addEventListener('gesturechange', (event) => {
        event.preventDefault();
        const r = stage.getBoundingClientRect();
        zoomAt(event.scale / gestureScale, event.clientX - r.left, event.clientY - r.top);
        gestureScale = event.scale;
      });

      const close = () => {
        overlay.remove();
        document.documentElement.classList.remove('diagram-open');
        ['width', 'height', 'style'].forEach((name) => {
          if (saved[name] == null) svg.removeAttribute(name); else svg.setAttribute(name, saved[name]);
        });
        holder.insertBefore(svg, next && next.parentNode === holder ? next : null);
        holder.style.minHeight = '';
        document.removeEventListener('keydown', keys, true);
        view = null;
      };

      overlay.querySelector('.diagram-bar').addEventListener('click', (event) => {
        const button = event.target.closest('button');
        if (!button) return;
        const act = button.dataset.act;
        if (act === 'in') zoomAt(1.25, ...center());
        else if (act === 'out') zoomAt(0.8, ...center());
        else if (act === 'fit') fit();
        else if (act === 'actual') actual();
        else if (act === 'close') close();
        else if (act === 'copy') {
          const markup = new XMLSerializer().serializeToString(svg)
            .replace(/ style="max-width: none;?"/, '');
          kit.copyText('<?xml version="1.0" encoding="UTF-8"?>\n' + markup);
          const labelNode = button.querySelector('span');
          labelNode.textContent = 'Copied';
          button.classList.add('done');
          clearTimeout(button._t);
          button._t = setTimeout(() => { labelNode.textContent = 'Copy SVG'; button.classList.remove('done'); }, 1400);
        }
      });

      function keys(event) {
        if (event.key === 'Escape') close();
        else if (event.key === '+' || event.key === '=') zoomAt(1.25, ...center());
        else if (event.key === '-' || event.key === '_') zoomAt(0.8, ...center());
        else if (event.key === '0') fit();
        else if (event.key === '1') actual();
        else return;
        event.preventDefault();
        event.stopPropagation();
      }
      document.addEventListener('keydown', keys, true);
      view = { close, fit };
    }

    window.addEventListener('resize', () => { if (view) view.fit(); });
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (view) view.close(); });

    root.addEventListener('click', (event) => {
      const block = event.target.closest('.mermaid-block');
      if (!block || event.target.closest('a')) return;
      if (!event.target.closest('.mermaid-expand') && window.getSelection && String(window.getSelection())) return;
      open(block);
    });
  });
})();

/* Greece — a better outline: drag its edge to resize, hide it (remembered for this document),
   open it as a floating panel when the window is too narrow for a sidebar, keep the current
   section in view, and show task-list progress in its header. */
(function () {
  'use strict';
  const greece = window.greece;
  if (!greece) return;

  const MIN = 160;
  const MAX = 440;
  const DEFAULT = 208;

  const store = {
    get(key) { try { return window.localStorage.getItem(key); } catch (_) { return null; } },
    set(key, value) { try { if (value == null) window.localStorage.removeItem(key); else window.localStorage.setItem(key, value); } catch (_) { } },
  };

  const ICON_SIDEBAR = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.25"><rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2.25"/><path d="M10 2.9v10.2"/><path d="M11.6 5.4h1.2M11.6 7.4h1.2M11.6 9.4h1.2" stroke-linecap="round"/></svg>';
  const ICON_LIST = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><path d="M5.5 4h8M5.5 8h8M7.5 12h6"/><path d="M2.5 4h.2M2.5 8h.2M4.5 12h.2" stroke-width="2"/></svg>';

  function taskProgress(article) {
    const tasks = article.querySelectorAll('li.task-list-item');
    if (!tasks.length) return '';
    const done = article.querySelectorAll('li.task-list-item.done').length;
    const percent = Math.round((done / tasks.length) * 100);
    const label = done === tasks.length ? `All ${tasks.length} done` : `${done} of ${tasks.length} done`;
    return `<div class="outline-tasks${done === tasks.length ? ' complete' : ''}" title="Task lists in this document"><span>${label}</span><span class="outline-meter"><i style="width:${percent}%"></i></span></div>`;
  }

  greece.enhance('markdown', (root, kit) => {
    const doc = root.querySelector('.doc.has-outline');
    const nav = doc && doc.querySelector(':scope > nav.outline');
    const article = doc && doc.querySelector(':scope > article');
    if (!nav || !article) return;
    const pageKey = 'greece.outline.hidden:' + (kit.fileName || location.pathname);

    // Header, progress, and a scroll area for the links.
    const title = nav.querySelector(':scope > .title');
    const head = document.createElement('div');
    head.className = 'outline-head';
    head.innerHTML = `<p class="title">${kit.esc(title ? title.textContent : 'On This Page')}</p><button type="button" class="outline-button outline-hide" title="Hide Outline" aria-label="Hide Outline">${ICON_SIDEBAR}</button>`;
    if (title) title.remove();
    const list = document.createElement('div');
    list.className = 'outline-scroll';
    while (nav.firstChild) list.appendChild(nav.firstChild);
    nav.appendChild(head);
    const progress = taskProgress(article);
    if (progress) nav.insertAdjacentHTML('beforeend', progress);
    nav.appendChild(list);
    nav.classList.add('enhanced');

    const handle = document.createElement('div');
    handle.className = 'outline-resizer';
    handle.setAttribute('role', 'separator');
    handle.setAttribute('aria-orientation', 'vertical');
    // Quick Look opens the file on any double-click, so it only advertises dragging there.
    handle.title = kit.typing ? 'Drag to resize. Double-click to reset.' : 'Drag to resize';
    nav.appendChild(handle);

    const show = document.createElement('button');
    show.type = 'button';
    show.className = 'outline-button outline-show';
    show.title = 'Show Outline';
    show.setAttribute('aria-label', 'Show Outline');
    show.innerHTML = ICON_LIST;
    document.body.appendChild(show);

    // Width
    let width = Number(store.get('greece.outline.width')) || DEFAULT;
    const applyWidth = (w) => { width = Math.max(MIN, Math.min(MAX, Math.round(w))); doc.style.setProperty('--outline-w', width + 'px'); };
    applyWidth(width);

    let drag = null;
    handle.addEventListener('pointerdown', (event) => {
      if (event.button !== 0) return;
      event.preventDefault();
      try { handle.setPointerCapture(event.pointerId); } catch (_) { }
      // How far the edge moves per pixel of width depends on whether the page is centred.
      drag = { ratio: -0.5 };
      doc.classList.add('outline-resizing');
    });
    handle.addEventListener('pointermove', (event) => {
      if (!drag) return;
      const edge = () => { const r = handle.getBoundingClientRect(); return r.left + r.width / 2; };
      const before = edge();
      const next = Math.max(MIN, Math.min(MAX, width + (event.clientX - before) / drag.ratio));
      if (Math.abs(next - width) < 0.5) return;
      const old = width;
      applyWidth(next);
      const moved = edge() - before;
      if (width !== old && Math.abs(moved) > 0.5) drag.ratio = Math.max(-1.5, Math.min(-0.25, moved / (width - old)));
    });
    const endDrag = () => {
      if (!drag) return;
      drag = null;
      doc.classList.remove('outline-resizing');
      store.set('greece.outline.width', width === DEFAULT ? null : String(width));
    };
    handle.addEventListener('pointerup', endDrag);
    handle.addEventListener('pointercancel', endDrag);
    handle.addEventListener('dblclick', () => { applyWidth(DEFAULT); store.set('greece.outline.width', null); });

    // Hidden (sidebar) and floating (narrow windows) states.
    // Asked afresh each time: a stored MediaQueryList only updates when the page renders.
    const MEDIA = '(max-width: 1080px)';
    const isNarrow = () => window.matchMedia(MEDIA).matches;
    const setHidden = (hidden) => {
      doc.classList.toggle('outline-collapsed', hidden);
      store.set(pageKey, hidden ? '1' : null);
    };
    const setFloating = (on) => {
      doc.classList.toggle('outline-floating', on);
      show.classList.toggle('active', on);
      if (on) {
        const active = list.querySelector('a.active');
        if (active) active.scrollIntoView({ block: 'nearest' });
      }
    };
    if (store.get(pageKey) === '1') setHidden(true);

    head.querySelector('.outline-hide').addEventListener('click', () => {
      if (isNarrow()) setFloating(false); else setHidden(true);
    });
    show.addEventListener('click', () => {
      if (isNarrow()) setFloating(!doc.classList.contains('outline-floating'));
      else setHidden(false);
    });
    window.matchMedia(MEDIA).addEventListener('change', () => setFloating(false));

    // The outline from the context menu too: a right-click away wherever the pointer is.
    greece.contextMenu(() => {
      if (String(window.getSelection() || '')) return null;
      const shown = isNarrow() ? doc.classList.contains('outline-floating') : !doc.classList.contains('outline-collapsed');
      return [{ title: 'Outline', checked: shown, run: () => (isNarrow() ? setFloating(!shown) : setHidden(shown)) }];
    });
    list.addEventListener('click', (event) => { if (event.target.closest('a') && isNarrow()) setFloating(false); });
    document.addEventListener('pointerdown', (event) => {
      if (doc.classList.contains('outline-floating') && !nav.contains(event.target) && !show.contains(event.target)) setFloating(false);
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && doc.classList.contains('outline-floating')) setFloating(false);
    });

    // Keep the current section visible in a long outline.
    new MutationObserver(() => {
      const active = list.querySelector('a.active');
      if (!active || list.scrollHeight <= list.clientHeight) return;
      const top = active.offsetTop - list.offsetTop;
      if (top < list.scrollTop || top + active.offsetHeight > list.scrollTop + list.clientHeight) {
        list.scrollTop = Math.max(0, top - list.clientHeight / 3);
      }
    }).observe(list, { subtree: true, attributes: true, attributeFilter: ['class'] });
  });
})();

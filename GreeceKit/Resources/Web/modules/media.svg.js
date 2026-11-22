/* Greece — SVG viewer. The drawing is an <img> from greece://module, so the file's scripts never run
   and nothing it references is loaded. Fit, zoom and pan (pinch, scroll, drag), 1:1, a transparency
   checkerboard, and the highlighted source. */
(function () {
  'use strict';
  const M = window.GreeceMedia;
  const { el } = M;

  window.greece.register('media-svg', async (info, kit) => {
    const root = kit.root;
    const stage = el('div', { class: 'stage checker', role: 'img', 'aria-label': info.title || kit.t('SVG image') });
    const frame = el('div', { class: 'frame' });
    const image = new Image();
    image.alt = '';
    image.draggable = false;
    image.decoding = 'sync';
    image.crossOrigin = 'anonymous';
    stage.append(image, frame);
    root.appendChild(stage);

    try {
      image.src = 'greece://module/image.svg';
      await image.decode();
    } catch (_) {
      stage.remove();
      root.appendChild(el('div', { class: 'empty', text: kit.t('This SVG couldn’t be drawn.') }));
      return;
    }

    const natural = { w: info.width, h: info.height };
    const view = { scale: 1, x: 0, y: 0, fitted: true };
    const MIN = 0.01, MAX = 64;
    const TOP = 52, PAD = 28;

    function fitScale() {
      const w = Math.max(stage.clientWidth - PAD * 2, 40), h = Math.max(stage.clientHeight - TOP - PAD, 40);
      return Math.min(w / natural.w, h / natural.h, MAX);
    }

    function apply() {
      // Size the image itself rather than scaling it, so vectors are redrawn sharp at every zoom.
      const w = natural.w * view.scale, h = natural.h * view.scale;
      const limit = 24000;
      const shrink = Math.max(w, h) > limit ? limit / Math.max(w, h) : 1;
      image.style.width = (w * shrink) + 'px';
      image.style.height = (h * shrink) + 'px';
      image.style.transform = `translate(${view.x}px, ${view.y}px)` + (shrink < 1 ? ` scale(${1 / shrink})` : '');
      frame.style.width = w + 'px';
      frame.style.height = h + 'px';
      frame.style.transform = `translate(${view.x}px, ${view.y}px)`;
      zoomLabel.textContent = kit.number(Math.round(view.scale * 100) / 100, { style: 'percent' });
      fitButton.classList.toggle('on', view.fitted);
      actualButton.classList.toggle('on', Math.abs(view.scale - 1) < 0.001);
    }

    function center(scale) {
      view.scale = scale;
      view.x = (stage.clientWidth - natural.w * scale) / 2;
      view.y = TOP / 2 + (stage.clientHeight - natural.h * scale) / 2;
      apply();
    }

    function fit() { view.fitted = true; center(fitScale()); }
    function actual() { view.fitted = false; center(1); }

    function zoomAt(factor, cx, cy) {
      const next = Math.min(MAX, Math.max(MIN, view.scale * factor));
      if (cx == null) { cx = stage.clientWidth / 2; cy = stage.clientHeight / 2; }
      view.x = cx - (cx - view.x) * (next / view.scale);
      view.y = cy - (cy - view.y) * (next / view.scale);
      view.scale = next;
      view.fitted = false;
      apply();
    }

    // -------------------------------------------------------------- Toolbar
    const zoomLabel = el('button', { class: 'm-button wide', type: 'button', title: kit.t('Actual size') });
    zoomLabel.addEventListener('click', actual);
    const fitButton = M.button({ icon: 'fit', title: `${kit.t('Fit to window')} (F)`, onClick: fit });
    const actualButton = M.button({ icon: 'actual', title: `${kit.t('Actual size')} (0)`, onClick: actual });
    const checkerButton = M.button({ icon: 'checker', title: `${kit.t('Transparency checkerboard')} (T)` });
    const sourceButton = M.button({ icon: 'code', title: `${kit.t('Source [code]')} (S)` });
    const tools = el('div', { class: 'svg-tools m-bar' }, [
      M.button({ icon: 'minus', title: `${kit.t('Zoom out')} (−)`, onClick: () => zoomAt(1 / 1.25) }),
      zoomLabel,
      M.button({ icon: 'plus', title: `${kit.t('Zoom in')} (+)`, onClick: () => zoomAt(1.25) }),
      el('span', { class: 'm-sep' }),
      fitButton, actualButton,
      el('span', { class: 'm-sep' }),
      checkerButton, sourceButton,
    ]);
    root.appendChild(tools);

    // ----------------------------------------------------------- Background
    // Black icons vanish on a dark page and white ones on a light page: pick a checkerboard
    // that keeps the drawing visible, then let the toggle turn it off.
    let checker = true;
    function paintBackground() {
      stage.classList.toggle('checker', checker);
      stage.style.removeProperty('--m-check-a');
      stage.style.removeProperty('--m-check-b');
      stage.style.background = '';
      const tone = measured && measured.coverage < 0.97 ? measured.lightness : null;
      const dark = M.isDark();
      let wantLight = null;
      if (tone != null && dark && tone < 0.28) wantLight = true;
      if (tone != null && !dark && tone > 0.86) wantLight = false;
      if (checker && wantLight === true) { stage.style.setProperty('--m-check-a', '#ffffff'); stage.style.setProperty('--m-check-b', '#e6e6e9'); }
      if (checker && wantLight === false) { stage.style.setProperty('--m-check-a', '#2b2b2e'); stage.style.setProperty('--m-check-b', '#222225'); }
      if (!checker) stage.style.background = wantLight === true ? '#ffffff' : wantLight === false ? '#1c1c1e' : 'var(--page)';
      checkerButton.classList.toggle('on', checker);
    }
    const measured = M.measureLightness(image, natural.w, natural.h);
    checkerButton.addEventListener('click', () => { checker = !checker; paintBackground(); });
    if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', paintBackground);
    paintBackground();

    // --------------------------------------------------------------- Source
    let source = null;
    async function toggleSource() {
      if (source) {
        const hidden = source.classList.toggle('m-hidden');
        sourceButton.classList.toggle('on', !hidden);
        return;
      }
      sourceButton.classList.add('on');
      source = el('div', { class: 'svg-source' });
      const notes = [];
      if (info.hasScripts) notes.push(kit.t('This file contains scripts. Greece shows SVG as an image, so they never run.'));
      if (info.hasExternalReferences) notes.push(kit.t('It refers to files or web addresses, which previews don’t load.'));
      for (const note of notes) source.appendChild(el('div', { class: 'm-note', text: note }));
      const pre = el('pre', { class: 'hljs' });
      source.appendChild(pre);
      root.appendChild(source);
      try {
        const text = await M.fetchText('source.txt');
        pre.innerHTML = text.length <= 1500000 ? kit.highlight(text, 'xml') : kit.esc(text);
        if (info.bytes > text.length * 1.01 && info.bytes > 8 * 1024 * 1024) source.appendChild(el('div', { class: 'm-note', text: kit.t('Showing the first {0}.', kit.t('{0} MB', 8)) }));
      } catch (_) {
        pre.textContent = kit.t('The source couldn’t be read.');
      }
    }
    sourceButton.addEventListener('click', toggleSource);

    // ------------------------------------------------------------ Gestures
    let drag = null;
    stage.addEventListener('pointerdown', (event) => {
      if (event.button !== 0) return;
      drag = { x: event.clientX, y: event.clientY, ox: view.x, oy: view.y };
      stage.setPointerCapture(event.pointerId);
      stage.classList.add('dragging');
    });
    stage.addEventListener('pointermove', (event) => {
      if (!drag) return;
      view.x = drag.ox + event.clientX - drag.x;
      view.y = drag.oy + event.clientY - drag.y;
      view.fitted = false;
      apply();
    });
    const endDrag = () => { drag = null; stage.classList.remove('dragging'); };
    stage.addEventListener('pointerup', endDrag);
    stage.addEventListener('pointercancel', endDrag);
    stage.addEventListener('dblclick', (event) => {
      if (view.fitted || Math.abs(view.scale - fitScale()) < 0.001) {
        // To actual size, keeping the point under the pointer still.
        zoomAt(1 / view.scale, event.clientX, event.clientY);
      } else {
        fit();
      }
    });

    // Trackpad: two-finger scroll pans, pinch zooms (as ctrl+wheel, or Safari's gesture events).
    stage.addEventListener('wheel', (event) => {
      event.preventDefault();
      if (event.ctrlKey || event.metaKey) {
        zoomAt(Math.exp(-event.deltaY * 0.01), event.clientX, event.clientY);
      } else {
        view.x -= event.deltaX;
        view.y -= event.deltaY;
        view.fitted = false;
        apply();
      }
    }, { passive: false });
    let gestureStart = 1;
    stage.addEventListener('gesturestart', (event) => { event.preventDefault(); gestureStart = view.scale; });
    stage.addEventListener('gesturechange', (event) => {
      event.preventDefault();
      zoomAt((gestureStart * event.scale) / view.scale, event.clientX, event.clientY);
    });
    stage.addEventListener('gestureend', (event) => event.preventDefault());

    document.addEventListener('keydown', (event) => {
      if (event.target.closest && event.target.closest('input, textarea')) return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      switch (event.key) {
        case '+': case '=': zoomAt(1.25); break;
        case '-': case '_': zoomAt(1 / 1.25); break;
        case '0': case '1': actual(); break;
        case 'f': case 'F': fit(); break;
        case 't': case 'T': checkerButton.click(); break;
        case 's': case 'S': toggleSource(); break;
        default: return;
      }
      event.preventDefault();
    });

    window.addEventListener('resize', () => { if (view.fitted) fit(); });
    fit();
  });
})();

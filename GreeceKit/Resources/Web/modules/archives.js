/* Greece — comic books. Pages come from the archive on demand at greece://module/thumb/<n> and
   greece://module/page/<n>; nothing from the file reaches the page except escaped text. */
(function () {
  'use strict';

  greece.register('comic', async (data, kit) => {
    const { esc, root } = kit;
    const pages = data.pages || [];
    const thumb = (index, width) => `greece://module/thumb/${index}?w=${width}`;
    const full = (index) => `greece://module/page/${index}`;
    const scale = Math.min(2, window.devicePixelRatio || 1);

    const facts = (data.facts || []).map((fact) => `<span>${esc(fact)}</span>`).join('');
    root.innerHTML = `
      <div class="comic">
        <header class="comic-hero">
          <div class="comic-cover" data-page="0" role="button" aria-label="Read from the cover">
            ${pages.length ? `<img src="${thumb(0, Math.round(220 * scale))}" alt="">` : ''}
          </div>
          <div class="comic-meta">
            <div class="comic-eyebrow">${esc(data.eyebrow)}</div>
            <h1>${esc(data.title)}</h1>
            ${data.subtitle ? `<p class="comic-subtitle">${esc(data.subtitle)}</p>` : ''}
            <p class="comic-facts">${facts}</p>
            ${data.summary ? `<p class="comic-summary">${esc(data.summary)}</p>` : ''}
            <button class="comic-read" data-page="0">Read</button>
          </div>
        </header>
        <h2 class="comic-section">Pages</h2>
        <div class="comic-grid"></div>
      </div>
      <div class="comic-reader" aria-hidden="true">
        <div class="stage"><img alt=""></div>
        <div class="side left"></div><div class="side right"></div>
        <button class="close" aria-label="Close">✕</button>
        <div class="bar">
          <button class="previous" aria-label="Previous page">‹</button>
          <span class="position"></span>
          <button class="next" aria-label="Next page">›</button>
        </div>
      </div>`;

    // Thumbnails load as they scroll into view.
    const grid = root.querySelector('.comic-grid');
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const img = entry.target.querySelector('img');
        if (img && !img.src) img.src = img.dataset.src;
        observer.unobserve(entry.target);
      }
    }, { rootMargin: '600px 0px' });
    const fragment = document.createDocumentFragment();
    pages.forEach((page, index) => {
      const figure = document.createElement('figure');
      figure.className = 'comic-page';
      figure.dataset.page = String(index);
      figure.title = page.name;
      figure.innerHTML = `<div class="comic-thumb"><img alt="" data-src="${thumb(index, Math.round(160 * scale))}"></div>
        <figcaption>${index + 1}</figcaption>`;
      const img = figure.querySelector('img');
      fragment.appendChild(figure);
      // The first screenful loads straight away (Quick Look renders before the page is on screen,
      // where intersection callbacks wait); the rest as they scroll into view.
      if (index < 18) img.src = img.dataset.src;
      else observer.observe(figure);
    });
    grid.appendChild(fragment);

    // Reader.
    const reader = root.querySelector('.comic-reader');
    const image = reader.querySelector('.stage img');
    const position = reader.querySelector('.position');
    const previous = reader.querySelector('.previous');
    const next = reader.querySelector('.next');
    const step = data.rightToLeft ? -1 : 1;
    let current = 0;

    function show(index) {
      current = Math.max(0, Math.min(pages.length - 1, index));
      image.src = full(current);
      position.textContent = `${current + 1} of ${pages.length}`;
      previous.disabled = current === 0;
      next.disabled = current === pages.length - 1;
      // Warm the next page so turning is instant.
      if (current + 1 < pages.length) new Image().src = full(current + 1);
    }
    function open(index) {
      if (!pages.length) return;
      reader.classList.add('open');
      reader.setAttribute('aria-hidden', 'false');
      show(index);
    }
    function close() {
      reader.classList.remove('open');
      reader.setAttribute('aria-hidden', 'true');
    }

    root.addEventListener('click', (event) => {
      const target = event.target.closest('[data-page]');
      if (target && !reader.contains(target)) open(Number(target.dataset.page) || 0);
    });
    reader.querySelector('.close').addEventListener('click', close);
    previous.addEventListener('click', () => show(current - 1));
    next.addEventListener('click', () => show(current + 1));
    reader.querySelector('.side.left').addEventListener('click', () => show(current - step));
    reader.querySelector('.side.right').addEventListener('click', () => show(current + step));
    document.addEventListener('keydown', (event) => {
      if (!reader.classList.contains('open')) {
        if (event.key === 'Enter') open(0);
        return;
      }
      if (event.key === 'Escape') { close(); event.preventDefault(); }
      else if (event.key === 'ArrowRight' || event.key === ' ' || event.key === 'PageDown') { show(current + (event.key === 'ArrowRight' ? step : 1)); event.preventDefault(); }
      else if (event.key === 'ArrowLeft' || event.key === 'PageUp') { show(current - (event.key === 'ArrowLeft' ? step : 1)); event.preventDefault(); }
      else if (event.key === 'Home') show(0);
      else if (event.key === 'End') show(pages.length - 1);
    });

    // Quick Look shows the page once this resolves: give the cover a moment so it's there from the first frame.
    const cover = root.querySelector('.comic-cover img');
    if (cover && !cover.complete) {
      await new Promise((resolve) => {
        cover.addEventListener('load', resolve, { once: true });
        cover.addEventListener('error', resolve, { once: true });
        setTimeout(resolve, 900);
      });
    }
  });
})();

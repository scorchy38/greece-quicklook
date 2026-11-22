/* Greece — click an image to see it large; arrows step through the document's images. */
(function () {
  'use strict';
  const greece = window.greece;
  if (!greece) return;

  const ICONS = {
    prev: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3 5 8l5 5"/></svg>',
    next: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="m6 3 5 5-5 5"/></svg>',
    close: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="m4 4 8 8m0-8-8 8"/></svg>',
  };

  greece.enhance('markdown', (root, kit) => {
    const article = root.querySelector('.doc > article');
    if (!article) return;
    const candidates = () => Array.from(article.querySelectorAll('img')).filter((img) => !img.closest('a') && img.getAttribute('src'));
    if (!candidates().length) return;
    article.classList.add('has-lightbox');

    let box = null;

    function show(images, index) {
      const img = images[index];
      const large = box.querySelector('.lightbox-image');
      large.src = img.currentSrc || img.src;
      large.alt = img.alt || '';
      const caption = img.getAttribute('title') || img.alt || '';
      box.querySelector('.lightbox-caption').textContent = caption;
      box.querySelector('.lightbox-count').textContent = images.length > 1 ? `${index + 1} of ${images.length}` : '';
      box.querySelector('.lightbox-prev').disabled = index === 0;
      box.querySelector('.lightbox-next').disabled = index === images.length - 1;
      box.dataset.index = String(index);
    }

    function open(target) {
      const images = candidates();
      const index = images.indexOf(target);
      if (index < 0) return;
      box = document.createElement('div');
      box.className = 'lightbox';
      box.setAttribute('role', 'dialog');
      box.setAttribute('aria-label', 'Image');
      box.innerHTML = `
        <img class="lightbox-image" alt="">
        <button type="button" class="lightbox-button lightbox-close" title="Close (Esc)" aria-label="Close">${ICONS.close}</button>
        ${images.length > 1 ? `<button type="button" class="lightbox-button lightbox-prev" title="Previous (←)" aria-label="Previous">${ICONS.prev}</button>
        <button type="button" class="lightbox-button lightbox-next" title="Next (→)" aria-label="Next">${ICONS.next}</button>` : '<span class="lightbox-prev" hidden></span><span class="lightbox-next" hidden></span>'}
        <div class="lightbox-footer"><span class="lightbox-caption"></span><span class="lightbox-count"></span></div>`;
      document.body.appendChild(box);
      document.documentElement.classList.add('lightbox-open');
      show(images, index);

      const step = (delta) => {
        const next = Number(box.dataset.index) + delta;
        if (next >= 0 && next < images.length) show(images, next);
      };
      const close = () => {
        if (!box) return;
        box.remove();
        box = null;
        document.documentElement.classList.remove('lightbox-open');
        document.removeEventListener('keydown', keys, true);
      };
      function keys(event) {
        if (event.key === 'Escape') close();
        else if (event.key === 'ArrowLeft') step(-1);
        else if (event.key === 'ArrowRight') step(1);
        else return;
        event.preventDefault();
        event.stopPropagation();
      }
      document.addEventListener('keydown', keys, true);
      box.addEventListener('click', (event) => {
        if (event.target.closest('.lightbox-prev')) step(-1);
        else if (event.target.closest('.lightbox-next')) step(1);
        else if (event.target.closest('.lightbox-close') || !event.target.closest('.lightbox-image, .lightbox-footer')) close();
      });
    }

    article.addEventListener('click', (event) => {
      const img = event.target.closest('img');
      if (!img || img.closest('a') || !article.contains(img)) return;
      event.preventDefault();
      open(img);
    });
  });
})();

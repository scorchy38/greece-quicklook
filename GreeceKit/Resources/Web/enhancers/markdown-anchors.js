/* Greece — a link button beside each heading on hover; clicking it copies a link to that section. */
(function () {
  'use strict';
  const greece = window.greece;
  if (!greece) return;

  const ICON = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M6.9 9.1a2.6 2.6 0 0 0 3.7 0l2.2-2.2a2.6 2.6 0 0 0-3.7-3.7l-.9.9"/><path d="M9.1 6.9a2.6 2.6 0 0 0-3.7 0L3.2 9.1a2.6 2.6 0 0 0 3.7 3.7l.9-.9"/></svg>';

  /** The file's own URL (file://…/README.md) plus the section. */
  function sectionURL(kit, id) {
    try {
      const page = new URL(encodeURIComponent(kit.fileName || ''), document.baseURI);
      if (page.protocol === 'greece:' && page.host === 'file' && kit.fileName) return 'file://' + page.pathname + '#' + encodeURIComponent(id);
    } catch (_) { }
    return '#' + encodeURIComponent(id);
  }

  greece.enhance('markdown', (root, kit) => {
    const article = root.querySelector('.doc > article');
    if (!article) return;
    article.querySelectorAll('h1[id], h2[id], h3[id], h4[id], h5[id], h6[id]').forEach((heading) => {
      const anchor = document.createElement('a');
      anchor.className = 'heading-anchor';
      anchor.href = '#' + encodeURIComponent(heading.id);
      anchor.setAttribute('aria-label', kit.t('Copy Link to Section'));
      anchor.title = kit.t('Copy Link to Section');
      anchor.innerHTML = ICON;
      heading.insertBefore(anchor, heading.firstChild);
      heading.classList.add('has-anchor');
    });

    article.addEventListener('click', (event) => {
      const anchor = event.target.closest('.heading-anchor');
      if (!anchor) return;
      const heading = anchor.parentElement;
      kit.copyText(sectionURL(kit, heading.id));
      let tip = anchor.querySelector('.anchor-tip');
      if (!tip) {
        tip = document.createElement('span');
        tip.className = 'anchor-tip';
        tip.textContent = kit.t('Link Copied');
        anchor.appendChild(tip);
      }
      anchor.classList.add('copied');
      clearTimeout(anchor._t);
      anchor._t = setTimeout(() => anchor.classList.remove('copied'), 1300);
    });
  });
})();

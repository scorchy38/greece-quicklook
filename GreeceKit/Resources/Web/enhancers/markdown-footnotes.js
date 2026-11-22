/* Greece — hovering a footnote reference shows the note right there. */
(function () {
  'use strict';
  const greece = window.greece;
  if (!greece) return;

  greece.enhance('markdown', (root) => {
    const article = root.querySelector('.doc > article');
    if (!article || !article.querySelector('.footnote-ref a')) return;

    const pop = document.createElement('div');
    pop.className = 'footnote-pop';
    pop.setAttribute('role', 'tooltip');
    pop.hidden = true;
    document.body.appendChild(pop);
    let current = null;
    let hideTimer = 0;

    function show(link) {
      clearTimeout(hideTimer);
      if (current === link && !pop.hidden) return;
      let id = (link.getAttribute('href') || '').slice(1);
      try { id = decodeURIComponent(id); } catch (_) { }
      const note = id && document.getElementById(id);
      if (!note) return;
      const copy = note.cloneNode(true);
      copy.querySelectorAll('.footnote-backref').forEach((a) => a.remove());
      copy.querySelectorAll('[id]').forEach((el) => el.removeAttribute('id'));
      pop.innerHTML = '';
      while (copy.firstChild) pop.appendChild(copy.firstChild);
      current = link;
      pop.hidden = false;
      pop.classList.remove('above');
      const anchor = link.getBoundingClientRect();
      const width = pop.offsetWidth;
      const height = pop.offsetHeight;
      const left = Math.max(12, Math.min(anchor.left + anchor.width / 2 - width / 2, window.innerWidth - width - 12));
      let top = anchor.bottom + 8;
      if (top + height > window.innerHeight - 8 && anchor.top - height - 8 > 8) {
        top = anchor.top - height - 8;
        pop.classList.add('above');
      }
      pop.style.left = left + window.scrollX + 'px';
      pop.style.top = top + window.scrollY + 'px';
    }
    function hideSoon() {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => { pop.hidden = true; current = null; }, 160);
    }

    article.addEventListener('mouseover', (event) => {
      const link = event.target.closest('.footnote-ref a');
      if (link) show(link);
    });
    article.addEventListener('mouseout', (event) => {
      if (event.target.closest('.footnote-ref a')) hideSoon();
    });
    article.addEventListener('focusin', (event) => {
      const link = event.target.closest('.footnote-ref a');
      if (link) show(link);
    });
    article.addEventListener('focusout', (event) => { if (event.target.closest('.footnote-ref a')) hideSoon(); });
    pop.addEventListener('mouseenter', () => clearTimeout(hideTimer));
    pop.addEventListener('mouseleave', hideSoon);
    window.addEventListener('scroll', () => { if (!pop.hidden && !pop.matches(':hover')) { pop.hidden = true; current = null; } }, { passive: true });
    document.addEventListener('keydown', (event) => { if (event.key === 'Escape') { pop.hidden = true; current = null; } });
  });
})();

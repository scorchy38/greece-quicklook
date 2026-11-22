/* Greece — a slim reading-progress line along the top of long documents. */
(function () {
  'use strict';
  const greece = window.greece;
  if (!greece) return;

  greece.enhance('markdown', (root) => {
    if (!root.querySelector('.doc')) return;
    const bar = document.createElement('div');
    bar.className = 'read-progress';
    bar.setAttribute('aria-hidden', 'true');
    document.body.appendChild(bar);

    // Measured from the events themselves: Quick Look's hidden pages barely run timers.
    function update() {
      const range = document.documentElement.scrollHeight - window.innerHeight;
      const long = range > window.innerHeight * 0.6;
      bar.classList.toggle('on', long && window.scrollY > 2);
      if (long) bar.style.transform = `scaleX(${Math.min(1, Math.max(0, window.scrollY / range))})`;
    }
    window.addEventListener('scroll', update, { passive: true });
    window.addEventListener('resize', update, { passive: true });
    update();
  });
})();

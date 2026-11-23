/* Greece — wrap lines inside the preview (⌥Z, as in VS Code), keeping your place. The setting in
   Greece still decides how files open; this only changes the one you're looking at. */
(function () {
  'use strict';
  if (!window.greece) return;

  greece.enhance('code', (root, kit) => {
    const G = window.greeceCode;
    if (!G) return;
    const html = document.documentElement;

    const button = G.addTool({ icon: 'wrap', label: kit.t('Wrap Lines'), title: kit.t('Wrap Lines') + ' (⌥Z)', order: 30, onClick: () => toggle() });
    const sync = () => {
      const on = html.classList.contains('wrap');
      if (button) { button.classList.toggle('on', on); button.setAttribute('aria-pressed', String(on)); }
    };

    function toggle() {
      if (G.mode === 'tree') return;
      const top = G.lineAt(G.inset + (G.stickyHeight || 0) + 2);
      html.classList.toggle('wrap');
      sync();
      if (top > 0) {
        const el = G.lineElement(top);
        if (el) window.scrollTo(0, Math.max(0, el.getBoundingClientRect().top + window.scrollY - G.inset - (G.stickyHeight || 0)));
      } else if (top === 0) window.scrollTo(0, 0);
      G.emit('wrap');
    }

    G.addKeys((event) => {
      if (event.altKey && !event.metaKey && !event.ctrlKey && event.code === 'KeyZ' && G.mode !== 'tree' && !G.typing()) { toggle(); return true; }
      return false;
    });
    kit.onApply(sync);
    sync();
    G.wrap = { toggle };
  });
})();

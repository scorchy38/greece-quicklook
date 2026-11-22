/* Greece — content tabs as a segmented control. markdown-syntax.js renders the panels
   (`.md-tabs > section.md-tab[data-label]`); this adds the control, keyboard support, and
   linked selection: choosing "macOS" in one tab set chooses it in every set that has it. */
(function () {
  'use strict';
  const greece = window.greece;
  if (!greece) return;

  function panelsOf(set) {
    return Array.from(set.children).filter((el) => el.classList.contains('md-tab'));
  }

  function select(set, index) {
    const panels = panelsOf(set);
    const buttons = Array.from(set.querySelector(':scope > .md-tabbar').children);
    panels.forEach((panel, i) => { panel.hidden = i !== index; });
    buttons.forEach((button, i) => {
      const on = i === index;
      button.setAttribute('aria-selected', on ? 'true' : 'false');
      button.tabIndex = on ? 0 : -1;
    });
  }

  /** Selects `label` everywhere, keeping the clicked control where it was on screen. */
  function selectLabel(origin, index, root) {
    const label = panelsOf(origin)[index].dataset.label;
    const anchor = origin.querySelector(':scope > .md-tabbar');
    const before = anchor.getBoundingClientRect().top;
    select(origin, index);
    root.querySelectorAll('.md-tabs.ready').forEach((set) => {
      if (set === origin) return;
      const match = panelsOf(set).findIndex((panel) => panel.dataset.label === label);
      if (match >= 0) select(set, match);
    });
    const shift = anchor.getBoundingClientRect().top - before;
    if (Math.abs(shift) > 1) window.scrollBy(0, shift);
  }

  greece.enhance('markdown', (root) => {
    const sets = Array.from(root.querySelectorAll('.md-tabs'));
    if (!sets.length) return;
    sets.forEach((set, n) => {
      const panels = panelsOf(set);
      if (!panels.length) return;
      const bar = document.createElement('div');
      bar.className = 'md-tabbar';
      bar.setAttribute('role', 'tablist');
      panels.forEach((panel, i) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.setAttribute('role', 'tab');
        button.id = `md-tab-${n}-${i}`;
        button.textContent = panel.dataset.label || `Tab ${i + 1}`;
        panel.setAttribute('role', 'tabpanel');
        panel.setAttribute('aria-labelledby', button.id);
        bar.appendChild(button);
      });
      set.insertBefore(bar, set.firstChild);
      set.classList.add('ready');
      const preferred = panels.findIndex((panel) => panel.hasAttribute('data-selected'));
      select(set, preferred < 0 ? 0 : preferred);
    });

    root.addEventListener('click', (event) => {
      const button = event.target.closest('.md-tabbar > button');
      if (!button) return;
      const set = button.parentElement.parentElement;
      selectLabel(set, Array.from(button.parentElement.children).indexOf(button), root);
    });

    root.addEventListener('keydown', (event) => {
      const button = event.target.closest('.md-tabbar > button');
      if (!button) return;
      const buttons = Array.from(button.parentElement.children);
      let index = buttons.indexOf(button);
      if (event.key === 'ArrowRight') index = (index + 1) % buttons.length;
      else if (event.key === 'ArrowLeft') index = (index - 1 + buttons.length) % buttons.length;
      else if (event.key === 'Home') index = 0;
      else if (event.key === 'End') index = buttons.length - 1;
      else return;
      event.preventDefault();
      selectLabel(button.parentElement.parentElement, index, root);
      buttons[index].focus();
    });

    // A link to something inside a hidden tab (the outline, a footnote) opens that tab first.
    document.addEventListener('click', (event) => {
      const link = event.target.closest('a[href^="#"]');
      if (!link) return;
      let id = link.getAttribute('href').slice(1);
      try { id = decodeURIComponent(id); } catch (_) { }
      const target = id && document.getElementById(id);
      for (let panel = target && target.closest('.md-tab[hidden]'); panel; panel = panel.parentElement.closest('.md-tab[hidden]')) {
        const set = panel.parentElement;
        select(set, panelsOf(set).indexOf(panel));
      }
    }, true);
  });
})();

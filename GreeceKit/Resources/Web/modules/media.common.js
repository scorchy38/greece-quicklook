/* Greece — shared pieces for media pages: elements, icons, controls, fetching, formatting.
   Everything a file provides reaches the page as text (textContent) or escaped HTML. */
(function () {
  'use strict';

  /** Builds an element. `props.text` sets textContent; `props.html` is only ever Greece's own markup. */
  function el(tag, props, children) {
    const node = document.createElement(tag);
    if (props) {
      for (const key of Object.keys(props)) {
        const value = props[key];
        if (value == null || value === false) continue;
        if (key === 'text') node.textContent = value;
        else if (key === 'html') node.innerHTML = value;
        else if (key === 'class') node.className = value;
        else if (key === 'style' && typeof value === 'object') Object.assign(node.style, value);
        else if (key.startsWith('on') && typeof value === 'function') node.addEventListener(key.slice(2), value);
        else node.setAttribute(key, value === true ? '' : value);
      }
    }
    for (const child of [].concat(children || [])) {
      if (child == null || child === false) continue;
      node.appendChild(typeof child === 'string' ? document.createTextNode(child) : child);
    }
    return node;
  }

  // SF Symbols-like glyphs, drawn on a 16-point grid.
  const ICONS = {
    plus: '<path d="M8 3.5v9M3.5 8h9"/>',
    minus: '<path d="M3.5 8h9"/>',
    fit: '<path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/>',
    actual: '<rect x="2.5" y="2.5" width="11" height="11" rx="2"/><path d="M6 6.2l1-.7v5M9.5 6.2l1-.7v5" stroke-width="1.2"/>',
    checker: '<rect x="2.5" y="2.5" width="11" height="11" rx="1.5"/><path d="M2.5 8h11M8 2.5v11" /><rect x="2.5" y="2.5" width="5.5" height="5.5" fill="currentColor" stroke="none" opacity=".45"/><rect x="8" y="8" width="5.5" height="5.5" fill="currentColor" stroke="none" opacity=".45"/>',
    code: '<path d="M5.5 4.5L2 8l3.5 3.5M10.5 4.5L14 8l-3.5 3.5M9 3L7 13"/>',
    play: '<path d="M5 3.2v9.6c0 .4.4.6.7.4l7.4-4.8c.3-.2.3-.6 0-.8L5.7 2.8c-.3-.2-.7 0-.7.4z" fill="currentColor" stroke="none"/>',
    pause: '<rect x="4" y="3" width="2.6" height="10" rx=".8" fill="currentColor" stroke="none"/><rect x="9.4" y="3" width="2.6" height="10" rx=".8" fill="currentColor" stroke="none"/>',
    loop: '<path d="M3 7.5V6a2 2 0 012-2h7.5M10.5 2l2 2-2 2M13 8.5V10a2 2 0 01-2 2H3.5M5.5 14l-2-2 2-2"/>',
    close: '<path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/>',
    copy: '<rect x="5.5" y="5.5" width="8" height="8" rx="1.6"/><path d="M10.5 3.5v-.3A1.2 1.2 0 009.3 2H3.7A1.2 1.2 0 002.5 3.2v5.6a1.2 1.2 0 001.2 1.2h.3"/>',
    back: '<path d="M10 3L5 8l5 5"/>',
    forward: '<path d="M6 3l5 5-5 5"/>',
  };

  function icon(name) {
    return `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ''}</svg>`;
  }

  function button(options) {
    const node = el('button', { class: 'm-button' + (options.wide ? ' wide' : ''), type: 'button', title: options.title, 'aria-label': options.title });
    node.innerHTML = options.icon ? icon(options.icon) : '';
    if (options.text) node.appendChild(document.createTextNode(options.text));
    if (options.onClick) node.addEventListener('click', options.onClick);
    return node;
  }

  /** A segmented control: [{value, label}], calls onChange(value). */
  function segmented(items, selected, onChange) {
    const node = el('div', { class: 'm-segmented', role: 'tablist' });
    for (const item of items) {
      const option = el('button', { type: 'button', class: item.value === selected ? 'on' : '', text: item.label, title: item.title });
      option.addEventListener('click', () => {
        node.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b === option));
        onChange(item.value);
      });
      node.appendChild(option);
    }
    return node;
  }

  /** A native pop-up menu. */
  function select(items, selected, onChange) {
    const node = el('select', { class: 'm-select' });
    items.forEach((item, index) => {
      const option = el('option', { value: String(index), text: item.label });
      if (item.value === selected) option.selected = true;
      node.appendChild(option);
    });
    node.addEventListener('change', () => onChange(items[Number(node.value)].value));
    return node;
  }

  /** Keeps a range input's filled track in step with its value. */
  function paintRange(input) {
    const min = Number(input.min) || 0, max = Number(input.max) || 100;
    const fraction = max > min ? (Number(input.value) - min) / (max - min) : 0;
    input.style.setProperty('--fill-to', (fraction * 100).toFixed(2) + '%');
  }

  function range(min, max, step, value, onInput) {
    const input = el('input', { type: 'range', class: 'm-range', min, max, step, value });
    input.addEventListener('input', () => { paintRange(input); onInput(Number(input.value)); });
    paintRange(input);
    return input;
  }

  async function fetchJSON(path) {
    const response = await fetch('greece://module/' + path);
    if (!response.ok) throw new Error('Could not load ' + path);
    return response.json();
  }

  async function fetchText(path) {
    const response = await fetch('greece://module/' + path);
    if (!response.ok) throw new Error('Could not load ' + path);
    return response.text();
  }

  /** A number for the page's locale (kit.number in greece.js). */
  const number = (value, options) => window.greece.kit.number(value, options);
  const trimNumber = (value, digits) => Number(value.toFixed(digits == null ? 2 : digits)).toString();

  /** 00:01:02.345 */
  function timecode(ms, withHours) {
    const negative = ms < 0;
    ms = Math.abs(Math.round(ms));
    const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60, f = ms % 1000;
    const pad = (v, n) => String(v).padStart(n, '0');
    const head = (withHours || h > 0) ? pad(h, 2) + ':' : '';
    return (negative ? '−' : '') + head + pad(m, 2) + ':' + pad(s, 2) + '.' + pad(f, 3);
  }

  let copiedTimer;
  /** Copies through Greece (the page can't reach the pasteboard) and confirms quietly. */
  function copy(text, label) {
    window.greece.kit.post('copy', text);
    let toast = document.querySelector('.m-copied');
    if (!toast) { toast = el('div', { class: 'm-copied', role: 'status' }); document.body.appendChild(toast); }
    toast.textContent = label || window.greece.kit.t('Copied {0}', text);
    toast.classList.add('show');
    clearTimeout(copiedTimer);
    copiedTimer = setTimeout(() => toast.classList.remove('show'), 1300);
  }

  /** True when the page is showing in dark mode. */
  const isDark = () => window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;

  /**
   * How light an image's visible pixels are (0 black … 1 white), or null if it can't be measured.
   * Used to pick a background that keeps black icons visible in dark mode and white ones in light.
   */
  function measureLightness(image, width, height) {
    try {
      const side = 48;
      const canvas = document.createElement('canvas');
      canvas.width = side; canvas.height = side;
      const context = canvas.getContext('2d', { willReadFrequently: true });
      const scale = Math.min(side / width, side / height);
      context.drawImage(image, 0, 0, width * scale, height * scale);
      const data = context.getImageData(0, 0, side, side).data;
      let weight = 0, light = 0;
      for (let i = 0; i < data.length; i += 4) {
        const alpha = data[i + 3] / 255;
        if (alpha < 0.05) continue;
        const r = data[i] / 255 / alpha, g = data[i + 1] / 255 / alpha, b = data[i + 2] / 255 / alpha;
        weight += alpha;
        light += alpha * (0.2126 * r + 0.7152 * g + 0.0722 * b);
      }
      if (weight < 4) return null;
      // Mostly opaque artwork carries its own background: no need to change ours.
      const coverage = weight / (side * side * Math.min(1, (width * scale * height * scale) / (side * side)));
      return { lightness: light / weight, coverage };
    } catch (_) {
      return null;
    }
  }

  window.GreeceMedia = { el, icon, button, segmented, select, range, paintRange, fetchJSON, fetchText, number, trimNumber, timecode, copy, isDark, measureLightness };
})();

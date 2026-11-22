/* Greece — colour palettes: every swatch with its name and value, grouped as the file groups them.
   Click a swatch to copy its value in the chosen notation. */
(function () {
  'use strict';
  const M = window.GreeceMedia;
  const { el } = M;

  const hex = (c) => c.hex.toUpperCase() + (c.alpha < 1 ? Math.round(c.alpha * 255).toString(16).padStart(2, '0').toUpperCase() : '');

  function hsl(rgb) {
    const [r, g, b] = rgb.map((v) => v / 255);
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const l = (max + min) / 2;
    let h = 0, s = 0;
    if (max !== min) {
      const d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
      h *= 60;
    }
    return [Math.round(h), Math.round(s * 100), Math.round(l * 100)];
  }

  function original(c) {
    const v = c.values.map((n) => M.trimNumber(n, 1).replace('-', '−'));
    switch (c.model) {
      case 'CMYK': return `C${v[0]} M${v[1]} Y${v[2]} K${v[3]}`;
      case 'Lab': return `L${v[0]} a${v[1]} b${v[2]}`;
      case 'Gray': return `Gray ${v[0]}%`;
      case 'HSB': case 'HSB (P3)': return `H${v[0]} S${v[1]} B${v[2]}` + (c.model === 'HSB (P3)' ? ' P3' : '');
      case 'Display P3': return `P3 ${c.values.map((n) => M.trimNumber(n / 255, 3)).join(' ')}`;
      default: return `R${v[0]} G${v[1]} B${v[2]}`;
    }
  }

  const FORMATS = {
    hex: (c) => hex(c),
    rgb: (c) => c.alpha < 1 ? `rgb(${c.rgb.join(' ')} / ${M.trimNumber(c.alpha, 2)})` : `rgb(${c.rgb.join(', ')})`,
    hsl: (c) => { const [h, s, l] = hsl(c.rgb); return c.alpha < 1 ? `hsl(${h} ${s}% ${l}% / ${M.trimNumber(c.alpha, 2)})` : `hsl(${h}, ${s}%, ${l}%)`; },
    original,
  };

  window.greece.register('media-palette', (data, kit) => {
    const root = kit.root;
    const colors = data.groups.flatMap((g) => g.colors);
    const hasOriginal = colors.some((c) => c.model !== 'RGB');
    let format = 'hex';

    const page = el('div', { class: 'palette' });
    const formats = [{ value: 'hex', label: 'Hex' }, { value: 'rgb', label: 'RGB' }, { value: 'hsl', label: 'HSL' }];
    if (hasOriginal) formats.push({ value: 'original', label: colors.every((c) => c.model === colors[0].model) ? colors[0].model.replace(' (P3)', '') : 'Original' });
    page.appendChild(el('div', { class: 'palette-head' }, [
      el('div', { class: 'titles' }, [
        el('h1', { text: data.name || data.kind }),
        el('div', { class: 'sub', text: `${M.plural(data.count, 'color')} · ${data.kind}` }),
      ]),
      M.segmented(formats, format, (value) => { format = value; refresh(); }),
    ]));

    // Every colour at a glance.
    const strip = el('div', { class: 'palette-strip', 'aria-hidden': 'true' });
    for (const color of colors.slice(0, 400)) strip.appendChild(el('i', { style: { background: color.hex } }));
    page.appendChild(strip);

    const values = [];
    for (const group of data.groups) {
      const section = el('section', { class: 'palette-group' });
      if (group.name || data.groups.length > 1) {
        section.appendChild(el('h2', null, [group.name || 'Ungrouped', el('span', { class: 'n', text: M.number(group.colors.length) })]));
      }
      const unnamed = group.colors.every((c) => !c.name);
      const grid = el('div', { class: 'swatches' + (group.colors.length > 48 && unnamed ? ' dense' : '') });
      for (const color of group.colors) {
        const light = (0.2126 * color.rgb[0] + 0.7152 * color.rgb[1] + 0.0722 * color.rgb[2]) / 255 > 0.6;
        const chip = el('div', { class: 'chip' + (color.alpha < 1 ? ' checker' : '') }, [
          el('div', { class: 'fill', style: { background: `rgba(${color.rgb.join(',')},${color.alpha})` } }),
          // Spot inks matter when printing; "global" is a bookkeeping flag, left to the tooltip.
          color.kind === 'Spot' ? el('span', { class: 'badge', text: 'Spot' }) : null,
          el('span', { class: 'copy', style: { color: light ? 'rgba(0,0,0,.65)' : 'rgba(255,255,255,.85)' }, text: 'Copy' }),
        ]);
        const value = el('div', { class: 'value' });
        values.push([value, color]);
        const kind = color.kind ? ` (${color.kind} ${color.model})` : color.model !== 'RGB' ? ` (${color.model})` : '';
        const swatch = el('div', { class: 'swatch', title: `${color.name || hex(color)}${kind} — click to copy`, tabindex: '0' }, [
          chip,
          el('div', { class: 'name', text: color.name || hex(color) }),
          value,
        ]);
        const copy = () => M.copy(FORMATS[format](color));
        swatch.addEventListener('click', copy);
        swatch.addEventListener('keydown', (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); copy(); } });
        grid.appendChild(swatch);
      }
      section.appendChild(grid);
      page.appendChild(section);
    }

    function refresh() {
      for (const [node, color] of values) {
        node.textContent = FORMATS[format](color);
        if (color.clipped && format !== 'original') node.appendChild(el('span', { class: 'clip', title: 'Outside sRGB: shown as the nearest sRGB color', text: ' ◆' }));
      }
    }
    refresh();
    root.appendChild(page);
  });
})();

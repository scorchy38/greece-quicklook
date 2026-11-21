/* Greece — maps.
   Draws geodata on an offline map with MapLibre GL: a bundled Natural Earth basemap, the file's
   layers (fetched on demand from greece://module), MBTiles tiles, KML overlays, a feature
   inspector, layer toggles, a graticule and, for tracks, an elevation profile.
   Nothing here ever reaches the network. */
(function () {
  'use strict';

  const ICONS = {
    layers: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 2.6 2.4 6.7 10 10.8l7.6-4.1L10 2.6Z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><path d="m2.4 10 7.6 4.1 7.6-4.1M2.4 13.3l7.6 4.1 7.6-4.1" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    fit: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3.5 7.5v-3a1 1 0 0 1 1-1h3M12.5 3.5h3a1 1 0 0 1 1 1v3M16.5 12.5v3a1 1 0 0 1-1 1h-3M7.5 16.5h-3a1 1 0 0 1-1-1v-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
    plus: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 4.5v11M4.5 10h11" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    minus: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M4.5 10h11" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    close: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m6 6 8 8M14 6l-8 8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
    chevron: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 8 3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    info: '<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="7.2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M10 9v4.6" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="10" cy="6.4" r="1" fill="currentColor"/></svg>',
  };

  // Calm, Apple Maps-like colours. Data colours are the system palette.
  const THEMES = {
    light: {
      water: '#d5e3ee', land: '#f6f4ef', lakes: '#d5e3ee', rivers: '#bcd3e6', borders: '#c2b8ac', states: '#dcd5cb',
      graticule: 'rgba(66, 96, 140, 0.16)', graticuleLabel: 'rgba(60, 72, 92, 0.55)', casing: '#ffffff', halo: '#ffffff',
      planar: '#f5f5f7', planarGrid: 'rgba(0, 0, 0, 0.05)', label: '#1d1d1f', labelHalo: 'rgba(255,255,255,0.92)',
      roadCasing: '#d4cdc4', profileFill: 'rgba(0, 122, 255, 0.16)',
      layers: ['#007aff', '#ff9500', '#ff2d55', '#34c759', '#af52de', '#30b0c7', '#5856d6', '#a2845e', '#ff3b30', '#00c7be'],
    },
    dark: {
      water: '#161d25', land: '#27292d', lakes: '#161d25', rivers: '#22313f', borders: '#4f545b', states: '#383b41',
      graticule: 'rgba(170, 195, 230, 0.13)', graticuleLabel: 'rgba(210, 220, 235, 0.5)', casing: '#1c1c1e', halo: '#1c1c1e',
      planar: '#1c1c1e', planarGrid: 'rgba(255, 255, 255, 0.05)', label: '#f5f5f7', labelHalo: 'rgba(28,28,30,0.9)',
      roadCasing: '#2a2c30', profileFill: 'rgba(10, 132, 255, 0.22)',
      layers: ['#0a84ff', '#ff9f0a', '#ff375f', '#30d158', '#bf5af2', '#40c8e0', '#5e5ce6', '#ac8e68', '#ff453a', '#63e6e2'],
    },
  };

  /** OpenStreetMap colours are written in light-mode values; these are their dark counterparts. */
  const OSM_DARK = {
    '#e0d9d0': '#3a3a3e', '#cbbfb2': '#4a4a50', '#a6cff2': '#1d3247', '#c8e6b5': '#23382a', '#b6d9a0': '#2c4733',
    '#efe4e4': '#2d2a2c', '#efece6': '#2a2a2d', '#86bdf0': '#2f5679', '#9a9ca3': '#6e7178', '#f7b955': '#a8792e',
    '#fbd77a': '#8f7a3e', '#ffffff': '#56575c', '#c9b9a8': '#6a6158', '#a593b8': '#6f6383', '#9a9aa0': '#7a7a80',
    '#d8d8dc': '#3a3a3e',
  };

  const OSM_ROLES = new Set(['area', 'road', 'path', 'rail', 'place']);

  /** Quick Look prepares pages offscreen, where animation frames don't fire; MapLibre needs them
      even to load its style. Frames come from the display when there is one, from a timer when not. */
  function installFrameFallback() {
    const nativeRequest = window.requestAnimationFrame.bind(window);
    const nativeCancel = window.cancelAnimationFrame.bind(window);
    const pending = new Map();
    let next = 1;
    window.requestAnimationFrame = (callback) => {
      const id = next++;
      const entry = { raf: 0, timer: 0 };
      const run = (time) => {
        if (!pending.has(id)) return;
        pending.delete(id);
        nativeCancel(entry.raf);
        clearTimeout(entry.timer);
        callback(typeof time === 'number' ? time : performance.now());
      };
      entry.raf = nativeRequest(run);
      entry.timer = setTimeout(() => run(performance.now()), 34);
      pending.set(id, entry);
      return id;
    };
    window.cancelAnimationFrame = (id) => {
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id);
      nativeCancel(entry.raf);
      clearTimeout(entry.timer);
    };
  }

  greece.register('map', async (data, kit) => {
    const { esc, root } = kit;
    const html = document.documentElement;
    const dark = window.matchMedia('(prefers-color-scheme: dark)');
    let theme = dark.matches ? THEMES.dark : THEMES.light;
    const imperial = data.units === 'imperial';
    const planar = !!data.planar;

    root.innerHTML = `
      <div id="map" class="map" aria-label="Map"></div>
      <div class="graticule-labels" aria-hidden="true"></div>
      <div class="map-controls top">
        <button class="glass round" id="layers-button" type="button" title="Layers" aria-label="Layers" aria-expanded="false">${ICONS.layers}</button>
        <button class="glass round" id="fit-button" type="button" title="Show all (F)" aria-label="Show all">${ICONS.fit}</button>
      </div>
      <div class="map-controls bottom">
        <div class="glass stack">
          <button id="zoom-in" type="button" title="Zoom in" aria-label="Zoom in">${ICONS.plus}</button>
          <span class="divider"></span>
          <button id="zoom-out" type="button" title="Zoom out" aria-label="Zoom out">${ICONS.minus}</button>
        </div>
      </div>
      <div class="glass panel layers-panel" id="layers-panel" hidden></div>
      <div class="cards"></div>
      <div class="notices"></div>
      <div class="glass track-card" id="track-card" hidden></div>
      <div class="map-footer"><div class="scale-slot"></div><div class="attribution"></div></div>`;

    if (!window.maplibregl) {
      root.innerHTML = `<div class="empty">${esc('The map couldn’t start.')}</div>`;
      return;
    }

    const $ = (s) => root.querySelector(s);
    const cards = $('.cards');
    const layersPanel = $('#layers-panel');
    const trackCard = $('#track-card');

    // ---------------------------------------------------------------- Map

    /** The data's extent for framing. World-wide data skips the polar regions, which Mercator
        would otherwise blow up to fill the window. */
    function framing() {
      if (!data.bounds) return null;
      let [w, s, e, n] = data.bounds;
      if (e - w > 200 && !planar) { s = Math.max(s, -58); n = Math.min(n, 78); if (s >= n) { s = -58; n = 78; } }
      s = Math.max(s, -84); n = Math.min(n, 84);
      return [[w, s], [e, n]];
    }
    const framed = framing();
    const initial = framed ? { bounds: framed } : { center: [0, 20], zoom: 1 };
    const tiles = data.tiles || [];
    const maxTileZoom = tiles.reduce((m, t) => Math.max(m, t.maxzoom), 0);

    installFrameFallback();
    const map = new maplibregl.Map({
      container: $('#map'),
      style: {
        version: 8,
        sources: {},
        layers: [{ id: 'background', type: 'background', paint: { 'background-color': planar ? theme.planar : theme.water } }],
      },
      ...initial,
      fitBoundsOptions: { padding: fitPadding(), maxZoom: 16, animate: false },
      attributionControl: false,
      dragRotate: false,
      pitchWithRotate: false,
      touchPitch: false,
      maxPitch: 0,
      fadeDuration: 0,
      maxZoom: Math.max(20, maxTileZoom + 3),
      renderWorldCopies: !planar,
      canvasContextAttributes: { antialias: true, preserveDrawingBuffer: true },
      cooperativeGestures: false,
    });
    map.touchZoomRotate.disableRotation();
    map.keyboard.disableRotation();
    map.on('error', (e) => kit.post('log', 'map: ' + (e && e.error && e.error.message)));

    const scale = planar ? null : new maplibregl.ScaleControl({ maxWidth: 96, unit: imperial ? 'imperial' : 'metric' });
    if (scale) $('.scale-slot').appendChild(scale.onAdd(map));

    function fitPadding() {
      const track = html.classList.contains('has-track') ? 190 : 0;
      return { top: 56, bottom: 56 + track, left: 56, right: 72 };
    }

    function fitAll(animate) {
      if (framed) {
        const [[w, s], [e, n]] = framed;
        const single = w === e && s === n;
        if (single) map.jumpTo({ center: [w, s], zoom: Math.min(14, map.getMaxZoom()) });
        else map.fitBounds(framed, { padding: fitPadding(), maxZoom: 17, duration: animate ? 180 : 0 });
      } else if (tiles.length) {
        const t = tiles[0];
        if (t.center && t.center.length >= 2) map.jumpTo({ center: [t.center[0], t.center[1]], zoom: t.center[2] != null ? t.center[2] : t.minzoom });
        else map.jumpTo({ center: [0, 20], zoom: t.minzoom });
      }
    }

    await new Promise((resolve) => map.once('load', resolve));
    if (data.bounds && data.bounds[0] === data.bounds[2] && data.bounds[1] === data.bounds[3]) fitAll(false);
    if (!data.bounds) fitAll(false);

    // ---------------------------------------------------------------- Basemap

    const state = { basemap: !planar, grid: false, labels: true };
    const basemapLayers = [];

    async function addBasemap() {
      if (planar) return;
      let layers;
      try {
        const buffer = await fetch('greece://asset/modules/maps-basemap.bin').then((r) => r.arrayBuffer());
        layers = decodeBasemap(buffer);
      } catch (e) {
        kit.post('log', 'basemap: ' + e);
      }
      if (!layers) return;
      const add = (id, source, layer) => {
        if (!map.getSource(source)) map.addSource(source, { type: 'geojson', data: layers[source.replace('bm-', '')], tolerance: 0.45, buffer: 32, maxzoom: 9 });
        map.addLayer({ id, source, ...layer });
        basemapLayers.push(id);
      };
      // Natural Earth 1:50m is accurate to a kilometre or two: past regional zooms its coastlines,
      // rivers and borders would mislead, so the map fades to plain paper under the data.
      const fade = (from, to) => ['interpolate', ['linear'], ['zoom'], from, 1, to, 0];
      add('bm-land', 'bm-land', { type: 'fill', maxzoom: 12, paint: { 'fill-color': theme.land, 'fill-antialias': true } });
      add('bm-lakes', 'bm-lakes', { type: 'fill', maxzoom: 11.5, filter: ['<=', ['get', 'rank'], ['+', ['zoom'], 2.5]],
        paint: { 'fill-color': theme.lakes, 'fill-opacity': fade(9, 11) } });
      add('bm-rivers', 'bm-rivers', {
        type: 'line', maxzoom: 10, filter: ['<=', ['get', 'rank'], ['+', ['zoom'], 1.5]],
        layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': theme.rivers, 'line-width': ['interpolate', ['linear'], ['zoom'], 2, 0.5, 6, 1.2, 9, 1.6], 'line-opacity': fade(7.5, 9.5) },
      });
      add('bm-states', 'bm-states', {
        type: 'line', minzoom: 2.5, maxzoom: 11.5,
        layout: { 'line-join': 'round' },
        paint: { 'line-color': theme.states, 'line-width': ['interpolate', ['linear'], ['zoom'], 3, 0.5, 8, 1], 'line-dasharray': [3, 2], 'line-opacity': fade(9, 11) },
      });
      add('bm-borders', 'bm-borders', {
        type: 'line', maxzoom: 12,
        layout: { 'line-join': 'round', 'line-cap': 'round' },
        paint: { 'line-color': theme.borders, 'line-width': ['interpolate', ['linear'], ['zoom'], 0, 0.45, 5, 0.9, 9, 1.4], 'line-opacity': fade(9.5, 11.5) },
      });
      if (!state.basemap) setBasemap(false);
      else map.setPaintProperty('background', 'background-color', backgroundColor());
    }

    /** Water, fading to plain land colour where the basemap would be too coarse to trust. */
    function backgroundColor() {
      if (planar) return theme.planar;
      if (!state.basemap) return theme.land;
      return ['interpolate', ['linear'], ['zoom'], 9, theme.water, 11, theme.land];
    }

    function setBasemap(on) {
      state.basemap = on;
      basemapLayers.forEach((id) => map.setLayoutProperty(id, 'visibility', on ? 'visible' : 'none'));
      map.setPaintProperty('background', 'background-color', backgroundColor());
    }

    function decodeBasemap(buffer) {
      const b = new Uint8Array(buffer);
      if (b.length < 6 || String.fromCharCode(b[0], b[1], b[2], b[3]) !== 'GRBM' || b[4] !== 1) return null;
      const text = new TextDecoder();
      let pos = 6;
      const varint = () => {
        let result = 0, shift = 0, byte;
        do { byte = b[pos++]; result += (byte & 0x7f) * Math.pow(2, shift); shift += 7; } while (byte & 0x80 && pos < b.length);
        return result;
      };
      const zigzag = () => { const v = varint(); return v % 2 ? -(v + 1) / 2 : v / 2; };
      const layers = {};
      for (let l = 0, count = b[5]; l < count && pos < b.length; l++) {
        const nameLength = b[pos++];
        const name = text.decode(b.subarray(pos, pos + nameLength));
        pos += nameLength;
        const kind = b[pos++];
        const n = varint();
        const features = [];
        for (let i = 0; i < n && pos < b.length; i++) {
          const rank = b[pos++] / 10;
          if (kind === 3) {
            const length = varint();
            const label = text.decode(b.subarray(pos, pos + length));
            pos += length;
            const x = zigzag() / 1000, y = zigzag() / 1000;
            features.push({ type: 'Feature', properties: { name: label, rank }, geometry: { type: 'Point', coordinates: [x, y] } });
            continue;
          }
          const parts = varint();
          let x = 0, y = 0;
          const coordinates = [];
          for (let p = 0; p < parts; p++) {
            const m = varint();
            const part = new Array(m);
            for (let k = 0; k < m; k++) { x += zigzag(); y += zigzag(); part[k] = [x / 1000, y / 1000]; }
            coordinates.push(part);
          }
          features.push({ type: 'Feature', properties: { rank }, geometry: kind === 1 ? { type: 'Polygon', coordinates } : { type: 'MultiLineString', coordinates } });
        }
        layers[name] = { type: 'FeatureCollection', features };
      }
      return layers;
    }

    // ---------------------------------------------------------------- Graticule

    const graticuleLabels = $('.graticule-labels');

    function graticuleStep(zoom) {
      const steps = [30, 15, 10, 5, 2, 1, 0.5, 0.25, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001];
      const target = 360 / Math.pow(2, zoom) / 2.2;
      return steps.find((s) => s <= target) || 0.001;
    }

    function graticuleData() {
      const step = graticuleStep(map.getZoom());
      const b = map.getBounds();
      const west = Math.max(-540, Math.floor(b.getWest() / step) * step), east = Math.min(540, Math.ceil(b.getEast() / step) * step);
      const south = Math.max(-85, Math.floor(b.getSouth() / step) * step), north = Math.min(85, Math.ceil(b.getNorth() / step) * step);
      const features = [];
      const dense = Math.max(step / 8, 0.0005);
      for (let x = west; x <= east + 1e-9 && features.length < 400; x += step) {
        const line = [];
        for (let y = south; y <= north + 1e-9; y += Math.max((north - south) / 64, dense)) line.push([x, y]);
        line.push([x, north]);
        features.push({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: line } });
      }
      for (let y = south; y <= north + 1e-9 && features.length < 800; y += step) {
        features.push({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: [[west, y], [east, y]] } });
      }
      return { step, data: { type: 'FeatureCollection', features } };
    }

    function formatDegree(value, positive, negative, step) {
      const digits = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3;
      let v = value;
      if (positive === 'E') { v = ((v + 540) % 360) - 180; }
      if (Math.abs(v) < 1e-9) return '0°';
      return `${Math.abs(v).toFixed(digits)}°${v < 0 ? negative : positive}`;
    }

    let graticuleFrame = 0;
    function updateGraticule() {
      if (!state.grid || planar) { graticuleLabels.innerHTML = ''; return; }
      const { step, data: lines } = graticuleData();
      const source = map.getSource('graticule');
      if (source) source.setData(lines);
      const b = map.getBounds();
      const canvas = map.getCanvas();
      const width = canvas.clientWidth, height = canvas.clientHeight;
      let out = '';
      for (let x = Math.ceil(b.getWest() / step) * step; x <= b.getEast(); x += step) {
        const p = map.project([x, b.getNorth()]);
        if (p.x > 40 && p.x < width - 40) out += `<span class="lon" style="left:${p.x.toFixed(1)}px">${esc(formatDegree(x, 'E', 'W', step))}</span>`;
      }
      for (let y = Math.ceil(b.getSouth() / step) * step; y <= b.getNorth(); y += step) {
        const p = map.project([b.getWest(), y]);
        if (p.y > 30 && p.y < height - 30) out += `<span class="lat" style="top:${p.y.toFixed(1)}px">${esc(formatDegree(y, 'N', 'S', step))}</span>`;
      }
      graticuleLabels.innerHTML = out;
    }

    function addGraticule() {
      if (planar) return;
      map.addSource('graticule', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
      map.addLayer({ id: 'graticule', type: 'line', source: 'graticule', layout: { visibility: 'none' },
        paint: { 'line-color': theme.graticule, 'line-width': 0.8 } });
      map.on('move', () => {
        if (!state.grid) return;
        cancelAnimationFrame(graticuleFrame);
        graticuleFrame = requestAnimationFrame(updateGraticule);
      });
    }

    function setGrid(on) {
      state.grid = on;
      if (map.getLayer('graticule')) map.setLayoutProperty('graticule', 'visibility', on ? 'visible' : 'none');
      html.classList.toggle('grid-on', on);
      updateGraticule();
    }

    // ---------------------------------------------------------------- Tiles and overlays

    const vectorLayerIDs = {};

    function addTiles() {
      tiles.forEach((t, index) => {
        const source = 'tiles-' + index;
        const options = { tiles: [t.url], minzoom: t.minzoom, maxzoom: t.maxzoom, tileSize: t.tileSize || 256 };
        if (t.bounds) options.bounds = t.bounds;
        if (t.kind === 'raster') {
          map.addSource(source, { type: 'raster', ...options });
          map.addLayer({ id: source, type: 'raster', source, paint: { 'raster-fade-duration': 120 } });
          return;
        }
        delete options.tileSize;
        map.addSource(source, { type: 'vector', ...options });
        const layers = t.vectorLayers.length ? t.vectorLayers : [];
        layers.forEach((layer, i) => {
          const color = theme.layers[i % theme.layers.length];
          const ids = [];
          const base = `vt-${index}-${i}`;
          const common = { source, 'source-layer': layer.id };
          map.addLayer({ id: base + '-fill', type: 'fill', ...common, filter: ['==', ['geometry-type'], 'Polygon'],
            paint: { 'fill-color': color, 'fill-opacity': ['case', ['boolean', ['feature-state', 'hover'], false], 0.34, 0.16] } });
          map.addLayer({ id: base + '-outline', type: 'line', ...common, filter: ['==', ['geometry-type'], 'Polygon'],
            paint: { 'line-color': color, 'line-width': 0.8, 'line-opacity': 0.85 } });
          map.addLayer({ id: base + '-line', type: 'line', ...common, filter: ['==', ['geometry-type'], 'LineString'],
            layout: { 'line-cap': 'round', 'line-join': 'round' },
            paint: { 'line-color': color, 'line-width': ['interpolate', ['linear'], ['zoom'], 0, 1, 10, 2] } });
          map.addLayer({ id: base + '-point', type: 'circle', ...common, filter: ['==', ['geometry-type'], 'Point'],
            paint: { 'circle-color': color, 'circle-radius': ['interpolate', ['linear'], ['zoom'], 0, 2.5, 10, 4.5],
              'circle-stroke-color': theme.halo, 'circle-stroke-width': 1.2 } });
          ids.push(base + '-fill', base + '-outline', base + '-line', base + '-point');
          vectorLayerIDs[`${index}:${layer.id}`] = { ids, color, name: layer.id, tileset: index };
          interactive.push(base + '-fill', base + '-line', base + '-point');
        });
      });
    }

    function addOverlays() {
      (data.overlays || []).forEach((o, i) => {
        const id = 'overlay-' + i;
        map.addSource(id, { type: 'image', url: o.url, coordinates: o.coordinates });
        map.addLayer({ id, type: 'raster', source: id, paint: { 'raster-opacity': 0.92, 'raster-fade-duration': 0 } });
      });
    }

    // ---------------------------------------------------------------- Data layers

    const interactive = [];
    const dataLayers = [];
    const sourceOfLayer = {};

    function color(index) { return theme.layers[index % theme.layers.length]; }

    /** A colour from the feature (validated in Swift) or the layer's, adapted for dark mode in OSM layers. */
    function styled(key, fallback, role) {
      const value = ['coalesce', ['get', key], fallback];
      if (!dark.matches || !OSM_ROLES.has(role)) return value;
      const pairs = [];
      Object.keys(OSM_DARK).forEach((k) => pairs.push(k, OSM_DARK[k]));
      return ['match', ['coalesce', ['get', key], ''], ...pairs, value];
    }

    function hover(on, off) { return ['case', ['boolean', ['feature-state', 'hover'], false], on, ['boolean', ['feature-state', 'selected'], false], on, off]; }

    /** Zoom must be the outermost expression in MapLibre: each stop scales a data expression. */
    function byZoom(stops, value) {
      if (!stops) return value(1);
      const out = ['interpolate', ['exponential', 1.6], ['zoom']];
      stops.forEach(([z, k]) => out.push(z, value(k)));
      return out;
    }

    function paintFor(layer, index) {
      const c = color(index);
      const role = layer.role;
      const area = role === 'area';
      const track = role === 'track';
      const road = role === 'road';
      // Streets widen as you zoom in, like a real map; other data keeps its stroke.
      const streetStops = road || role === 'path' || role === 'rail' ? [[11, 0.35], [14, 0.9], [16, 2], [18, 5]] : null;
      const areaStops = area ? [[12, 0.5], [16, 1], [18, 1.6]] : null;
      const baseWidth = track ? 4 : 2.2;
      const lineWidth = (k, extra) => ['+', ['*', ['coalesce', ['get', 'stroke-width'], baseWidth], k], extra];
      const many = data.stats.points > 5000;
      return {
        fill: {
          'fill-color': styled('fill', c, role),
          'fill-opacity': ['*', ['coalesce', ['get', 'fill-opacity'], area ? 1 : 0.16], hover(area ? 1 : 1.7, 1)],
        },
        outline: {
          'line-color': styled('stroke', c, role),
          'line-opacity': ['coalesce', ['get', 'stroke-opacity'], area ? 0.9 : 1],
          'line-width': byZoom(areaStops, (k) => ['+', ['*', ['coalesce', ['get', 'stroke-width'], area ? 0.6 : 1.2], k], hover(1.4, 0)]),
        },
        casing: {
          'line-color': road ? (dark.matches ? '#1f2023' : theme.roadCasing) : theme.casing,
          'line-opacity': ['coalesce', ['get', 'stroke-opacity'], 1],
          'line-width': byZoom(streetStops, (k) => lineWidth(k, ['+', road ? 1.6 * Math.max(k, 0.6) : 3, hover(2, 0)])),
        },
        line: {
          'line-color': styled('stroke', c, role),
          'line-opacity': ['coalesce', ['get', 'stroke-opacity'], 1],
          'line-width': byZoom(streetStops, (k) => lineWidth(k, hover(1.5, 0))),
        },
        point: {
          'circle-color': styled('marker-color', c, role),
          'circle-radius': ['interpolate', ['linear'], ['zoom'],
            0, ['+', many ? 1.6 : 3.6, hover(2, 0)],
            10, ['+', many ? 3 : 5, hover(2, 0)],
            16, ['+', 6.5, hover(2, 0)]],
          'circle-stroke-color': theme.halo,
          'circle-stroke-width': many ? ['interpolate', ['linear'], ['zoom'], 4, 0, 8, 1.2] : 1.6,
        },
      };
    }

    async function addDataLayers() {
      const layers = data.layers || [];
      const jobs = layers.map((layer) => fetch(layer.url).then((r) => r.json()).catch((e) => { kit.post('log', 'layer: ' + e); return null; }));
      const results = await Promise.all(jobs);
      // Areas first, then lines, then points, so nothing small is buried.
      const order = { fill: [], outline: [], casing: [], line: [], icon: [], point: [] };
      layers.forEach((layer, index) => {
        const json = results[index];
        if (!json) return;
        const source = 'data-' + index;
        map.addSource(source, { type: 'geojson', data: json, tolerance: 0.3, buffer: 48, maxzoom: 20 });
        const p = paintFor(layer, index);
        const ids = [];
        const polygonFilter = ['==', ['geometry-type'], 'Polygon'];
        const lineFilter = ['==', ['geometry-type'], 'LineString'];
        const pointFilter = ['all', ['==', ['geometry-type'], 'Point'], ['!', ['has', 'icon']]];
        if (layer.polygons) {
          order.fill.push({ id: source + '-fill', type: 'fill', source, filter: polygonFilter, paint: p.fill });
          order.outline.push({ id: source + '-outline', type: 'line', source, filter: polygonFilter, layout: { 'line-join': 'round' }, paint: p.outline });
          ids.push(source + '-fill', source + '-outline');
          interactive.push(source + '-fill');
        }
        if (layer.lines) {
          if (layer.role === 'track' || layer.role === 'road') {
            order.casing.push({ id: source + '-casing', type: 'line', source, filter: lineFilter, layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: p.casing });
            ids.push(source + '-casing');
          }
          const layout = { 'line-cap': 'round', 'line-join': 'round' };
          const paint = { ...p.line };
          if (layer.role === 'path') paint['line-dasharray'] = [2, 1.5];
          if (layer.role === 'rail') paint['line-dasharray'] = [3, 2];
          order.line.push({ id: source + '-line', type: 'line', source, filter: lineFilter, layout, paint });
          ids.push(source + '-line');
          interactive.push(source + '-line');
        }
        if (layer.points) {
          order.icon.push({ id: source + '-icon', type: 'symbol', source, filter: ['all', ['==', ['geometry-type'], 'Point'], ['has', 'icon']],
            layout: { 'icon-image': ['get', 'icon'], 'icon-size': ['coalesce', ['get', 'icon-scale'], 1], 'icon-allow-overlap': true, 'icon-ignore-placement': true } });
          order.point.push({ id: source + '-point', type: 'circle', source, filter: pointFilter, paint: p.point });
          ids.push(source + '-icon', source + '-point');
          interactive.push(source + '-point', source + '-icon');
        }
        dataLayers.push({ layer, index, ids, source, json });
        ids.forEach((id) => { sourceOfLayer[id] = source; });
      });
      ['fill', 'outline', 'casing', 'line', 'icon', 'point'].forEach((kind) => order[kind].forEach((spec) => map.addLayer(spec)));
      dataLayers.forEach((d) => { if (d.layer.hidden) setLayerVisible(d, false); });
      await loadIcons();
    }

    async function loadIcons() {
      const icons = data.icons || [];
      await Promise.all(icons.map(async (url, i) => {
        try {
          const blob = await fetch(url).then((r) => r.blob());
          const bitmap = await createImageBitmap(blob);
          if (bitmap.width > 0 && bitmap.width <= 1024 && bitmap.height <= 1024 && !map.hasImage('icon-' + i)) {
            // Google Earth shows icons about 24 points across at scale 1, whatever their resolution.
            map.addImage('icon-' + i, bitmap, { pixelRatio: Math.max(1, Math.max(bitmap.width, bitmap.height) / 24) });
          }
        } catch (e) {
          kit.post('log', 'icon: ' + e);
        }
      }));
    }

    function setLayerVisible(d, on) {
      d.layer.hidden = !on;
      d.ids.forEach((id) => { if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', on ? 'visible' : 'none'); });
      updateLabels();
    }

    // ---------------------------------------------------------------- Labels

    const labelMarkers = [];
    function addLabels() {
      dataLayers.forEach((d) => {
        const named = d.json.features.filter((f) => f.properties && f.properties.label && f.geometry && f.geometry.type === 'Point');
        if (!named.length || named.length > 250) return;
        named.forEach((f) => {
          const element = document.createElement('div');
          element.className = 'map-label';
          element.textContent = f.properties.label;
          const marker = new maplibregl.Marker({ element, anchor: 'left', offset: [9, 0] }).setLngLat(f.geometry.coordinates).addTo(map);
          labelMarkers.push({ marker, element, d });
        });
      });
      if (labelMarkers.length) {
        map.on('moveend', updateLabels);
        updateLabels();
      }
    }

    /** Hides labels that would collide with ones already placed. */
    function updateLabels() {
      const placed = [];
      labelMarkers.forEach(({ marker, element, d }) => {
        if (d.layer.hidden || !state.labels) { element.hidden = true; return; }
        const p = map.project(marker.getLngLat());
        const w = element.offsetWidth || element.textContent.length * 6.5, h = 16;
        const box = { x: p.x + 9, y: p.y - h / 2, w, h };
        const clash = placed.some((b) => box.x < b.x + b.w && box.x + box.w > b.x && box.y < b.y + b.h && box.y + box.h > b.y);
        element.hidden = clash;
        if (!clash) placed.push(box);
      });
    }

    // ---------------------------------------------------------------- Hover and inspector

    let hovered = null;
    let selected = null;

    function setState(target, key, on) {
      if (!target || target.id == null) return;
      try { map.setFeatureState({ source: target.source, sourceLayer: target.sourceLayer, id: target.id }, { [key]: on }); } catch (_) { }
    }

    function hit(point) {
      const layers = interactive.filter((id) => map.getLayer(id) && map.getLayoutProperty(id, 'visibility') !== 'none');
      if (!layers.length) return null;
      const box = [[point.x - 4, point.y - 4], [point.x + 4, point.y + 4]];
      const features = map.queryRenderedFeatures(box, { layers });
      // Prefer points over lines over areas: the smallest thing under the pointer.
      const rank = (f) => (f.layer.type === 'circle' || f.layer.type === 'symbol' ? 0 : f.layer.type === 'line' ? 1 : 2);
      features.sort((a, b) => rank(a) - rank(b));
      return features[0] || null;
    }

    map.on('mousemove', (e) => {
      const f = hit(e.point);
      const same = f && hovered && f.source === hovered.source && f.id === hovered.id && f.sourceLayer === hovered.sourceLayer;
      if (same) return;
      setState(hovered, 'hover', false);
      hovered = f ? { source: f.source, sourceLayer: f.sourceLayer, id: f.id } : null;
      setState(hovered, 'hover', true);
      map.getCanvas().style.cursor = f ? 'pointer' : '';
    });
    map.on('mouseout', () => { setState(hovered, 'hover', false); hovered = null; });

    map.on('click', async (e) => {
      const f = hit(e.point);
      setState(selected, 'selected', false);
      if (!f) { closeInspector(); return; }
      selected = { source: f.source, sourceLayer: f.sourceLayer, id: f.id };
      setState(selected, 'selected', true);
      if (f.source.startsWith('data-') && f.id != null) {
        try {
          const details = await fetch('greece://module/feature/' + encodeURIComponent(f.id)).then((r) => r.json());
          showInspector(details, e.lngLat);
        } catch (err) {
          kit.post('log', 'feature: ' + err);
        }
      } else {
        const props = Object.keys(f.properties || {}).map((k) => [k, String(f.properties[k]), typeof f.properties[k] === 'number' ? 'n' : 's']);
        showInspector({ layer: f.sourceLayer || 'Tile', geometry: f.geometry ? geometryName(f.geometry.type) : '', properties: props }, e.lngLat);
      }
    });

    function geometryName(type) {
      return { Point: 'Point', MultiPoint: 'Points', LineString: 'Line', MultiLineString: 'Lines', Polygon: 'Polygon', MultiPolygon: 'Polygons' }[type] || type;
    }

    function titleOf(details) {
      if (details.name) return details.name;
      const keys = ['name', 'Name', 'NAME', 'title', 'label', 'id'];
      for (const k of keys) {
        const p = (details.properties || []).find((row) => row[0] === k && row[1]);
        if (p) return p[1];
      }
      return details.geometry || 'Feature';
    }

    function closeInspector() {
      setState(selected, 'selected', false);
      selected = null;
      const card = cards.querySelector('.inspector');
      if (card) card.remove();
    }

    function showInspector(details, lngLat) {
      const old = cards.querySelector('.inspector');
      if (old) old.remove();
      const card = document.createElement('section');
      card.className = 'glass card inspector' + (old ? '' : ' appearing');
      card.setAttribute('aria-label', 'Feature');
      const subtitle = [details.layer, details.geometry, details.length, details.area].filter(Boolean).map(esc).join(' · ');
      const rows = (details.properties || []).filter((r) => r[0] !== 'name' || r[1] !== details.name).map(([key, value, kind]) => {
        let cell;
        if (kind === 'z') cell = '<span class="null">—</span>';
        else if (kind === 'j') cell = `<code>${esc(value)}</code>`;
        else if (kind === 'n') cell = `<span class="num">${esc(formatNumber(value))}</span>`;
        else if (kind === 'b') cell = `<span class="bool">${value === 'true' ? 'Yes' : 'No'}</span>`;
        else if (/^https?:\/\/\S+$/.test(value)) cell = `<a href="${esc(value)}">${esc(value)}</a>`;
        else cell = esc(value);
        return `<tr><th scope="row">${esc(key)}</th><td>${cell}</td></tr>`;
      }).join('');
      const position = details.position ? `<div class="position"><span>${esc(details.position)}</span><button class="link" type="button" data-copy="${esc(details.position)}">Copy</button></div>` : '';
      card.innerHTML = `
        <header>
          <div class="titles"><h2>${esc(titleOf(details))}</h2>${subtitle ? `<p>${subtitle}</p>` : ''}</div>
          <button class="close" type="button" aria-label="Close" title="Close">${ICONS.close}</button>
        </header>
        <div class="body">
          ${position}
          <div class="detail" hidden></div>
          ${rows ? `<table class="props">${rows}</table>` : (details.detail ? '' : '<p class="none">No attributes</p>')}
        </div>`;
      if (details.detail) {
        const detail = card.querySelector('.detail');
        const template = document.createElement('template');
        template.innerHTML = /<[a-z][\s\S]*>/i.test(details.detail) ? details.detail : esc(details.detail).replace(/\n/g, '<br>');
        kit.sanitize(template.content);
        detail.appendChild(template.content);
        detail.hidden = false;
      }
      card.querySelector('.close').onclick = closeInspector;
      const copy = card.querySelector('[data-copy]');
      if (copy) copy.onclick = () => kit.copyText(copy.dataset.copy, copy);
      cards.prepend(card);
      // Keep the selection in view when the card covers it.
      const p = map.project(lngLat);
      if (p.x < card.offsetWidth + 40) map.easeTo({ center: map.unproject([p.x - (card.offsetWidth + 80 - p.x) / 2, p.y]), duration: 180 });
    }

    function formatNumber(value) {
      const n = Number(value);
      if (!isFinite(n)) return value;
      if (Number.isInteger(n) && Math.abs(n) >= 1900 && Math.abs(n) <= 2100) return String(n);
      return n.toLocaleString(undefined, { maximumFractionDigits: 6 });
    }

    // ---------------------------------------------------------------- Layers panel

    function renderLayersPanel() {
      const sections = [];
      if (dataLayers.length) {
        const rows = dataLayers.map((d) => {
          const counts = [];
          if (d.layer.polygons) counts.push(`${d.layer.polygons.toLocaleString()} ${d.layer.polygons === 1 ? 'area' : 'areas'}`);
          if (d.layer.lines) counts.push(`${d.layer.lines.toLocaleString()} ${d.layer.lines === 1 ? 'line' : 'lines'}`);
          if (d.layer.points) counts.push(`${d.layer.points.toLocaleString()} ${d.layer.points === 1 ? 'point' : 'points'}`);
          const swatch = OSM_ROLES.has(d.layer.role) ? '' : `<span class="swatch" style="--swatch:${color(d.index)}"></span>`;
          return `<label class="row"><input type="checkbox" data-layer="${d.index}" ${d.layer.hidden ? '' : 'checked'}>${swatch}<span class="name">${esc(d.layer.name)}</span><span class="count">${esc(counts.join(', '))}</span></label>`;
        }).join('');
        sections.push(`<h3>${esc(data.format === 'geopackage' ? 'Tables' : data.format === 'topojson' ? 'Objects' : 'Layers')}</h3>${rows}`);
      }
      const vector = Object.keys(vectorLayerIDs);
      if (vector.length) {
        const rows = vector.map((key) => {
          const v = vectorLayerIDs[key];
          return `<label class="row"><input type="checkbox" data-vector="${esc(key)}" ${v.hidden ? '' : 'checked'}><span class="swatch" style="--swatch:${v.color}"></span><span class="name">${esc(v.name)}</span></label>`;
        }).join('');
        sections.push(`<h3>Tile Layers</h3>${rows}`);
      }
      const mapRows = [];
      if (!planar) {
        mapRows.push(`<label class="row"><input type="checkbox" data-toggle="basemap" ${state.basemap ? 'checked' : ''}><span class="name">Basemap</span></label>`);
        mapRows.push(`<label class="row"><input type="checkbox" data-toggle="grid" ${state.grid ? 'checked' : ''}><span class="name">Grid</span></label>`);
      }
      if (labelMarkers.length) mapRows.push(`<label class="row"><input type="checkbox" data-toggle="labels" ${state.labels ? 'checked' : ''}><span class="name">Labels</span></label>`);
      if (mapRows.length) sections.push(`<h3>Map</h3>${mapRows.join('')}`);
      const crs = data.crs ? `<p class="crs">${esc(data.crs)}${data.reprojected ? '<br>Reprojected to WGS 84 for display' : ''}</p>` : '';
      layersPanel.innerHTML = sections.join('') + crs + (planar ? '' : '<p class="credit">Basemap: Natural Earth</p>');
      layersPanel.querySelectorAll('input[data-layer]').forEach((input) => {
        input.onchange = () => { const d = dataLayers.find((x) => String(x.index) === input.dataset.layer); if (d) setLayerVisible(d, input.checked); };
      });
      layersPanel.querySelectorAll('input[data-vector]').forEach((input) => {
        input.onchange = () => {
          const v = vectorLayerIDs[input.dataset.vector];
          v.hidden = !input.checked;
          v.ids.forEach((id) => map.setLayoutProperty(id, 'visibility', input.checked ? 'visible' : 'none'));
        };
      });
      layersPanel.querySelectorAll('input[data-toggle]').forEach((input) => {
        input.onchange = () => {
          if (input.dataset.toggle === 'basemap') setBasemap(input.checked);
          if (input.dataset.toggle === 'grid') setGrid(input.checked);
          if (input.dataset.toggle === 'labels') { state.labels = input.checked; updateLabels(); }
        };
      });
    }

    function togglePanel(open) {
      const show = open != null ? open : layersPanel.hidden;
      if (show) renderLayersPanel();
      layersPanel.hidden = !show;
      $('#layers-button').setAttribute('aria-expanded', String(show));
      $('#layers-button').classList.toggle('active', show);
    }

    $('#layers-button').onclick = (e) => { e.stopPropagation(); togglePanel(); };
    $('#fit-button').onclick = () => fitAll(true);
    $('#zoom-in').onclick = () => map.zoomIn({ duration: 160 });
    $('#zoom-out').onclick = () => map.zoomOut({ duration: 160 });
    document.addEventListener('click', (e) => {
      if (!layersPanel.hidden && !layersPanel.contains(e.target) && !e.target.closest('#layers-button')) togglePanel(false);
    });
    document.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === 'Escape') { if (!layersPanel.hidden) togglePanel(false); else closeInspector(); }
      else if (e.key === 'f' || e.key === 'F' || e.key === '0') fitAll(true);
      else if (e.key === 'g' || e.key === 'G') { if (!planar) setGrid(!state.grid); if (!layersPanel.hidden) renderLayersPanel(); }
      else if (e.key === 'l' || e.key === 'L') togglePanel();
      else if (e.key === '=' || e.key === '+') map.zoomIn({ duration: 160 });
      else if (e.key === '-' || e.key === '_') map.zoomOut({ duration: 160 });
    });

    // ---------------------------------------------------------------- Tile metadata

    function showTileCard() {
      if (!tiles.length || data.format !== 'mbtiles') return;
      const t = tiles[0];
      const meta = {};
      (t.metadata || []).forEach(([k, v]) => { meta[k] = v; });
      const zoomRange = t.minzoom === t.maxzoom ? `${t.minzoom}` : `${t.minzoom}–${t.maxzoom}`;
      const rows = [
        ['Format', t.kind === 'vector' ? 'Vector tiles (PBF)' : t.format.toUpperCase()],
        ['Type', meta.type],
        ['Zoom', zoomRange],
        ['Showing', `<span class="current-zoom"></span>`],
        ['Tile size', t.kind === 'raster' ? `${t.tileSize} px` : null],
        ['Layers', t.kind === 'vector' ? String(t.vectorLayers.length) : null],
        ['Bounds', t.bounds ? t.bounds.map((v) => Number(v).toFixed(3)).join(', ') : null],
        ['Center', meta.center],
        ['Version', meta.version],
        ['Scheme', meta.scheme],
        ['Generator', meta.generator],
      ].filter((r) => r[1] != null && r[1] !== '');
      const card = document.createElement('section');
      card.className = 'glass card tiles-card';
      const description = meta.description ? `<p class="description">${esc(stripTags(meta.description))}</p>` : '';
      const attribution = t.attribution ? `<p class="attribution-text">${esc(stripTags(t.attribution))}</p>` : '';
      card.innerHTML = `
        <header><div class="titles"><h2>${esc(t.name)}</h2><p>MBTiles · ${esc(t.kind === 'vector' ? 'Vector' : 'Raster')}</p></div>
          <button class="collapse" type="button" aria-label="Collapse" aria-expanded="true">${ICONS.chevron}</button></header>
        <div class="body">${description}<table class="props">${rows.map(([k, v]) => `<tr><th scope="row">${esc(k)}</th><td>${k === 'Showing' ? v : esc(v)}</td></tr>`).join('')}</table>${attribution}</div>`;
      const button = card.querySelector('.collapse');
      button.onclick = () => {
        const collapsed = card.classList.toggle('collapsed');
        button.setAttribute('aria-expanded', String(!collapsed));
      };
      cards.appendChild(card);
      const zoomLabel = card.querySelector('.current-zoom');
      const update = () => { zoomLabel.textContent = `Zoom ${map.getZoom().toFixed(1)}${map.getZoom() > t.maxzoom + 0.01 ? ' (overzoomed)' : ''}`; };
      map.on('zoom', update);
      update();
      if (t.attribution) $('.attribution').textContent = stripTags(t.attribution);
    }

    function stripTags(text) {
      const template = document.createElement('template');
      template.innerHTML = String(text);
      return (template.content.textContent || '').replace(/\s+/g, ' ').trim();
    }

    // ---------------------------------------------------------------- Notices

    function showNotices() {
      const list = (data.notices || []).slice(0, 4);
      $('.notices').innerHTML = list.map((n) => `<div class="glass notice-pill">${ICONS.info}<span>${esc(n)}</span></div>`).join('');
    }

    // ---------------------------------------------------------------- Tracks

    const trackMarker = (() => {
      const element = document.createElement('div');
      element.className = 'track-dot';
      return new maplibregl.Marker({ element });
    })();

    function speedText(metresPerSecond) {
      if (metresPerSecond == null) return null;
      return imperial ? `${(metresPerSecond * 2.236936).toFixed(1)} mph` : `${(metresPerSecond * 3.6).toFixed(1)} km/h`;
    }
    function distanceText(m) {
      if (imperial) { const mi = m / 1609.344; return mi < 0.2 ? `${Math.round(m * 3.28084).toLocaleString()} ft` : `${mi.toFixed(mi < 100 ? 1 : 0)} mi`; }
      return m < 1000 ? `${Math.round(m).toLocaleString()} m` : `${(m / 1000).toFixed(m < 100000 ? 1 : 0)} km`;
    }
    function elevationText(m) { return imperial ? `${Math.round(m * 3.28084).toLocaleString()} ft` : `${Math.round(m).toLocaleString()} m`; }
    function durationText(s) {
      if (s == null) return null;
      const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60);
      return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
    }

    /** The profile card is for track files; a KML of places with one small track keeps its map. */
    function showsProfile() {
      const tracks = data.tracks || [];
      if (!tracks.length) return false;
      if (data.format === 'gpx') return true;
      return data.stats.polygons === 0 && data.stats.lines <= tracks.length && data.stats.points <= 6;
    }

    function showTrack(index) {
      const tracks = data.tracks || [];
      if (!showsProfile()) return;
      const t = tracks[index];
      const stats = [
        ['Distance', distanceText(t.distance)],
        ['Duration', durationText(t.duration)],
        ['Moving', t.movingTime && t.duration && t.movingTime < t.duration - 60 ? durationText(t.movingTime) : null],
        ['Elevation Gain', t.gain != null ? elevationText(t.gain) : null],
        ['Highest', t.maxElevation != null ? elevationText(t.maxElevation) : null],
        ['Max Speed', speedText(t.maxSpeed)],
        ['Avg Speed', speedText(t.averageSpeed)],
        ['Avg Heart Rate', t.averageHeartRate ? `${Math.round(t.averageHeartRate)} bpm` : null],
      ].filter((s) => s[1]);
      const picker = tracks.length > 1
        ? `<select class="track-picker" aria-label="Track">${tracks.map((x, i) => `<option value="${i}" ${i === index ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select>`
        : `<h2>${esc(t.name)}</h2>`;
      const hasElevation = t.samples.some((s) => s[1] != null);
      trackCard.innerHTML = `
        <div class="track-head">${picker}<div class="track-stats">${stats.map(([k, v]) => `<div class="stat"><span class="label">${esc(k)}</span><span class="value">${esc(v)}</span></div>`).join('')}</div></div>
        ${hasElevation ? '<div class="profile"><svg class="chart" preserveAspectRatio="none"></svg><div class="profile-tip" hidden></div></div>' : ''}`;
      trackCard.hidden = false;
      html.classList.add('has-track');
      const picker2 = trackCard.querySelector('.track-picker');
      if (picker2) picker2.onchange = () => showTrack(Number(picker2.value));
      if (hasElevation) drawProfile(t);
    }

    function drawProfile(t) {
      const box = trackCard.querySelector('.profile');
      const svg = box.querySelector('svg');
      const tip = box.querySelector('.profile-tip');
      const samples = t.samples.filter((s) => s[1] != null);
      if (samples.length < 2) { box.remove(); return; }
      const render = () => {
        const width = box.clientWidth, height = box.clientHeight;
        if (!width || !height) return;
        const pad = { left: 44, right: 10, top: 8, bottom: 18 };
        const total = samples[samples.length - 1][0] || 1;
        let lo = Math.min(...samples.map((s) => s[1])), hi = Math.max(...samples.map((s) => s[1]));
        const span = Math.max(hi - lo, imperial ? 30 : 10);
        const niceStep = niceNumber(span / 2.5);
        lo = Math.floor(lo / niceStep) * niceStep;
        hi = Math.max(Math.ceil(hi / niceStep) * niceStep, lo + niceStep);
        const x = (d) => pad.left + (d / total) * (width - pad.left - pad.right);
        const y = (e) => pad.top + (1 - (e - lo) / (hi - lo)) * (height - pad.top - pad.bottom);
        let line = '';
        samples.forEach((s, i) => { line += `${i ? 'L' : 'M'}${x(s[0]).toFixed(1)},${y(s[1]).toFixed(1)}`; });
        const area = `${line}L${x(total).toFixed(1)},${height - pad.bottom}L${x(0).toFixed(1)},${height - pad.bottom}Z`;
        let grid = '';
        for (let e = lo; e <= hi + 1e-9; e += niceStep) {
          grid += `<line class="grid" x1="${pad.left}" x2="${width - pad.right}" y1="${y(e).toFixed(1)}" y2="${y(e).toFixed(1)}"/>`;
          grid += `<text class="axis" x="${pad.left - 6}" y="${(y(e) + 3.5).toFixed(1)}" text-anchor="end">${esc(elevationText(e))}</text>`;
        }
        const ticks = [0, total / 2, total].map((d, i) => `<text class="axis" x="${x(d).toFixed(1)}" y="${height - 4}" text-anchor="${['start', 'middle', 'end'][i]}">${esc(distanceText(d))}</text>`).join('');
        svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
        svg.innerHTML = `<defs><linearGradient id="profile-fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--track)" stop-opacity="0.32"/><stop offset="1" stop-color="var(--track)" stop-opacity="0.03"/></linearGradient></defs>
          ${grid}<path class="area" d="${area}"/><path class="line" d="${line}"/>${ticks}<line class="cursor" y1="${pad.top}" y2="${height - pad.bottom}" hidden/><circle class="cursor-dot" r="3.5" hidden/>`;
        const cursor = svg.querySelector('.cursor'), dot = svg.querySelector('.cursor-dot');
        svg.onmousemove = (e) => {
          const rect = svg.getBoundingClientRect();
          const d = Math.max(0, Math.min(total, ((e.clientX - rect.left - pad.left) / (width - pad.left - pad.right)) * total));
          let i = 0;
          while (i < samples.length - 1 && samples[i + 1][0] < d) i++;
          const s = samples[i];
          cursor.setAttribute('x1', x(s[0])); cursor.setAttribute('x2', x(s[0])); cursor.hidden = false;
          cursor.removeAttribute('hidden');
          dot.setAttribute('cx', x(s[0])); dot.setAttribute('cy', y(s[1])); dot.removeAttribute('hidden');
          const parts = [distanceText(s[0]), elevationText(s[1])];
          if (s[2] != null) parts.push(durationText(s[2]));
          if (s[5] != null) parts.push(`${Math.round(s[5])} bpm`);
          tip.textContent = parts.join(' · ');
          tip.hidden = false;
          tip.style.left = `${Math.min(Math.max(x(s[0]) - tip.offsetWidth / 2, 0), width - tip.offsetWidth)}px`;
          if (s[3] != null && s[4] != null) trackMarker.setLngLat([s[3], s[4]]).addTo(map);
        };
        svg.onmouseleave = () => { cursor.setAttribute('hidden', ''); dot.setAttribute('hidden', ''); tip.hidden = true; trackMarker.remove(); };
      };
      render();
      new ResizeObserver(render).observe(box);
    }

    function niceNumber(value) {
      const exponent = Math.floor(Math.log10(Math.max(value, 1e-9)));
      const fraction = value / Math.pow(10, exponent);
      const nice = fraction < 1.5 ? 1 : fraction < 3 ? 2 : fraction < 7 ? 5 : 10;
      return nice * Math.pow(10, exponent);
    }

    // ---------------------------------------------------------------- Theme

    function applyTheme() {
      theme = dark.matches ? THEMES.dark : THEMES.light;
      html.style.setProperty('--track', theme.layers[0]);
      if (!map.getLayer('background')) return;
      map.setPaintProperty('background', 'background-color', backgroundColor());
      const set = (id, key, value) => { if (map.getLayer(id)) map.setPaintProperty(id, key, value); };
      set('bm-land', 'fill-color', theme.land);
      set('bm-lakes', 'fill-color', theme.lakes);
      set('bm-rivers', 'line-color', theme.rivers);
      set('bm-states', 'line-color', theme.states);
      set('bm-borders', 'line-color', theme.borders);
      set('graticule', 'line-color', theme.graticule);
      dataLayers.forEach((d) => {
        const p = paintFor(d.layer, d.index);
        set(d.source + '-fill', 'fill-color', p.fill['fill-color']);
        set(d.source + '-outline', 'line-color', p.outline['line-color']);
        set(d.source + '-casing', 'line-color', p.casing['line-color']);
        set(d.source + '-line', 'line-color', p.line['line-color']);
        set(d.source + '-point', 'circle-color', p.point['circle-color']);
        set(d.source + '-point', 'circle-stroke-color', p.point['circle-stroke-color']);
      });
      Object.values(vectorLayerIDs).forEach((v) => v.ids.forEach((id) => { if (id.endsWith('-point')) set(id, 'circle-stroke-color', theme.halo); }));
      if (!layersPanel.hidden) renderLayersPanel();
    }
    dark.addEventListener('change', applyTheme);
    kit.onApply(applyTheme);

    // ---------------------------------------------------------------- Build

    html.style.setProperty('--track', theme.layers[0]);
    await addBasemap();
    addTiles();
    addOverlays();
    addGraticule();
    await addDataLayers();
    addLabels();
    showNotices();
    showTileCard();
    showTrack(0);
    if (html.classList.contains('has-track')) fitAll(false);
    if (!dataLayers.length && !tiles.length && !(data.overlays || []).length) {
      $('.notices').insertAdjacentHTML('beforeend', `<div class="glass notice-pill">${ICONS.info}<span>${esc('No features to draw')}</span></div>`);
    }
    // Let the first frame with data render before Quick Look shows the page.
    await Promise.race([new Promise((r) => map.once('idle', r)), new Promise((r) => setTimeout(r, 1500))]);
  });
})();

/* Greece — Lottie player. lottie-web's light build (SVG renderer, no expression engine) plays the
   animation; Greece adds play and pause, a scrubber with frame and time, speed, markers and backgrounds. */
(function () {
  'use strict';
  const M = window.GreeceMedia;
  const { el } = M;

  let shown = false;

  /** Points image assets at files beside the JSON (read through greece://file), and keeps fonts local. */
  function prepare(json, directory) {
    for (const asset of json.assets || []) {
      if (typeof asset.p !== 'string' || asset.layers) continue;
      if (asset.e === 1 || asset.p.startsWith('data:')) {
        // Embedded images stay data URLs; anything else claiming to be embedded is dropped.
        if (!asset.p.startsWith('data:image/')) asset.p = '';
        continue;
      }
      const folder = typeof asset.u === 'string' ? asset.u : '';
      if (!directory || /[:\\]/.test(folder + asset.p) || (folder + asset.p).includes('..')) { asset.p = ''; asset.u = ''; continue; }
      const path = (directory.replace(/\/$/, '') + '/' + folder.replace(/^\//, '')).split('/').map(encodeURIComponent).join('/');
      asset.u = 'greece://file' + path.replace(/\/?$/, '/');
      asset.p = encodeURIComponent(asset.p);
    }
    // Web fonts would be fetched from the network: use the system's instead.
    if (json.fonts && Array.isArray(json.fonts.list)) {
      for (const font of json.fonts.list) { delete font.fPath; delete font.fClass; font.fOrigin = 'n'; }
    }
    return json;
  }

  window.greece.register('media-lottie', async (data, kit) => {
    kit.afterReady(() => { shown = true; });
    const root = kit.root;
    if (!window.lottie) return kit.empty(kit.t('The Lottie player is missing'));

    const stage = el('div', { class: 'lottie-stage checker' });
    const canvas = el('div', { class: 'canvas', title: `${kit.t('Click to play or pause')} (K)` });
    stage.appendChild(canvas);
    root.appendChild(stage);

    let animation = null;
    let info = data.animations[0];
    let playing = false;
    let speed = 1;

    // ------------------------------------------------------------ Controls
    const playButton = M.button({ icon: 'play', title: `${kit.t('Play')} (K)` });
    const time = el('div', { class: 'time' });
    const scrub = M.range(0, 1, 1, 0, (value) => {
      if (!animation) return;
      animation.goToAndStop(value, true);
      update();
    });
    let resumeAfterScrub = false;
    scrub.addEventListener('pointerdown', () => { resumeAfterScrub = playing; pause(); });
    scrub.addEventListener('pointerup', () => { if (resumeAfterScrub) play(); });

    const loopButton = M.button({ icon: 'loop', title: kit.t('Loop') });
    let loop = true;
    loopButton.classList.add('on');
    loopButton.addEventListener('click', () => {
      loop = !loop;
      loopButton.classList.toggle('on', loop);
      if (animation) animation.loop = loop;
    });

    // One button cycles the backdrop: transparency checkerboard, white, black.
    const backgrounds = [
      ['checker', () => kit.t('Background: Checkerboard')],
      ['bg-light', () => kit.t('Background: White')],
      ['bg-dark', () => kit.t('Background: Black')],
    ];
    let backgroundIndex = 0;
    const background = M.button({ icon: 'checker', title: `${backgrounds[0][1]()} (B)` });
    background.addEventListener('click', () => {
      stage.classList.remove(backgrounds[backgroundIndex][0]);
      backgroundIndex = (backgroundIndex + 1) % backgrounds.length;
      stage.classList.add(backgrounds[backgroundIndex][0]);
      background.title = `${backgrounds[backgroundIndex][1]()} (B)`;
      background.classList.toggle('on', backgroundIndex !== 0);
    });
    const speeds = M.segmented([0.5, 1, 2].map((s) => ({ value: s, label: kit.number(s) + '×', title: kit.t('Speed {0}', kit.number(s) + '×') })), 1, (value) => {
      speed = value;
      if (animation) animation.setSpeed(speed);
    });

    const bar = el('div', { class: 'lottie-controls' }, [playButton, el('div', { class: 'scrub' }, [scrub]), time, loopButton, speeds, background]);
    if (data.animations.length > 1) {
      bar.insertBefore(M.select(data.animations.map((a, i) => ({ value: i, label: a.name || a.id })), 0, (index) => load(index)), bar.firstChild.nextSibling);
    }
    root.appendChild(bar);
    const markers = el('div', { class: 'lottie-markers' });
    root.appendChild(markers);
    const badge = el('div', { class: 'lottie-badge' });
    root.appendChild(badge);

    function layout() {
      const width = stage.clientWidth - 48, height = stage.clientHeight - 48;
      const scale = Math.min(width / info.width, height / info.height);
      const w = Math.max(info.width * scale, 1), h = Math.max(info.height * scale, 1);
      Object.assign(canvas.style, { width: w + 'px', height: h + 'px', left: (stage.clientWidth - w) / 2 + 'px', top: (stage.clientHeight - h) / 2 + 'px' });
      if (animation) animation.resize();
    }

    function update() {
      if (!animation) return;
      const total = Math.max(animation.totalFrames, 1);
      const frame = Math.min(Math.max(animation.currentFrame, 0), total);
      scrub.max = String(Math.max(total - 1, 1));
      scrub.value = String(frame);
      M.paintRange(scrub);
      const seconds = frame / info.frameRate, duration = total / info.frameRate;
      const fixed = (value) => kit.esc(kit.number(value, { minimumFractionDigits: 2, maximumFractionDigits: 2 }));
      time.innerHTML = `<b>${fixed(seconds)}</b> / ${fixed(duration)} s · ${kit.esc(String(Math.round(frame)))}/${kit.esc(String(Math.round(total)))}`;
      playButton.innerHTML = M.icon(playing ? 'pause' : 'play');
      playButton.title = `${playing ? kit.t('Pause') : kit.t('Play')} (K)`;
    }

    function play() { if (!animation) return; playing = true; animation.play(); update(); }
    function pause() { if (!animation) return; playing = false; animation.pause(); update(); }
    const toggle = () => (playing ? pause() : play());
    playButton.addEventListener('click', toggle);
    canvas.addEventListener('click', toggle);

    async function load(index) {
      info = data.animations[index];
      if (animation) { animation.destroy(); animation = null; }
      canvas.innerHTML = '';
      markers.innerHTML = '';
      badge.innerHTML = '';
      layout();
      let json;
      try { json = prepare(await M.fetchJSON(`animation/${index}.json`), data.packaged ? null : data.directory); }
      catch (_) { canvas.appendChild(el('div', { class: 'empty', text: kit.t('This animation couldn’t be read.') })); return; }
      try {
        animation = window.lottie.loadAnimation({
          container: canvas, renderer: 'svg', loop, autoplay: false, animationData: json,
          rendererSettings: { preserveAspectRatio: 'xMidYMid meet', progressiveLoad: false, hideOnTransparent: true },
        });
      } catch (error) {
        kit.post('log', 'lottie: ' + error);
        canvas.appendChild(el('div', { class: 'empty', text: kit.t('This animation couldn’t be played.') }));
        return;
      }
      animation.setSpeed(speed);
      await new Promise((resolve) => {
        animation.addEventListener('DOMLoaded', resolve);
        animation.addEventListener('data_failed', resolve);
        setTimeout(resolve, 1500);
      });
      animation.addEventListener('enterFrame', update);
      animation.addEventListener('complete', () => { playing = false; update(); });
      animation.goToAndStop(0, true);
      layout();
      update();

      // Marker chips sit above the controls: give them room below the animation.
      stage.classList.toggle('with-markers', (info.markers || []).length > 0);
      layout();
      for (const marker of info.markers || []) {
        const chip = el('button', { type: 'button', class: 'm-chip', text: marker.name, title: kit.t('Play from frame {0}', Math.round(marker.start)) });
        chip.addEventListener('click', () => {
          const start = Math.max(marker.start - info.inPoint, 0);
          if (marker.duration > 0) animation.playSegments([marker.start, marker.start + marker.duration], true);
          else animation.goToAndPlay(start, true);
          playing = true;
          update();
        });
        markers.appendChild(chip);
      }
      if (info.hasExpressions) badge.appendChild(el('span', { class: 'm-chip', title: kit.t('Lottie expressions are code; Greece doesn’t run them, so some motion may differ.'), text: kit.t('Expressions not evaluated') }));

      // Start playing once Quick Look is actually showing the page.
      if (shown) play(); else kit.afterReady(play);
    }

    document.addEventListener('keydown', (event) => {
      if (!animation || event.metaKey || event.ctrlKey || event.altKey) return;
      const step = event.shiftKey ? 10 : 1;
      switch (event.key) {
        case 'k': case 'K': toggle(); break;
        case 'b': case 'B': background.click(); break;
        case 'ArrowLeft': pause(); animation.goToAndStop(Math.max(animation.currentFrame - step, 0), true); update(); break;
        case 'ArrowRight': pause(); animation.goToAndStop(Math.min(animation.currentFrame + step, animation.totalFrames - 1), true); update(); break;
        case 'Home': pause(); animation.goToAndStop(0, true); update(); break;
        case 'End': pause(); animation.goToAndStop(animation.totalFrames - 1, true); update(); break;
        default: return;
      }
      event.preventDefault();
    });
    window.addEventListener('resize', layout);
    await load(0);
  });
})();

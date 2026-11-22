/* Greece — 3D models and point clouds.
   three.js draws the model with studio lighting and a soft contact shadow; GreeceKit supplies the
   file's facts and units, and (for LAS) an evenly spaced sample of its points. Models, textures and
   sidecar files are read from greece://file; decoders (Draco, Meshopt, Basis, LASzip) are bundled. */
(function () {
  'use strict';

  const G = self.GreeceThree;
  if (!window.greece) return;

  const ICON = {
    shaded: '<svg viewBox="0 0 16 16"><path d="M8 1.6 13.9 4.9v6.3L8 14.4 2.1 11.2V4.9Z" fill="currentColor" opacity=".9"/><path d="M2.1 4.9 8 8.2l5.9-3.3M8 8.2v6.2" fill="none" stroke="var(--mv-glyph-cut)" stroke-width="1.1" stroke-linejoin="round"/></svg>',
    wireframe: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"><path d="M8 1.6 13.9 4.9v6.3L8 14.4 2.1 11.2V4.9Z"/><path d="M2.1 4.9 8 8.2l5.9-3.3M8 8.2v6.2" /><path d="M2.1 11.2 8 8.2l5.9 3" opacity=".45"/></svg>',
    play: '<svg viewBox="0 0 16 16"><path d="M5 3.1v9.8c0 .55.6.88 1.06.58l7.5-4.9a.7.7 0 0 0 0-1.16l-7.5-4.9C5.6 2.22 5 2.55 5 3.1Z" fill="currentColor"/></svg>',
    pause: '<svg viewBox="0 0 16 16" fill="currentColor"><rect x="3.9" y="2.9" width="2.7" height="10.2" rx=".8"/><rect x="9.4" y="2.9" width="2.7" height="10.2" rx=".8"/></svg>',
    reset: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round"><path d="M3.3 8.6A4.8 4.8 0 1 0 4.9 4.2"/><path d="M2.9 2.3v3.2h3.2"/></svg>',
    info: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.25"/><path d="M8 7.3v3.9" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="5" r=".85" fill="currentColor"/></svg>',
    warning: '<svg viewBox="0 0 16 16"><path d="M7.1 2.4a1 1 0 0 1 1.8 0l5.6 10.1a1 1 0 0 1-.9 1.5H2.4a1 1 0 0 1-.9-1.5Z" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/><path d="M8 6.2v3.3" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/><circle cx="8" cy="11.6" r=".8" fill="currentColor"/></svg>',
  };

  const UNIT_NAMES = { m: 'm', cm: 'cm', mm: 'mm', 'µm': 'µm', in: 'in', ft: 'ft', 'US ft': 'US ft', km: 'km' };
  const CLASS_NAMES = {
    0: 'Never classified', 1: 'Unclassified', 2: 'Ground', 3: 'Low vegetation', 4: 'Medium vegetation',
    5: 'High vegetation', 6: 'Building', 7: 'Low noise', 8: 'Key point', 9: 'Water', 10: 'Rail', 11: 'Road',
    12: 'Overlap', 13: 'Wire guard', 14: 'Wire conductor', 15: 'Tower', 16: 'Wire connector', 17: 'Bridge deck', 18: 'High noise',
  };
  const CLASS_COLORS = {
    0: [176, 176, 180], 1: [176, 176, 180], 2: [168, 128, 88], 3: [170, 210, 140], 4: [112, 190, 84], 5: [46, 139, 70],
    6: [224, 122, 95], 7: [200, 90, 214], 8: [255, 209, 102], 9: [61, 139, 253], 10: [141, 110, 99], 11: [108, 117, 125],
    12: [173, 181, 189], 13: [255, 209, 102], 14: [255, 190, 11], 15: [251, 133, 0], 16: [255, 183, 3], 17: [131, 56, 236], 18: [255, 0, 110],
  };
  // Low to high: deep blue, teal, green, sand, orange, red.
  const ELEVATION_RAMP = [[44, 90, 160], [42, 157, 143], [138, 201, 38], [244, 211, 94], [238, 150, 75], [209, 73, 91]];

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const encodePath = (path) => path.split('/').map((part) => encodeURIComponent(part)).join('/');

  greece.register('models', async (data, kit) => {
    { const NativeBlob = self.Blob; self.Blob = function (parts, options) { if (Array.isArray(parts) && typeof parts[0] === 'string' && parts[0].length > 1000) parts = ['self.addEventListener("unhandledrejection", (e) => postMessage({ type: "error", error: "rejection " + (e.reason && (e.reason.stack || e.reason)) })); self.addEventListener("error", (e) => postMessage({ type: "error", error: "error " + e.message }));\n'].concat(parts); return new NativeBlob(parts, options); }; }
    const viewer = new ModelViewer(data, kit);
    await viewer.start();
  });

  class ModelViewer {
    constructor(data, kit) {
      this.data = data;
      this.kit = kit;
      this.facts = data.facts || {};
      this.base = data.url.slice(0, data.url.lastIndexOf('/') + 1);
      this.mode = 'shaded';
      this.playing = false;
      this.needsRender = true;
      this.framePending = false;
      this.interacting = false;
      this.dark = matchMedia('(prefers-color-scheme: dark)');
    }

    // ------------------------------------------------------------------ Page

    buildPage() {
      const { kit } = this;
      kit.root.innerHTML = `
        <div class="mv" data-state="loading">
          <canvas class="mv-canvas" aria-label="${kit.esc(this.data.name)}"></canvas>
          <canvas class="mv-still" aria-hidden="true" hidden></canvas>
          <div class="mv-status" role="status"><div class="mv-ring"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.5" pathLength="100"/></svg></div><div class="mv-status-text"></div></div>
          <aside class="mv-stats" hidden></aside>
          <div class="mv-toolbar" role="toolbar" aria-label="Model controls" hidden></div>
        </div>`;
      this.el = kit.$('.mv', kit.root);
      this.canvas = kit.$('.mv-canvas', this.el);
      this.still = kit.$('.mv-still', this.el);
      this.status = kit.$('.mv-status', this.el);
      this.statsPanel = kit.$('.mv-stats', this.el);
      this.toolbar = kit.$('.mv-toolbar', this.el);
    }

    setStatus(text, progress) {
      this.kit.$('.mv-status-text', this.status).textContent = text || '';
      const ring = this.kit.$('.mv-ring', this.status);
      ring.classList.toggle('determinate', progress != null);
      if (progress != null) ring.style.setProperty('--progress', String(Math.max(2, Math.min(100, progress * 100))));
    }

    fail(title, detail) {
      this.el.dataset.state = 'error';
      this.toolbar.hidden = true;
      this.status.innerHTML = `<div class="mv-error">${ICON.warning}<div class="mv-error-title">${this.kit.esc(title)}</div>${detail ? `<div class="mv-error-detail">${this.kit.esc(detail)}</div>` : ''}</div>`;
    }

    // ------------------------------------------------------------------ Start

    async start() {
      this.buildPage();
      const { THREE } = G;
      if (this.data.tooLarge) {
        this.fail('This model is too large to preview', 'Greece previews models up to 1 GB.');
        return;
      }
      try {
        this.renderer = new THREE.WebGLRenderer({ canvas: this.canvas, antialias: true, alpha: true, preserveDrawingBuffer: true, powerPreference: 'high-performance' });
      } catch (e) {
        this.fail('3D previews need WebGL', String(e && e.message || e));
        return;
      }
      const renderer = this.renderer;
      renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
      renderer.outputColorSpace = THREE.SRGBColorSpace;
      renderer.toneMapping = THREE.NeutralToneMapping;
      renderer.toneMappingExposure = 1;
      renderer.setClearColor(0x000000, 0);

      this.scene = new THREE.Scene();
      const pmrem = new THREE.PMREMGenerator(renderer);
      this.scene.environment = pmrem.fromScene(new G.RoomEnvironment(), 0.04).texture;
      this.scene.environmentIntensity = 0.7;
      pmrem.dispose();
      // A key light from above and to the left of the viewer gives faces distinct shading.
      this.camera = new THREE.PerspectiveCamera(30, 1, 0.01, 1000);
      this.scene.add(this.camera);
      this.key = new THREE.DirectionalLight(0xffffff, 1.3);
      this.key.position.set(-0.55, 1, 0.45);
      this.camera.add(this.key);
      this.camera.add(this.key.target);

      this.resize();
      new ResizeObserver(() => { this.resize(); if (this.controls) this.render(this.playing); }).observe(this.el);
      this.dark.addEventListener('change', () => this.applyTheme());
      this.kit.onApply(() => this.applyTheme());

      // Show the spinner only if loading is slow enough to notice.
      const spinner = setTimeout(() => { if (this.el.dataset.state === 'loading') this.el.classList.add('show-status'); }, 250);
      const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error('Reading the model took too long.')), 90000));
      const loading = Promise.race([this.load(), timeout]).then(
        () => { clearTimeout(spinner); },
        (error) => {
          clearTimeout(spinner);
          this.kit.post('log', 'model: ' + (error && (error.stack || error.message) || error));
          this.fail('Greece couldn’t open this model', describeError(error));
        });
      // Quick Look shows the page after this resolves: give small models time to appear fully drawn.
      await Promise.race([loading, sleep(2200)]);
    }

    resize() {
      const width = Math.max(1, this.el.clientWidth), height = Math.max(1, this.el.clientHeight);
      this.renderer.setSize(width, height, false);
      this.camera.aspect = width / height;
      this.camera.updateProjectionMatrix();
      if (this.pointMaterial) this.updatePointScale();
    }

    // ------------------------------------------------------------------ Loading

    async load() {
      const { data } = this;
      const { THREE } = G;
      this.manager = new THREE.LoadingManager();
      this.manager.onLoad = () => this.invalidate();
      this.setStatus('Loading');
      const onProgress = (event) => {
        if (event && event.lengthComputable && event.total > 0) this.setStatus('Loading', event.loaded / event.total);
      };

      let result;
      switch (data.format) {
        case 'las': result = await this.loadLAS(); break;
        case 'laz': result = await this.loadLAZ(); break;
        case 'pcd': result = this.cloudFromGeometry(new G.loaders.PCDLoader(this.manager).parse(await this.fetchBuffer(onProgress)).geometry); break;
        default: result = await this.loadMesh(onProgress);
      }
      this.setStatus('Preparing');
      await this.kit.tick();
      this.present(result);
    }

    async fetchBuffer(onProgress) {
      const loader = new G.THREE.FileLoader(this.manager);
      loader.setResponseType('arraybuffer');
      return loader.loadAsync(this.data.url, onProgress);
    }

    async fetchText(url) {
      const loader = new G.THREE.FileLoader(this.manager);
      return loader.loadAsync(url);
    }

    async loadMesh(onProgress) {
      const { THREE } = G;
      const L = G.loaders;
      const { data, manager } = this;
      let object, animations = [], units = this.facts.units || null, plainMaterials = false;

      switch (data.format) {
        case 'gltf': case 'glb': {
          const loader = new L.GLTFLoader(manager);
          const draco = new L.DRACOLoader(manager);
          draco.setDecoderPath(data.assets + 'three/draco/');
          draco.setWorkerLimit(2);
          loader.setDRACOLoader(draco);
          const ktx2 = new L.KTX2Loader(manager);
          ktx2.setTranscoderPath(data.assets + 'three/basis/');
          ktx2.detectSupport(this.renderer);
          loader.setKTX2Loader(ktx2);
          loader.setMeshoptDecoder(L.MeshoptDecoder);
          // GLTFLoader decodes images with createImageBitmap(fetch(blob:)), which the page's CSP
          // forbids; without it, it uses <img> elements, which may show blob: images.
          const createImageBitmap = self.createImageBitmap;
          self.createImageBitmap = undefined;
          let gltf;
          try { gltf = await loader.loadAsync(data.url, onProgress); } finally { self.createImageBitmap = createImageBitmap; }
          draco.dispose();
          ktx2.dispose();
          object = gltf.scene || (gltf.scenes && gltf.scenes[0]);
          animations = gltf.animations || [];
          units = 'm';
          break;
        }
        case 'fbx': {
          object = await new L.FBXLoader(manager).loadAsync(data.url, onProgress);
          animations = object.animations || [];
          units = fbxUnits(object.userData && object.userData.unitScaleFactor);
          break;
        }
        case 'dae': {
          const collada = await new L.ColladaLoader(manager).loadAsync(data.url, onProgress);
          object = collada.scene;
          animations = collada.scene.animations || [];
          units = 'm';   // the loader scales to metres
          break;
        }
        case '3mf': object = await new L.ThreeMFLoader(manager).loadAsync(data.url, onProgress); break;
        case 'amf': object = await new L.AMFLoader(manager).loadAsync(data.url, onProgress); break;
        case '3ds': {
          const loader = new L.TDSLoader(manager);
          loader.setResourcePath(this.base);
          object = await loader.loadAsync(data.url, onProgress);
          break;
        }
        case 'vrml': object = await new L.VRMLLoader(manager).loadAsync(data.url, onProgress); break;
        case 'obj': {
          const text = await this.fetchText(data.url);
          const loader = new L.OBJLoader(manager);
          const materials = await this.loadMTL(text);
          if (materials) loader.setMaterials(materials);
          object = loader.parse(text);
          plainMaterials = !materials;
          break;
        }
        case 'stl': {
          const geometry = new L.STLLoader(manager).parse(await this.fetchBuffer(onProgress));
          object = new THREE.Mesh(geometry, this.clayMaterial(geometry.hasColors));
          break;
        }
        case 'ply': {
          const loader = new L.PLYLoader(manager);
          if (this.facts.isSplat) loader.setCustomPropertyNameMapping({ f_dc: ['f_dc_0', 'f_dc_1', 'f_dc_2'], opacity: ['opacity'] });
          const geometry = loader.parse(await this.fetchBuffer(onProgress));
          if (!geometry.index && !this.facts.triangles && (this.facts.faces || 0) === 0) return this.cloudFromGeometry(geometry, this.facts.isSplat);
          if (!geometry.getAttribute('normal')) geometry.computeVertexNormals();
          object = new THREE.Mesh(geometry, this.clayMaterial(!!geometry.getAttribute('color')));
          break;
        }
        case 'off': {
          const geometry = parseOFF(await this.fetchText(data.url));
          object = new THREE.Mesh(geometry, this.clayMaterial(!!geometry.getAttribute('color')));
          break;
        }
        case 'vox': {
          const vox = new L.VOXLoader(manager).parse(await this.fetchBuffer(onProgress));
          if (!vox) throw new Error('Not a MagicaVoxel file');
          if (vox.scene) object = vox.scene;
          else {
            object = new THREE.Group();
            for (const chunk of vox.chunks || []) if (chunk.data) object.add(L.buildVOXMesh(chunk));
          }
          units = null;
          break;
        }
        default:
          throw new Error('Unsupported format');
      }
      if (!object) throw new Error('The file has no scene');
      return { kind: 'mesh', object, animations, units, plainMaterials };
    }

    /** Reads the OBJ's material libraries from its folder, if they're there. */
    async loadMTL(text) {
      const names = [];
      const pattern = /^[ \t]*mtllib[ \t]+(.+?)[ \t]*$/gm;
      let match;
      while ((match = pattern.exec(text)) && names.length < 4) names.push(match[1].replace(/\\/g, '/'));
      for (const name of names) {
        try {
          const loader = new G.loaders.MTLLoader(this.manager);
          loader.setResourcePath(this.base);
          const creator = await loader.loadAsync(this.base + encodePath(name.replace(/^\.\//, '')));
          creator.preload();
          return creator;
        } catch (e) { /* missing or unreadable: fall back to clay */ }
      }
      return null;
    }

    clayMaterial(vertexColors) {
      return new G.THREE.MeshStandardMaterial({
        color: vertexColors ? 0xffffff : 0xa9aeb6, roughness: 0.48, metalness: 0,
        side: G.THREE.DoubleSide, vertexColors: !!vertexColors,
      });
    }

    // ------------------------------------------------------------------ Point clouds

    async loadLAS() {
      const response = await fetch('greece://module/points');
      if (!response.ok) throw new Error('Couldn’t read the points');
      return this.cloudFromSample(decodeSample(await response.arrayBuffer()));
    }

    async loadLAZ() {
      const { data } = this;
      const header = data.las;
      if (!header) throw new Error('Not a LAS/LAZ file');
      const [file, wasm, source] = await Promise.all([
        this.fetchBuffer((e) => { if (e.lengthComputable) this.setStatus('Loading', e.loaded / e.total * 0.3); }),
        fetch(data.assets + 'laz-perf/laz-perf.wasm').then((r) => r.arrayBuffer()),
        fetch(data.assets + 'laz-perf/laz-perf.js').then((r) => r.text()),
      ]);
      const body = source + '\n;\n' + lazWorker.toString() + '\nlazWorker();\n';
      const worker = new Worker(URL.createObjectURL(new Blob([body], { type: 'text/javascript' })));
      const sample = await new Promise((resolve, reject) => {
        worker.onmessage = (e) => {
          if (e.data.progress != null) this.setStatus('Decompressing', 0.3 + e.data.progress * 0.7);
          else if (e.data.error) reject(new Error(e.data.error));
          else resolve(e.data);
        };
        worker.onerror = (e) => reject(new Error(e.message || 'decoder failed'));
        worker.postMessage({ file, wasm, header, budget: data.pointBudget }, [file, wasm]);
      });
      worker.terminate();
      return this.cloudFromSample(sample);
    }

    /** PCD and point-only PLY: three.js geometry into the same sample shape as LAS. */
    cloudFromGeometry(geometry, splat) {
      const position = geometry.getAttribute('position');
      if (!position) throw new Error('The file has no points');
      const total = position.count;
      const stride = Math.max(1, Math.ceil(total / this.data.pointBudget));
      const color = geometry.getAttribute('color');
      const dc = splat ? geometry.getAttribute('f_dc') : null;
      const opacity = splat ? geometry.getAttribute('opacity') : null;
      const intensityAttribute = geometry.getAttribute('intensity');
      const box = new G.THREE.Box3().setFromBufferAttribute(position);
      const center = box.getCenter(new G.THREE.Vector3());
      const count = Math.ceil(total / stride);
      const positions = new Float32Array(count * 3);
      const colors = color || dc ? new Uint8Array(count * 3) : null;
      const intensity = intensityAttribute ? new Uint16Array(count) : null;
      let n = 0;
      const c = new G.THREE.Color();
      for (let i = 0; i < total; i += stride) {
        // Splats nearly transparent in the radiance field are noise as points.
        if (opacity && 1 / (1 + Math.exp(-opacity.getX(i))) < 0.15) continue;
        positions[n * 3] = position.getX(i) - center.x;
        positions[n * 3 + 1] = position.getY(i) - center.y;
        positions[n * 3 + 2] = position.getZ(i) - center.z;
        if (dc) {
          for (let k = 0; k < 3; k++) colors[n * 3 + k] = clampByte((0.5 + 0.28209479 * dc.getComponent(i, k)) * 255);
        } else if (color) {
          c.setRGB(color.getX(i), color.getY(i), color.getZ(i)).convertLinearToSRGB();
          colors[n * 3] = clampByte(c.r * 255); colors[n * 3 + 1] = clampByte(c.g * 255); colors[n * 3 + 2] = clampByte(c.b * 255);
        }
        if (intensity) intensity[n] = Math.max(0, Math.min(65535, intensityAttribute.getX(i) * (intensityAttribute.getX(i) <= 1 ? 65535 : 1)));
        n++;
      }
      const order = progressiveOrder(n);
      return this.cloudFromSample({
        count: n, center: [center.x, center.y, center.z],
        positions: permute(positions.subarray(0, n * 3), order, 3),
        colors: colors && permute(colors.subarray(0, n * 3), order, 3),
        intensity: intensity && permute(intensity.subarray(0, n), order, 1),
        classes: null, total,
      });
    }

    cloudFromSample(sample) {
      if (!sample.count) throw new Error('The file has no points');
      return { kind: 'points', sample, units: this.facts.units || null };
    }

    // ------------------------------------------------------------------ Presenting

    present(result) {
      const { THREE } = G;
      this.result = result;
      this.units = result.units;
      // Upright: Z-up formats turn so their top faces the sky.
      this.pivot = new THREE.Group();
      this.content = new THREE.Group();
      this.pivot.add(this.content);
      this.scene.add(this.pivot);

      if (result.kind === 'points') {
        this.cloud = this.buildCloud(result.sample);
        this.content.add(this.cloud);
      } else {
        this.prepareObject(result.object, result.plainMaterials);
        this.content.add(result.object);
      }
      if (this.data.zUp) this.content.rotation.x = -Math.PI / 2;
      this.scene.updateMatrixWorld(true);

      // Stand the model on the ground at the origin.
      const box = new THREE.Box3().setFromObject(this.content);
      if (box.isEmpty()) throw new Error('The model is empty');
      const center = box.getCenter(new THREE.Vector3());
      this.content.position.sub(new THREE.Vector3(center.x, result.kind === 'points' ? center.y : box.min.y, center.z));
      this.scene.updateMatrixWorld(true);
      this.bounds = new THREE.Box3().setFromObject(this.content);
      this.size = this.bounds.getSize(new THREE.Vector3());

      if (result.kind === 'mesh') {
        this.shadow = new ContactShadow(this.renderer, this.scene, this.bounds);
        this.shadow.update(this.content);
      }
      this.setupAnimations(result.animations || []);
      this.setupControls();
      this.frame(false);
      this.stats = this.computeStats();
      this.buildToolbar();
      this.renderStats();
      this.applyTheme();
      this.el.dataset.state = 'ready';
      this.el.classList.remove('show-status');
      this.render();
    }

    /** Lights and cameras from files fight the studio; materials become physically based. */
    prepareObject(object, plainMaterials) {
      const { THREE } = G;
      const remove = [];
      const maxAnisotropy = this.renderer.capabilities.getMaxAnisotropy();
      const converted = new Map();
      const keepMaterials = this.data.format === 'gltf' || this.data.format === 'glb';
      object.traverse((node) => {
        if (node.isLight || node.isCamera) { remove.push(node); return; }
        if (!node.isMesh && !node.isPoints && !node.isLine) return;
        node.frustumCulled = !node.isSkinnedMesh;
        const convert = (material) => {
          if (!material) return this.clayMaterial(false);
          if (converted.has(material)) return converted.get(material);
          const result = keepMaterials ? material : toStandard(material, plainMaterials ? this.clayMaterial(!!material.vertexColors) : null);
          for (const key of Object.keys(result)) {
            const value = result[key];
            if (value && value.isTexture && !value.isCompressedTexture) value.anisotropy = maxAnisotropy;
          }
          converted.set(material, result);
          return result;
        };
        node.material = Array.isArray(node.material) ? node.material.map(convert) : convert(node.material);
        if (node.isMesh && node.geometry && !node.geometry.getAttribute('normal') && node.geometry.getAttribute('position')) {
          node.geometry.computeVertexNormals();
        }
      });
      for (const node of remove) node.removeFromParent();
      if (object.isScene) { object.background = null; object.environment = null; object.fog = null; }
    }

    // ------------------------------------------------------------------ Camera

    setupControls() {
      const { THREE } = G;
      const controls = new G.OrbitControls(this.camera, this.canvas);
      controls.enableDamping = true;
      controls.dampingFactor = 0.12;
      controls.rotateSpeed = 0.8;
      controls.enableZoom = false;   // wheel and pinch are handled below
      controls.screenSpacePanning = true;
      controls.addEventListener('change', () => this.invalidate());
      controls.addEventListener('start', () => this.setInteracting(true));
      controls.addEventListener('end', () => this.setInteracting(false));
      this.controls = controls;

      // Pinch and mouse wheels zoom; two-finger scrolling on a trackpad pans, like Maps and Preview.
      let gesture = null, gestureUntil = 0;
      this.canvas.addEventListener('wheel', (event) => {
        event.preventDefault();
        const now = performance.now();
        if (now > gestureUntil) {
          const lineMode = event.deltaMode !== 0;
          const notched = event.wheelDeltaY !== 0 && event.wheelDeltaY % 120 === 0 && event.deltaX === 0;
          gesture = event.ctrlKey ? 'zoom' : (lineMode || notched ? 'zoom' : 'pan');
        }
        gestureUntil = now + 160;
        if (event.ctrlKey || gesture === 'zoom') {
          const scale = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 400 : 1;
          this.dolly(Math.exp(event.deltaY * scale * (event.ctrlKey ? 0.012 : 0.0025)));
        } else {
          this.pan(event.deltaX, event.deltaY);
        }
        this.setInteracting(true);
        clearTimeout(this.wheelTimer);
        this.wheelTimer = setTimeout(() => this.setInteracting(false), 180);
      }, { passive: false });
      let startScale = 1;
      this.canvas.addEventListener('gesturestart', (e) => { e.preventDefault(); startScale = 1; });
      this.canvas.addEventListener('gesturechange', (e) => {
        e.preventDefault();
        this.dolly(startScale / e.scale);
        startScale = e.scale;
      });
      this.canvas.addEventListener('gestureend', (e) => e.preventDefault());
      this.canvas.addEventListener('dblclick', () => this.frame(true));
    }

    dolly(factor) {
      if (!isFinite(factor) || factor <= 0) return;
      const { camera, controls } = this;
      const offset = camera.position.clone().sub(controls.target);
      const radius = this.radius || 1;
      const distance = Math.min(Math.max(offset.length() * factor, radius * 0.02), radius * 40);
      offset.setLength(distance);
      camera.position.copy(controls.target).add(offset);
      this.updateClipping(distance);
      this.invalidate();
    }

    pan(dx, dy) {
      const { camera, controls } = this;
      const distance = camera.position.distanceTo(controls.target);
      const perPixel = 2 * distance * Math.tan(camera.fov * Math.PI / 360) / Math.max(1, this.el.clientHeight);
      const right = new G.THREE.Vector3().setFromMatrixColumn(camera.matrix, 0).multiplyScalar(dx * perPixel);
      const up = new G.THREE.Vector3().setFromMatrixColumn(camera.matrix, 1).multiplyScalar(-dy * perPixel);
      const move = right.add(up);
      camera.position.add(move);
      controls.target.add(move);
      this.invalidate();
    }

    updateClipping(distance) {
      const radius = this.radius || 1;
      this.camera.near = Math.max(distance - radius * 1.5, distance / 500, radius / 2000);
      this.camera.far = distance + radius * 4;
      this.camera.updateProjectionMatrix();
      if (this.pointMaterial) this.updatePointScale();
    }

    /** Fits the whole model at a three-quarter view, from slightly above. */
    frame(animated) {
      const { THREE } = G;
      const { camera, controls, bounds } = this;
      const center = bounds.getCenter(new THREE.Vector3());
      const sphere = bounds.getBoundingSphere(new THREE.Sphere());
      this.radius = Math.max(sphere.radius, 1e-6);
      const isCloud = this.result.kind === 'points';
      const azimuth = THREE.MathUtils.degToRad(isCloud ? 25 : 32);
      const elevation = THREE.MathUtils.degToRad(isCloud ? 38 : 20);
      const direction = new THREE.Vector3(Math.sin(azimuth) * Math.cos(elevation), Math.sin(elevation), Math.cos(azimuth) * Math.cos(elevation));

      // Tight fit: every corner of the box inside the frustum, with a margin for the toolbar.
      const view = new THREE.Matrix4().lookAt(direction, new THREE.Vector3(), new THREE.Vector3(0, 1, 0));
      const inverse = view.clone().invert();
      const tanV = Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2) * 0.8;
      const tanH = tanV * camera.aspect;
      let distance = 0;
      const corner = new THREE.Vector3();
      for (let i = 0; i < 8; i++) {
        corner.set(i & 1 ? bounds.max.x : bounds.min.x, i & 2 ? bounds.max.y : bounds.min.y, i & 4 ? bounds.max.z : bounds.min.z).sub(center).applyMatrix4(inverse);
        distance = Math.max(distance, corner.z + Math.abs(corner.x) / tanH, corner.z + Math.abs(corner.y) / tanV);
      }
      distance = Math.max(distance, this.radius * 0.5);
      // Lift the view a little so the model sits above the toolbar.
      const target = center.clone();
      target.y -= distance * Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2) * 0.06;
      const position = target.clone().add(direction.multiplyScalar(distance));

      const finish = () => {
        camera.position.copy(position);
        controls.target.copy(target);
        this.updateClipping(distance);
        controls.update();
        this.invalidate();
      };
      if (!animated) return finish();
      const fromPosition = camera.position.clone(), fromTarget = controls.target.clone();
      const started = performance.now();
      const step = () => {
        const t = Math.min(1, (performance.now() - started) / 200);
        const ease = 1 - Math.pow(1 - t, 3);
        camera.position.lerpVectors(fromPosition, position, ease);
        controls.target.lerpVectors(fromTarget, target, ease);
        this.updateClipping(camera.position.distanceTo(controls.target));
        this.invalidate();
        if (t < 1) requestAnimationFrame(step); else finish();
      };
      requestAnimationFrame(step);
    }

    setInteracting(value) {
      this.interacting = value;
      if (!this.cloud) return;
      clearTimeout(this.detailTimer);
      if (value) this.setPointDetail(false);
      else this.detailTimer = setTimeout(() => { this.setPointDetail(true); this.invalidate(); }, 160);
    }

    // ------------------------------------------------------------------ Rendering

    invalidate() {
      this.needsRender = true;
      if (this.framePending || !this.controls) return;
      this.framePending = true;
      requestAnimationFrame(() => this.tick());
    }

    tick() {
      this.framePending = false;
      const delta = this.clock ? this.clock.getDelta() : 0;
      let active = this.controls.update();
      if (this.mixer && this.playing) {
        this.mixer.update(Math.min(delta, 0.1));
        if (this.shadow) this.shadow.update(this.content);
        active = true;
      }
      if (this.needsRender || active) this.render(active || this.interacting);
      if (active || this.needsRender) this.invalidate();
    }

    /** Draws a frame. Still frames are also copied to a 2D canvas: snapshots of the view (Quick
        Look's transitions, Greece's renders) can't see WebGL layers, and the copy is pixel-identical. */
    render(live) {
      this.needsRender = false;
      this.renderer.render(this.scene, this.camera);
      if (live) {
        this.still.hidden = true;
        return;
      }
      const canvas = this.canvas;
      if (this.still.width !== canvas.width || this.still.height !== canvas.height) {
        this.still.width = canvas.width;
        this.still.height = canvas.height;
      }
      const context = this.still.getContext('2d');
      context.clearRect(0, 0, canvas.width, canvas.height);
      context.drawImage(canvas, 0, 0);
      this.still.hidden = false;
    }

    applyTheme() {
      const dark = this.dark.matches;
      if (this.wireMaterial) {
        this.wireMaterial.color.set(dark ? 0xf5f5f7 : 0x1d1d1f);
        this.wireMaterial.opacity = dark ? 0.55 : 0.6;
      }
      if (this.shadow) this.shadow.setDarkness(dark ? 0.85 : 0.6);
      this.invalidate();
      if (this.controls) this.render();
    }

    // ------------------------------------------------------------------ Shading

    /** Wireframe draws each mesh's edges over a depth-only copy of it, so hidden edges stay hidden. */
    setMode(mode) {
      const { THREE } = G;
      if (mode === this.mode) return;
      this.mode = mode;
      if (!this.wireMaterial) {
        this.wireMaterial = new THREE.MeshBasicMaterial({ wireframe: true, transparent: true, depthWrite: false });
        this.occluder = new THREE.MeshBasicMaterial({ colorWrite: false, polygonOffset: true, polygonOffsetFactor: 1, polygonOffsetUnits: 1, side: THREE.DoubleSide });
        this.applyTheme();
      }
      const each = (material, replacement) => (Array.isArray(material) ? material.map(() => replacement) : replacement);
      if (mode === 'wireframe') {
        const meshes = [];
        this.content.traverse((node) => { if (node.isMesh && !node.userData.wireCopy) meshes.push(node); });
        this.wireCopies = meshes.map((mesh) => {
          mesh.userData.shaded = mesh.material;
          mesh.material = each(mesh.material, this.occluder);
          const copy = mesh.clone(false);
          copy.material = each(mesh.userData.shaded, this.wireMaterial);
          copy.userData = { wireCopy: true };
          copy.renderOrder = 1;
          if (mesh.morphTargetInfluences) copy.morphTargetInfluences = mesh.morphTargetInfluences;
          mesh.parent.add(copy);
          return copy;
        });
      } else {
        for (const copy of this.wireCopies || []) copy.removeFromParent();
        this.wireCopies = [];
        this.content.traverse((node) => { if (node.isMesh && node.userData.shaded) node.material = node.userData.shaded; });
      }
      for (const button of this.kit.$$('[data-mode]', this.toolbar)) button.setAttribute('aria-pressed', String(button.dataset.mode === mode));
      this.invalidate();
    }

    // ------------------------------------------------------------------ Animation

    setupAnimations(clips) {
      const { THREE } = G;
      this.clips = clips.filter((clip) => clip && clip.duration > 0 && clip.tracks.length);
      if (!this.clips.length) return;
      this.mixer = new THREE.AnimationMixer(this.content);
      this.clock = new THREE.Clock();
      this.selectClip(0);
      this.playing = true;
    }

    selectClip(index) {
      if (!this.mixer) return;
      if (this.action) this.action.stop();
      this.clipIndex = index;
      this.action = this.mixer.clipAction(this.clips[index]);
      this.action.reset().play();
      this.mixer.update(0);
      if (this.shadow) this.shadow.update(this.content);
      this.invalidate();
    }

    togglePlay() {
      this.playing = !this.playing;
      if (this.clock) this.clock.getDelta();
      const button = this.kit.$('.mv-play', this.toolbar);
      if (button) {
        button.innerHTML = this.playing ? ICON.pause : ICON.play;
        button.title = this.playing ? 'Pause' : 'Play';
        button.setAttribute('aria-label', button.title);
      }
      this.invalidate();
    }

    // ------------------------------------------------------------------ Toolbar

    buildToolbar() {
      const { kit } = this;
      const parts = [];
      if (this.result.kind === 'mesh') {
        parts.push(`<div class="mv-segment" role="radiogroup" aria-label="Display">
          <button type="button" data-mode="shaded" aria-pressed="true" title="Shaded" aria-label="Shaded">${ICON.shaded}</button>
          <button type="button" data-mode="wireframe" aria-pressed="false" title="Wireframe" aria-label="Wireframe">${ICON.wireframe}</button></div>`);
      } else {
        const options = this.colorModes.map((mode) => `<option value="${mode.id}">${kit.esc(mode.title)}</option>`).join('');
        parts.push(`<label class="mv-select" title="Colour"><select class="mv-color" aria-label="Colour">${options}</select></label>`);
      }
      if (this.clips && this.clips.length) {
        parts.push('<span class="mv-divider"></span>');
        parts.push(`<button type="button" class="mv-play" title="Pause" aria-label="Pause">${ICON.pause}</button>`);
        if (this.clips.length > 1) {
          const options = this.clips.map((clip, i) => `<option value="${i}">${kit.esc(clip.name || 'Animation ' + (i + 1))}</option>`).join('');
          parts.push(`<label class="mv-select mv-clip-label" title="Animation"><select class="mv-clip" aria-label="Animation">${options}</select></label>`);
        }
      }
      parts.push('<span class="mv-divider"></span>');
      parts.push(`<button type="button" class="mv-reset" title="Reset View" aria-label="Reset View">${ICON.reset}</button>`);
      parts.push(`<button type="button" class="mv-info" title="Statistics" aria-label="Statistics" aria-pressed="false">${ICON.info}</button>`);
      this.toolbar.innerHTML = parts.join('');
      this.toolbar.hidden = false;

      this.toolbar.addEventListener('click', (event) => {
        const button = event.target.closest('button');
        if (!button) return;
        if (button.dataset.mode) this.setMode(button.dataset.mode);
        else if (button.classList.contains('mv-play')) this.togglePlay();
        else if (button.classList.contains('mv-reset')) this.frame(true);
        else if (button.classList.contains('mv-info')) this.toggleStats();
      });
      const clip = kit.$('.mv-clip', this.toolbar);
      if (clip) clip.addEventListener('change', () => this.selectClip(Number(clip.value)));
      const color = kit.$('.mv-color', this.toolbar);
      if (color) {
        color.value = this.colorMode;
        color.addEventListener('change', () => this.setColorMode(color.value));
      }
    }

    toggleStats(show) {
      const visible = show != null ? show : this.statsPanel.hidden;
      this.statsPanel.hidden = !visible;
      const button = this.kit.$('.mv-info', this.toolbar);
      if (button) button.setAttribute('aria-pressed', String(visible));
    }

    // ------------------------------------------------------------------ Statistics

    computeStats() {
      const stats = { vertices: 0, triangles: 0, meshes: 0, points: 0, lines: 0, materials: new Set(), textures: new Set(), bones: 0, morphs: 0 };
      if (this.result.kind === 'points') {
        stats.points = this.cloudCount;
        return stats;
      }
      this.content.traverse((node) => {
        const geometry = node.geometry;
        const position = geometry && geometry.getAttribute && geometry.getAttribute('position');
        if (!position) return;
        const instances = node.isInstancedMesh ? node.count : 1;
        if (node.isMesh) {
          stats.meshes += instances;
          stats.vertices += position.count * instances;
          const drawn = geometry.index ? geometry.index.count : position.count;
          stats.triangles += Math.floor(drawn / 3) * instances;
          if (geometry.morphAttributes && geometry.morphAttributes.position) stats.morphs += geometry.morphAttributes.position.length;
          if (node.isSkinnedMesh && node.skeleton) stats.bones = Math.max(stats.bones, node.skeleton.bones.length);
        } else if (node.isPoints) {
          stats.points += position.count;
        } else if (node.isLine) {
          stats.lines += position.count;
        }
        const materials = node.userData.shaded || node.material;
        for (const material of Array.isArray(materials) ? materials : [materials]) {
          if (!material) continue;
          stats.materials.add(material);
          for (const key of Object.keys(material)) {
            const value = material[key];
            if (value && value.isTexture) stats.textures.add(value);
          }
        }
      });
      stats.textureBytes = 0;
      for (const texture of stats.textures) stats.textureBytes += textureBytes(texture);
      return stats;
    }

    renderStats() {
      const { kit, stats, facts, data } = this;
      const rows = [];
      const row = (label, value) => { if (value !== null && value !== undefined && value !== '') rows.push(`<div class="mv-row"><dt>${kit.esc(label)}</dt><dd>${kit.esc(value)}</dd></div>`); };
      const number = (n) => Number(n).toLocaleString('en-US');

      const dims = this.dimensions();
      if (dims) {
        rows.push(`<div class="mv-dims">${dims.map((d) => `<div><span class="mv-dim-value">${kit.esc(d.value)}</span><span class="mv-dim-label">${kit.esc(d.label)}</span></div>`).join('')}</div>`);
      }
      if (this.result.kind === 'points') {
        const sample = this.result.sample;
        const total = (data.las && data.las.pointCount) || sample.total || facts.points || stats.points;
        row('Points', number(total));
        if (total > stats.points) row('Showing', number(stats.points));
        if (this.classesPresent && this.classesPresent.length > 1) row('Classes', String(this.classesPresent.length));
        if (data.las) {
          row('Point format', String(data.las.pointFormat));
          row('LAS version', `${data.las.versionMajor}.${data.las.versionMinor}`);
        }
      } else {
        row('Vertices', number(stats.vertices));
        row('Triangles', number(stats.triangles));
        if (stats.points) row('Points', number(stats.points));
        row('Meshes', number(stats.meshes));
        row('Materials', number(stats.materials.size));
        row('Textures', number(stats.textures.size));
        if (stats.textures.size) row('Texture memory', formatBytes(stats.textureBytes));
        if (this.clips && this.clips.length) row('Animations', number(this.clips.length));
        if (stats.bones) row('Bones', number(stats.bones));
        if (stats.morphs) row('Morph targets', number(stats.morphs));
      }
      if (facts.compression && facts.compression.length) row('Compression', facts.compression.join(', '));
      if (facts.version && !data.las && data.format !== 'vox') row('Version', facts.version);
      if (facts.generator) row('Created with', facts.generator);
      this.statsPanel.innerHTML = `<dl>${rows.join('')}</dl>`;
    }

    /** Width, depth and height of the upright model, in the file's units where it has them. */
    dimensions() {
      if (!this.size) return null;
      let scale = 1;
      let unit = this.units ? UNIT_NAMES[this.units] || this.units : '';
      if (this.data.format === 'vox') unit = 'voxels';
      const values = [this.size.x, this.size.z, this.size.y];
      if (unit === 'm') {
        const largest = Math.max(...values);
        if (largest < 0.01) { scale = 1000; unit = 'mm'; } else if (largest < 1) { scale = 100; unit = 'cm'; }
      }
      const largest = Math.max(...values) * scale;
      const digits = largest >= 1000 ? 0 : largest >= 100 ? 1 : 2;
      const format = (v) => (v * scale).toLocaleString('en-US', { maximumFractionDigits: digits });
      const suffix = unit ? ' ' + unit : '';
      return [
        { label: 'Width', value: format(values[0]) + suffix },
        { label: 'Depth', value: format(values[1]) + suffix },
        { label: 'Height', value: format(values[2]) + suffix },
      ];
    }

    // ------------------------------------------------------------------ Point cloud rendering

    buildCloud(sample) {
      const { THREE } = G;
      const geometry = new THREE.BufferGeometry();
      // Swap to Y-up here only for display; the pivot handles Z-up for meshes.
      geometry.setAttribute('position', new THREE.BufferAttribute(sample.positions, 3));
      this.cloudCount = sample.count;
      this.sample = sample;
      this.colorBuffer = new Uint8Array(sample.count * 3);
      const color = new THREE.BufferAttribute(this.colorBuffer, 3, true);
      geometry.setAttribute('color', color);
      geometry.computeBoundingBox();
      geometry.computeBoundingSphere();

      // Colour modes the data supports.
      const hasRGB = sample.colors && hasVariation(sample.colors);
      const hasIntensity = sample.intensity && hasVariation(sample.intensity);
      if (sample.classes) {
        const seen = new Set();
        for (let i = 0; i < sample.count; i += Math.max(1, Math.floor(sample.count / 200000))) seen.add(sample.classes[i]);
        this.classesPresent = Array.from(seen).sort((a, b) => a - b);
      }
      this.colorModes = [];
      if (hasRGB) this.colorModes.push({ id: 'rgb', title: 'Colour' });
      this.colorModes.push({ id: 'elevation', title: 'Elevation' });
      if (hasIntensity) this.colorModes.push({ id: 'intensity', title: 'Intensity' });
      if (this.classesPresent && this.classesPresent.length > 1) this.colorModes.push({ id: 'class', title: 'Classification' });

      // Typical spacing between neighbours, for point size.
      const box = geometry.boundingBox;
      const size = box.getSize(new THREE.Vector3());
      const dims = [size.x, size.y, size.z].sort((a, b) => b - a);
      const area = Math.max(dims[0] * dims[1], 1e-12);
      this.spacing = Math.sqrt(area / sample.count);

      this.pointMaterial = new THREE.ShaderMaterial({
        uniforms: { size: { value: this.spacing * 1.3 }, scale: { value: 1 }, minSize: { value: 1.5 }, maxSize: { value: 10 } },
        vertexShader: `
          uniform float size; uniform float scale; uniform float minSize; uniform float maxSize;
          attribute vec3 color;
          varying vec3 vColor;
          void main() {
            vColor = color;
            vec4 mv = modelViewMatrix * vec4(position, 1.0);
            gl_Position = projectionMatrix * mv;
            gl_PointSize = clamp(size * scale / max(-mv.z, 1e-6), minSize, maxSize);
          }`,
        fragmentShader: `
          varying vec3 vColor;
          void main() {
            vec2 c = gl_PointCoord * 2.0 - 1.0;
            if (dot(c, c) > 1.0) discard;
            gl_FragColor = vec4(vColor, 1.0);
          }`,
        toneMapped: false,
      });
      const points = new THREE.Points(geometry, this.pointMaterial);
      points.frustumCulled = false;
      this.colorMode = hasRGB ? 'rgb' : 'elevation';
      this.colorAttribute = color;
      this.cloudGeometry = geometry;
      this.applyColorMode();
      this.updatePointScale();
      return points;
    }

    updatePointScale() {
      if (!this.pointMaterial) return;
      const ratio = this.renderer.getPixelRatio();
      const height = this.renderer.domElement.height;
      this.pointMaterial.uniforms.scale.value = height / (2 * Math.tan(this.camera.fov * Math.PI / 360));
      this.pointMaterial.uniforms.minSize.value = 1.4 * ratio;
      this.pointMaterial.uniforms.maxSize.value = 9 * ratio;
    }

    /** Fewer points while the view moves keeps millions of them smooth; every prefix is an even sample. */
    setPointDetail(full) {
      if (!this.cloudGeometry) return;
      const interactive = 1200000;
      this.cloudGeometry.setDrawRange(0, full ? this.cloudCount : Math.min(this.cloudCount, interactive));
    }

    setColorMode(mode) {
      this.colorMode = mode;
      this.applyColorMode();
      this.invalidate();
    }

    applyColorMode() {
      const { sample, colorBuffer } = this;
      const n = sample.count;
      const out = colorBuffer;
      if (this.colorMode === 'rgb' && sample.colors) {
        out.set(sample.colors.subarray(0, n * 3));
      } else if (this.colorMode === 'intensity' && sample.intensity) {
        const [low, high] = percentiles(sample.intensity, 0.02, 0.98);
        const span = Math.max(1, high - low);
        for (let i = 0; i < n; i++) {
          const t = Math.min(1, Math.max(0, (sample.intensity[i] - low) / span));
          const v = clampByte(Math.pow(t, 0.8) * 225 + 30);
          out[i * 3] = v; out[i * 3 + 1] = v; out[i * 3 + 2] = v;
        }
      } else if (this.colorMode === 'class' && sample.classes) {
        for (let i = 0; i < n; i++) {
          const c = CLASS_COLORS[sample.classes[i]] || hashColor(sample.classes[i]);
          out[i * 3] = c[0]; out[i * 3 + 1] = c[1]; out[i * 3 + 2] = c[2];
        }
      } else {
        // Elevation is the file's z (up) axis.
        const heights = new Float32Array(n);
        for (let i = 0; i < n; i++) heights[i] = sample.positions[i * 3 + 2];
        const [low, high] = percentiles(heights, 0.01, 0.99);
        const span = Math.max(1e-9, high - low);
        const last = ELEVATION_RAMP.length - 1;
        for (let i = 0; i < n; i++) {
          const t = Math.min(1, Math.max(0, (heights[i] - low) / span)) * last;
          const k = Math.min(last - 1, Math.floor(t)), f = t - k;
          const a = ELEVATION_RAMP[k], b = ELEVATION_RAMP[k + 1];
          out[i * 3] = a[0] + (b[0] - a[0]) * f;
          out[i * 3 + 1] = a[1] + (b[1] - a[1]) * f;
          out[i * 3 + 2] = a[2] + (b[2] - a[2]) * f;
        }
      }
      this.colorAttribute.needsUpdate = true;
    }
  }

  // -------------------------------------------------------------------- Contact shadow

  /** A soft shadow under the model: its silhouette seen from below, blurred (after three.js's contact shadows). */
  class ContactShadow {
    constructor(renderer, scene, bounds) {
      const { THREE } = G;
      this.renderer = renderer;
      this.scene = scene;
      const size = bounds.getSize(new THREE.Vector3());
      const center = bounds.getCenter(new THREE.Vector3());
      const extent = Math.max(size.x, size.z) * 1.7 + size.y * 0.25;
      const resolution = 256;
      this.target = new THREE.WebGLRenderTarget(resolution, resolution);
      this.target.texture.generateMipmaps = false;
      this.blurTarget = new THREE.WebGLRenderTarget(resolution, resolution);
      this.blurTarget.texture.generateMipmaps = false;

      const geometry = new THREE.PlaneGeometry(extent, extent).rotateX(Math.PI / 2);
      this.material = new THREE.MeshBasicMaterial({ map: this.target.texture, transparent: true, depthWrite: false, opacity: 1 });
      this.plane = new THREE.Mesh(geometry, this.material);
      this.plane.renderOrder = -1;
      this.plane.scale.y = -1;
      this.plane.position.set(center.x, bounds.min.y + Math.max(size.y, 1e-6) * 0.0005, center.z);
      scene.add(this.plane);

      this.blurPlane = new THREE.Mesh(geometry);
      this.blurPlane.visible = false;
      this.blurPlane.position.copy(this.plane.position);
      scene.add(this.blurPlane);

      const height = Math.max(size.y * 0.5, extent * 0.06);
      // From just below the ground looking up, so faces resting on the ground count.
      const below = extent * 0.002;
      this.camera = new THREE.OrthographicCamera(-extent / 2, extent / 2, extent / 2, -extent / 2, 0, height + below);
      this.camera.rotation.x = Math.PI / 2;
      this.camera.position.set(center.x, bounds.min.y - below, center.z);
      this.camera.updateMatrixWorld(true);

      this.darkness = { value: 0.6 };
      this.depthMaterial = new THREE.MeshDepthMaterial({ side: THREE.DoubleSide });
      this.depthMaterial.depthTest = false;
      this.depthMaterial.depthWrite = false;
      this.depthMaterial.onBeforeCompile = (shader) => {
        shader.uniforms.darkness = this.darkness;
        shader.fragmentShader = 'uniform float darkness;\n' + shader.fragmentShader.replace(
          'gl_FragColor = vec4( vec3( 1.0 - fragCoordZ ), opacity );',
          'gl_FragColor = vec4( vec3( 0.0 ), ( 1.0 - fragCoordZ ) * darkness );');
      };
      this.horizontal = new THREE.ShaderMaterial(G.HorizontalBlurShader);
      this.horizontal.depthTest = false;
      this.vertical = new THREE.ShaderMaterial(G.VerticalBlurShader);
      this.vertical.depthTest = false;
      // Several narrow passes make a wide, smooth falloff without banding.
      this.passes = [2.6, 2.2, 1.7, 1.1];
      this.resolution = resolution;
    }

    setDarkness(value) {
      this.material.opacity = value;
    }

    blurPass(amount) {
      const { renderer, blurPlane } = this;
      blurPlane.visible = true;
      blurPlane.material = this.horizontal;
      this.horizontal.uniforms.tDiffuse.value = this.target.texture;
      this.horizontal.uniforms.h.value = amount / this.resolution;
      renderer.setRenderTarget(this.blurTarget);
      renderer.render(blurPlane, this.camera);
      blurPlane.material = this.vertical;
      this.vertical.uniforms.tDiffuse.value = this.blurTarget.texture;
      this.vertical.uniforms.v.value = amount / this.resolution;
      renderer.setRenderTarget(this.target);
      renderer.render(blurPlane, this.camera);
      blurPlane.visible = false;
    }

    update() {
      const { renderer, scene } = this;
      const background = scene.background;
      scene.background = null;
      this.plane.visible = false;
      const clearAlpha = renderer.getClearAlpha();
      renderer.setClearAlpha(0);
      scene.overrideMaterial = this.depthMaterial;
      const toneMapping = renderer.toneMapping;
      renderer.toneMapping = G.THREE.NoToneMapping;
      renderer.setRenderTarget(this.target);
      renderer.clear();
      this.darkness.value = 1.25;
      renderer.render(scene, this.camera);
      scene.overrideMaterial = null;
      for (const amount of this.passes) this.blurPass(amount);
      renderer.setRenderTarget(null);
      renderer.toneMapping = toneMapping;
      renderer.setClearAlpha(clearAlpha);
      scene.background = background;
      this.plane.visible = true;
    }
  }

  // -------------------------------------------------------------------- Helpers

  /** Phong, Lambert and the like become physically based so the studio light reads them consistently. */
  function toStandard(material, replacement) {
    const { THREE } = G;
    if (replacement && !material.map && !material.vertexColors) return replacement;
    if (!(material.isMeshPhongMaterial || material.isMeshLambertMaterial)) return material;
    const standard = new THREE.MeshStandardMaterial();
    for (const key of ['name', 'map', 'normalMap', 'normalScale', 'bumpMap', 'bumpScale', 'alphaMap', 'aoMap', 'aoMapIntensity',
      'emissiveMap', 'emissiveIntensity', 'transparent', 'opacity', 'side', 'vertexColors', 'alphaTest', 'flatShading',
      'depthWrite', 'displacementMap', 'displacementScale', 'displacementBias', 'lightMap', 'lightMapIntensity']) {
      if (material[key] !== undefined) standard[key] = material[key];
    }
    if (material.color) standard.color.copy(material.color);
    if (material.emissive) standard.emissive.copy(material.emissive);
    const shininess = material.isMeshPhongMaterial ? material.shininess : 4;
    standard.roughness = Math.min(0.95, Math.max(0.18, Math.sqrt(2 / (shininess + 2))));
    standard.metalness = 0;
    if (standard.transparent && standard.opacity < 1) standard.depthWrite = false;
    return standard;
  }

  function fbxUnits(factor) {
    // UnitScaleFactor is centimetres per unit.
    if (!factor) return 'cm';
    const known = { 1: 'cm', 100: 'm', 0.1: 'mm', 2.54: 'in', 30.48: 'ft', 100000: 'km' };
    for (const [value, unit] of Object.entries(known)) if (Math.abs(Number(value) - factor) / factor < 0.001) return unit;
    return null;
  }

  function textureBytes(texture) {
    if (texture.isCompressedTexture && texture.mipmaps) {
      return texture.mipmaps.reduce((sum, level) => sum + (level.data ? level.data.byteLength : 0), 0);
    }
    const image = texture.image || texture.source && texture.source.data;
    if (!image) return 0;
    const width = image.width || image.videoWidth || 0, height = image.height || image.videoHeight || 0;
    const bytes = width * height * 4;
    return texture.generateMipmaps !== false ? Math.round(bytes * 4 / 3) : bytes;
  }

  function formatBytes(bytes) {
    if (!bytes) return '0 KB';
    const units = ['bytes', 'KB', 'MB', 'GB'];
    let value = bytes, unit = 0;
    while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit++; }
    return `${value.toLocaleString('en-US', { maximumFractionDigits: value >= 100 || unit === 0 ? 0 : 1 })} ${units[unit]}`;
  }

  function describeError(error) {
    const message = String(error && error.message || error || '');
    if (/HTTP|404|Failed to fetch|Load failed/i.test(message)) return 'A file it needs couldn’t be read.';
    return message.length > 140 ? message.slice(0, 140) + '…' : message;
  }

  const clampByte = (v) => Math.max(0, Math.min(255, Math.round(v)));

  function hashColor(value) {
    const hue = (value * 137.508) % 360;
    const c = new G.THREE.Color().setHSL(hue / 360, 0.55, 0.55);
    return [c.r * 255, c.g * 255, c.b * 255];
  }

  function hasVariation(array) {
    const step = Math.max(1, Math.floor(array.length / 5000));
    const first = array[0];
    for (let i = 0; i < array.length; i += step) if (array[i] !== first) return true;
    return false;
  }

  function percentiles(values, low, high) {
    const step = Math.max(1, Math.floor(values.length / 100000));
    const sample = [];
    for (let i = 0; i < values.length; i += step) if (isFinite(values[i])) sample.push(values[i]);
    if (!sample.length) return [0, 1];
    sample.sort((a, b) => a - b);
    return [sample[Math.floor(low * (sample.length - 1))], sample[Math.floor(high * (sample.length - 1))]];
  }

  /** 0..<count in bit-reversed order: every prefix is spread evenly over the whole. */
  function progressiveOrder(count) {
    const order = new Uint32Array(count);
    if (count < 2) { if (count) order[0] = 0; return order; }
    let bits = 0;
    while ((1 << bits) < count) bits++;
    let n = 0;
    for (let value = 0; value < (1 << bits); value++) {
      let reversed = 0, v = value;
      for (let b = 0; b < bits; b++) { reversed = (reversed << 1) | (v & 1); v >>= 1; }
      if (reversed < count) order[n++] = reversed;
    }
    return order;
  }

  function permute(array, order, width) {
    const out = new array.constructor(array.length);
    for (let i = 0; i < order.length; i++) {
      const from = order[i] * width, to = i * width;
      for (let k = 0; k < width; k++) out[to + k] = array[from + k];
    }
    return out;
  }

  /** The sample GreeceKit serves for LAS files (see LASFile.Sample.encoded). */
  function decodeSample(buffer) {
    const view = new DataView(buffer);
    if (buffer.byteLength < 40 || view.getUint32(0, true) !== 0x31435047) throw new Error('Unreadable point sample');
    const count = view.getUint32(4, true), flags = view.getUint32(8, true);
    const center = [view.getFloat64(16, true), view.getFloat64(24, true), view.getFloat64(32, true)];
    let offset = 40;
    const take = (Type, length) => {
      const bytes = length * Type.BYTES_PER_ELEMENT;
      if (offset + bytes > buffer.byteLength) throw new Error('Truncated point sample');
      const array = new Type(buffer, offset, length);
      offset += (bytes + 3) & ~3;
      return array;
    };
    const positions = take(Float32Array, count * 3);
    const colors = flags & 1 ? take(Uint8Array, count * 3) : null;
    const intensity = flags & 2 ? take(Uint16Array, count) : null;
    const classes = flags & 4 ? take(Uint8Array, count) : null;
    return { count, center, positions, colors, intensity, classes };
  }

  /** Object File Format: a header, vertex lines, then one polygon per line with an optional colour. */
  function parseOFF(text) {
    const { THREE } = G;
    const lines = text.split(/\r?\n/).map((line) => line.replace(/#.*/, '').trim()).filter(Boolean);
    let header = lines.length ? lines[0].split(/\s+/) : [];
    const keyword = header.shift() || '';
    if (!/OFF$/.test(keyword)) throw new Error('Not an OFF file');
    const hasColor = /C/.test(keyword.replace(/OFF$/, '')), hasNormal = /N/.test(keyword.replace(/OFF$/, '')), hasUV = /ST/.test(keyword);
    let cursor = 1;
    let counts = header.map(Number).filter((n) => Number.isFinite(n));
    while (counts.length < 2 && cursor < lines.length) counts = counts.concat(lines[cursor++].split(/\s+/).map(Number));
    const nv = counts[0], nf = counts[1];
    if (!(nv >= 0 && nf >= 0) || nv > 20e6 || nf > 20e6) throw new Error('Invalid OFF header');
    // Vertices may wrap across lines: read them as a stream of numbers.
    const perVertex = 3 + (hasNormal ? 3 : 0) + (hasColor ? 4 : 0) + (hasUV ? 2 : 0);
    const vertices = new Float32Array(nv * 3);
    const vertexColors = hasColor ? new Float32Array(nv * 3) : null;
    let numbers = [];
    let v = 0;
    while (v < nv && cursor < lines.length) {
      numbers = numbers.concat(lines[cursor++].split(/\s+/).map(Number));
      while (numbers.length >= perVertex && v < nv) {
        const row = numbers.splice(0, perVertex);
        vertices.set(row.slice(0, 3), v * 3);
        if (vertexColors) {
          const rgb = row.slice(3 + (hasNormal ? 3 : 0), 6 + (hasNormal ? 3 : 0));
          const scale = rgb.some((c) => c > 1) ? 1 / 255 : 1;
          vertexColors.set(rgb.map((c) => c * scale), v * 3);
        }
        v++;
      }
    }
    const positions = [], colors = [];
    let anyColor = !!vertexColors;
    for (let f = 0; f < nf && cursor < lines.length; f++) {
      const words = lines[cursor++].split(/\s+/).map(Number);
      const n = words[0];
      if (!(n >= 3) || n > 1000 || words.length < n + 1) continue;
      const ids = words.slice(1, n + 1);
      if (!ids.every((id) => Number.isInteger(id) && id >= 0 && id < nv)) continue;
      const extra = words.slice(n + 1);
      let faceColor = null;
      if (extra.length >= 3 && extra.slice(0, 3).every(Number.isFinite)) {
        const scale = extra.slice(0, 3).some((c) => c > 1) ? 1 / 255 : 1;
        faceColor = extra.slice(0, 3).map((c) => c * scale);
        anyColor = true;
      }
      for (let k = 1; k + 1 < n; k++) {
        for (const id of [ids[0], ids[k], ids[k + 1]]) {
          positions.push(vertices[id * 3], vertices[id * 3 + 1], vertices[id * 3 + 2]);
          const c = faceColor || (vertexColors ? [vertexColors[id * 3], vertexColors[id * 3 + 1], vertexColors[id * 3 + 2]] : [0.8, 0.8, 0.8]);
          colors.push(c[0], c[1], c[2]);
        }
      }
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    if (anyColor) {
      const color = new THREE.Color();
      const linear = new Float32Array(colors.length);
      for (let i = 0; i < colors.length; i += 3) {
        color.setRGB(colors[i], colors[i + 1], colors[i + 2], THREE.SRGBColorSpace);
        linear[i] = color.r; linear[i + 1] = color.g; linear[i + 2] = color.b;
      }
      geometry.setAttribute('color', new THREE.BufferAttribute(linear, 3));
    }
    geometry.computeVertexNormals();
    return geometry;
  }

  /** Runs inside a worker, after laz-perf: decodes LAZ points, keeping an even sample. */
  function lazWorker() {
    onmessage = async (event) => {
      const { file, wasm, header, budget } = event.data;
      try {
        const module = await createLazPerf({ wasmBinary: wasm, locateFile: (name) => name });
        const filePointer = module._malloc(file.byteLength);
        module.HEAPU8.set(new Uint8Array(file), filePointer);
        const laszip = new module.LASZip();
        laszip.open(filePointer, file.byteLength);
        const total = laszip.getCount();
        const length = laszip.getPointLength();
        const format = laszip.getPointFormat() & 0x3f;
        const pointPointer = module._malloc(length);
        const stride = Math.max(1, Math.ceil(total / budget));
        const count = Math.ceil(total / stride);
        const positions = new Float32Array(count * 3);
        const rgbOffset = { 2: 20, 3: 28, 5: 28, 7: 30, 8: 30, 10: 30 }[format];
        const colors = rgbOffset !== undefined ? new Uint16Array(count * 3) : null;
        const intensity = new Uint16Array(count);
        const classes = new Uint8Array(count);
        const extended = format >= 6;
        const [sx, sy, sz] = header.scale, [ox, oy, oz] = header.offset;
        const cx = (header.minimum[0] + header.maximum[0]) / 2, cy = (header.minimum[1] + header.maximum[1]) / 2, cz = (header.minimum[2] + header.maximum[2]) / 2;
        const started = Date.now();
        let n = 0, maxColor = 0;
        for (let i = 0; i < total; i++) {
          laszip.getPoint(pointPointer);
          if (i % stride) continue;
          const view = new DataView(module.HEAPU8.buffer, pointPointer, length);
          positions[n * 3] = view.getInt32(0, true) * sx + ox - cx;
          positions[n * 3 + 1] = view.getInt32(4, true) * sy + oy - cy;
          positions[n * 3 + 2] = view.getInt32(8, true) * sz + oz - cz;
          intensity[n] = view.getUint16(12, true);
          classes[n] = extended ? view.getUint8(16) : view.getUint8(15) & 0x1f;
          if (colors) {
            for (let k = 0; k < 3; k++) {
              const value = view.getUint16(rgbOffset + k * 2, true);
              colors[n * 3 + k] = value;
              if (value > maxColor) maxColor = value;
            }
          }
          n++;
          if ((n & 0x3ffff) === 0) {
            postMessage({ progress: i / total });
            if (Date.now() - started > 25000) break;
          }
        }
        laszip.delete();
        // Bit-reversed order, as for LAS.
        let bits = 0;
        while ((1 << bits) < n) bits++;
        const order = new Uint32Array(n);
        let m = 0;
        for (let value = 0; value < (1 << bits); value++) {
          let reversed = 0, v = value;
          for (let b = 0; b < bits; b++) { reversed = (reversed << 1) | (v & 1); v >>= 1; }
          if (reversed < n) order[m++] = reversed;
        }
        const outPositions = new Float32Array(n * 3), outIntensity = new Uint16Array(n), outClasses = new Uint8Array(n);
        const outColors = colors ? new Uint8Array(n * 3) : null;
        const shift = maxColor > 255 ? 8 : 0;
        for (let i = 0; i < n; i++) {
          const s = order[i];
          outPositions[i * 3] = positions[s * 3]; outPositions[i * 3 + 1] = positions[s * 3 + 1]; outPositions[i * 3 + 2] = positions[s * 3 + 2];
          outIntensity[i] = intensity[s];
          outClasses[i] = classes[s];
          if (outColors) for (let k = 0; k < 3; k++) outColors[i * 3 + k] = colors[s * 3 + k] >> shift;
        }
        postMessage({ count: n, total, center: [cx, cy, cz], positions: outPositions, colors: outColors, intensity: outIntensity, classes: outClasses },
          [outPositions.buffer, outIntensity.buffer, outClasses.buffer].concat(outColors ? [outColors.buffer] : []));
      } catch (error) {
        postMessage({ error: String(error && error.message || error) });
      }
    };
  }
})();

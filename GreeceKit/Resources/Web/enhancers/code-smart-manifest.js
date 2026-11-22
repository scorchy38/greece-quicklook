/* Greece — project manifests: one card for package.json, Cargo.toml, pyproject.toml, go.mod,
   Gemfile, Podfile, Package.swift, composer.json, pubspec.yaml, mix.exs and build.gradle(.kts).
   Name, version, description, licence, engines and platforms, scripts, and dependencies with
   their kind (dev, peer, build…). Formats without a data syntax (Ruby, Swift, Elixir, Gradle)
   are read with patterns, never executed. */
(function (global) {
  'use strict';
  const Smart = global.GreeceSmart = global.GreeceSmart || {};
  /** The page's strings (Smart.kit), looked up when used: code-smart.js, which sets it, may load after this file. */
  const kit = new Proxy({}, { get: (_, name) => Smart.kit[name] });
  const MAX = 2 * 1024 * 1024;

  const str = (v, max = 200) => Smart.text(v, max);
  const entries = (v) => Smart.entries(v, 3000);
  const json = (text) => { try { const v = JSON.parse(text.slice(0, MAX)); return Smart.isObject(v) ? v : null; } catch (_) { return null; } };
  const licence = (v) => (typeof v === 'string' ? v : Array.isArray(v) ? kit.list(v.map((x) => str(x.type || x, 40)), { type: 'disjunction' }) : Smart.isObject(v) ? str(v.type || v.text || (v.file ? kit.t('See {0}', v.file) : ''), 80) : '');
  const repoURL = (v) => (typeof v === 'string' ? v : Smart.isObject(v) ? str(v.url, 300) : '');

  /** A dependency's version requirement in a few characters. */
  function requirement(v) {
    if (typeof v === 'string') return str(v, 60);
    if (typeof v === 'number') return String(v);
    if (!Smart.isObject(v)) return '';
    if (v.workspace === true) return 'workspace';
    if (v.version) return str(v.version, 60);
    if (v.git || v.github) return 'git';
    if (v.path) return 'path';
    if (v.sdk) return str(v.sdk, 30) + ' SDK';
    if (v.hosted) return 'hosted';
    if (v.url) return 'url';
    return '';
  }

  function depsOf(object, type) {
    return entries(object).map(([name, v]) => ({ name, version: requirement(v), type: !type && Smart.isObject(v) && v.optional === true ? 'optional' : type }));
  }

  // ------------------------------------------------------------------------- Parsers

  const parsers = {
    'package.json'(text) {
      const j = json(text);
      if (!j) return null;
      const facts = [
        { label: kit.t('License'), value: licence(j.license || j.licenses) },
        ...entries(j.engines).map(([k, v]) => ({ label: k === 'node' ? 'Node' : k, value: str(v, 40), mono: true })),
        { label: kit.t('Module'), value: j.type === 'module' ? kit.t('ES modules') : j.type === 'commonjs' ? 'CommonJS' : '' },
        { label: kit.t('Package Manager'), value: str(j.packageManager, 60), mono: true },
        { label: kit.t('Workspaces'), value: Array.isArray(j.workspaces) ? kit.number(j.workspaces.length) : Smart.isObject(j.workspaces) && Array.isArray(j.workspaces.packages) ? kit.number(j.workspaces.packages.length) : '' },
        { label: kit.t('Visibility'), value: j.private === true ? kit.t('Private') : '' },
        { label: kit.t('Home'), value: Smart.link(j.homepage || repoURL(j.repository)), html: true },
      ];
      return {
        label: kit.t('npm package'), title: str(j.name, 120) || 'package.json', version: str(j.version, 40), subtitle: str(j.description, 300), facts,
        scripts: entries(j.scripts).map(([name, command]) => ({ name, command: str(command, 400) })),
        deps: [...depsOf(j.dependencies, ''), ...depsOf(j.devDependencies, 'dev'), ...depsOf(j.peerDependencies, 'peer'), ...depsOf(j.optionalDependencies, 'optional')],
      };
    },

    'composer.json'(text) {
      const j = json(text);
      if (!j) return null;
      const require = entries(j.require);
      const engines = require.filter(([k]) => k === 'php' || /^ext-/.test(k));
      return {
        label: kit.t('Composer package'), title: str(j.name, 120) || 'composer.json', version: str(j.version, 40), subtitle: str(j.description, 300),
        facts: [
          { label: kit.t('License'), value: licence(j.license) },
          ...engines.slice(0, 6).map(([k, v]) => ({ label: k === 'php' ? 'PHP' : k, value: str(v, 40), mono: true })),
          { label: kit.t('Type'), value: str(j.type, 40) },
          { label: kit.t('Home'), value: Smart.link(j.homepage), html: true },
        ],
        scripts: entries(j.scripts).map(([name, command]) => ({ name, command: Array.isArray(command) ? command.map((c) => str(c, 120)).join(' && ') : str(command, 400) })),
        deps: [...require.filter(([k]) => k !== 'php' && !/^ext-/.test(k)).map(([name, v]) => ({ name, version: requirement(v), type: '' })), ...depsOf(j['require-dev'], 'dev')],
      };
    },

    'cargo.toml'(text) {
      const { data } = Smart.toml(text, MAX);
      const p = Smart.isObject(data.package) ? data.package : {};
      const workspace = Smart.isObject(data.workspace) ? data.workspace : null;
      const version = Smart.isObject(p.version) && p.version.workspace ? 'workspace' : str(p.version, 40);
      const deps = [...depsOf(data.dependencies, ''), ...depsOf(data['dev-dependencies'], 'dev'), ...depsOf(data['build-dependencies'], 'build')];
      entries(data.target).forEach(([target, t]) => {
        if (!Smart.isObject(t)) return;
        deps.push(...depsOf(t.dependencies, 'platform').map((d) => ({ ...d, note: target })), ...depsOf(t['dev-dependencies'], 'dev'));
      });
      if (workspace) deps.push(...depsOf(workspace.dependencies, 'workspace'));
      const features = entries(data.features).length;
      return {
        label: workspace && !p.name ? kit.t('Cargo workspace') : kit.t('Rust crate'), title: str(p.name, 120) || (workspace ? kit.t('Workspace') : 'Cargo.toml'), version, subtitle: str(p.description, 300),
        facts: [
          { label: kit.t('License'), value: str(p.license || (p['license-file'] ? kit.t('See {0}', p['license-file']) : ''), 80) },
          { label: kit.t('Edition'), value: str(Smart.isObject(p.edition) ? '' : p.edition, 10) },
          { label: 'Rust', value: str(p['rust-version'], 20), mono: true },
          { label: kit.t('Members'), value: workspace && Array.isArray(workspace.members) ? kit.number(workspace.members.length) : '' },
          { label: kit.t('Features'), value: features ? kit.number(features) : '' },
          { label: kit.t('Home'), value: Smart.link(p.homepage || p.repository), html: true },
        ],
        scripts: [],
        deps,
      };
    },

    'pyproject.toml'(text) {
      const { data } = Smart.toml(text, MAX);
      const p = Smart.isObject(data.project) ? data.project : {};
      const tool = Smart.isObject(data.tool) ? data.tool : {};
      const poetry = Smart.isObject(tool.poetry) ? tool.poetry : {};
      const pep508 = (spec, type, note) => {
        const s = str(spec, 200);
        const m = /^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*(.*)$/.exec(s);
        if (!m) return null;
        const [requirementText] = m[3].split(';');
        return { name: m[1], version: requirementText.trim().replace(/^\((.*)\)$/, '$1'), type, note: note || (m[2] ? m[2].slice(1, -1) : '') };
      };
      const deps = [];
      (Array.isArray(p.dependencies) ? p.dependencies : []).slice(0, 2000).forEach((d) => { const x = pep508(d, ''); if (x) deps.push(x); });
      entries(p['optional-dependencies']).forEach(([group, list]) => (Array.isArray(list) ? list : []).slice(0, 500).forEach((d) => { const x = pep508(d, 'optional', group); if (x) deps.push(x); }));
      entries(data['dependency-groups']).forEach(([group, list]) => (Array.isArray(list) ? list : []).slice(0, 500).forEach((d) => { if (typeof d === 'string') { const x = pep508(d, group === 'dev' ? 'dev' : 'group', group === 'dev' ? '' : group); if (x) deps.push(x); } }));
      let python = str(p['requires-python'], 40);
      entries(poetry.dependencies).forEach(([name, v]) => { if (name.toLowerCase() === 'python') python = python || requirement(v); else deps.push({ name, version: requirement(v), type: '' }); });
      deps.push(...depsOf(poetry['dev-dependencies'], 'dev'));
      entries(poetry.group).forEach(([group, g]) => { if (Smart.isObject(g)) deps.push(...depsOf(g.dependencies, group === 'dev' || group === 'test' ? 'dev' : 'group').map((d) => ({ ...d, note: group === 'dev' ? '' : group }))); });
      const backend = Smart.isObject(data['build-system']) ? str(data['build-system']['build-backend'], 60) : '';
      const urls = Smart.isObject(p.urls) ? Object.values(p.urls).find((u) => typeof u === 'string') : '';
      return {
        label: poetry.name && !p.name ? kit.t('Poetry project') : kit.t('Python project'), title: str(p.name || poetry.name, 120) || 'pyproject.toml', version: str(p.version || poetry.version, 40) || (Array.isArray(p.dynamic) && p.dynamic.includes('version') ? 'dynamic' : ''),
        subtitle: str(p.description || poetry.description, 300),
        facts: [
          { label: kit.t('License'), value: licence(p.license || poetry.license) },
          { label: 'Python', value: python, mono: true },
          { label: kit.t('Build'), value: backend, mono: true },
          { label: kit.t('Home'), value: Smart.link(urls || poetry.homepage || poetry.repository), html: true },
        ],
        scripts: [...entries(p.scripts), ...entries(poetry.scripts)].map(([name, command]) => ({ name, command: str(command, 300) })),
        deps,
      };
    },

    'go.mod'(text) {
      const src = text.slice(0, MAX);
      const module = (/^module\s+(\S+)/m.exec(src) || [])[1] || '';
      const go = (/^go\s+(\S+)/m.exec(src) || [])[1] || '';
      const toolchain = (/^toolchain\s+(\S+)/m.exec(src) || [])[1] || '';
      const deps = [];
      const add = (line) => {
        const m = /^\s*(\S+)\s+(v\S+)(\s*\/\/\s*indirect)?/.exec(line);
        if (m && deps.length < 5000) deps.push({ name: m[1], version: m[2], type: m[3] ? 'indirect' : '' });
      };
      const block = /^require\s*\(([\s\S]*?)^\)/gm;
      let m;
      while ((m = block.exec(src))) m[1].split('\n').forEach(add);
      src.split('\n').forEach((line) => { if (/^require\s+[^(\s]/.test(line)) add(line.replace(/^require\s+/, '')); });
      const replaces = (src.match(/^replace\s|^\s+\S+\s+=>\s/gm) || []).length;
      return {
        label: kit.t('Go module'), title: module.split('/').pop() || 'go.mod', subtitle: module, version: '',
        facts: [
          { label: 'Go', value: go, mono: true },
          { label: kit.t('Toolchain'), value: toolchain, mono: true },
          { label: kit.t('Replaced'), value: replaces ? kit.number(replaces) : '' },
        ],
        scripts: [], deps,
      };
    },

    gemfile(text) {
      const src = text.slice(0, MAX);
      const deps = [];
      const groups = [];
      let ruby = '';
      src.split('\n').slice(0, 20000).forEach((raw) => {
        const line = raw.replace(/#.*$/, '').trim();
        if (!line) return;
        const group = /^group\s+(.+?)\s+do\b/.exec(line);
        if (group) { groups.push(group[1].match(/:\w+|["']\w+["']/g) || []); return; }
        if (/^end\b/.test(line)) { groups.pop(); return; }
        const r = /^ruby\s+["']([^"']+)["']/.exec(line);
        if (r) { ruby = r[1]; return; }
        const gem = /^gem\s+["']([^"']+)["']\s*(.*)$/.exec(line);
        if (!gem) return;
        const versions = (gem[2].match(/["'][~><=!\d][^"']*["']/g) || []).map((v) => v.slice(1, -1));
        const inline = /group[s]?:\s*\[?([^\]\n]+)\]?/.exec(gem[2]);
        const names = (groups.flat().concat(inline ? inline[1].match(/:\w+|["']\w+["']/g) || [] : [])).map((g) => g.replace(/[:"']/g, ''));
        const dev = names.length && names.every((g) => /^(development|test|dev)$/.test(g));
        deps.push({ name: gem[1], version: versions.join(', '), type: dev ? 'dev' : names.length && !names.includes('default') ? 'group' : '', note: names.length && !dev ? names.join(', ') : '' });
      });
      const source = (/^source\s+["']([^"']+)["']/m.exec(src) || [])[1] || '';
      return {
        label: 'Bundler', title: 'Gemfile', subtitle: '', version: '',
        facts: [
          { label: 'Ruby', value: ruby, mono: true },
          { label: kit.t('Source'), value: Smart.link(source), html: true },
          { label: 'Gemspec', value: /^gemspec\b/m.test(src) ? kit.t('Yes') : '' },
        ],
        scripts: [], deps,
      };
    },

    podfile(text) {
      const src = text.slice(0, MAX);
      const deps = [];
      const targets = [];
      const platforms = [];
      src.split('\n').slice(0, 20000).forEach((raw) => {
        const line = raw.replace(/#.*$/, '').trim();
        const target = /^(?:abstract_)?target\s+["']([^"']+)["']\s+do/.exec(line);
        if (target) { targets.push(target[1]); return; }
        if (/^end\b/.test(line)) { targets.pop(); return; }
        const platform = /^platform\s+:(\w+)(?:\s*,\s*["']([^"']+)["'])?/.exec(line);
        if (platform) { platforms.push(`${({ ios: 'iOS', osx: 'macOS', macos: 'macOS', tvos: 'tvOS', watchos: 'watchOS', visionos: 'visionOS' })[platform[1]] || platform[1]}${platform[2] ? ' ' + platform[2] : ''}`); return; }
        const pod = /^pod\s+["']([^"']+)["']\s*(.*)$/.exec(line);
        if (!pod) return;
        const version = (pod[2].match(/["'][~><=!\d][^"']*["']/) || [''])[0].replace(/["']/g, '');
        const source = /:git\b|git:/.test(pod[2]) ? 'git' : /:path\b|path:/.test(pod[2]) ? 'path' : '';
        const owner = targets[targets.length - 1] || "";
        deps.push({ name: pod[1], version: version || source, type: /tests?$/i.test(owner) ? "test" : "", note: owner });
      });
      return {
        label: 'CocoaPods', title: 'Podfile', subtitle: targets.length ? '' : '', version: '',
        facts: [
          { label: kit.t('Platform'), value: platforms.join(', ') },
          { label: kit.t('Frameworks'), value: /^use_frameworks!/m.test(src) ? kit.t('Yes') : '' },
          { label: kit.t('Targets'), value: kit.number((src.match(/^\s*target\s+["']/gm) || []).length) || '' },
        ],
        scripts: [], deps,
      };
    },

    'package.swift'(text) {
      const src = text.slice(0, MAX);
      const tools = (/swift-tools-version\s*:\s*([\d.]+)/.exec(src) || [])[1] || '';
      const body = src.slice(Math.max(0, src.search(/Package\s*\(/)));
      const name = (/name\s*:\s*"([^"]+)"/.exec(body) || [])[1] || '';
      const platformBlock = (/platforms\s*:\s*\[([\s\S]*?)\]/.exec(body) || [])[1] || '';
      const PLATFORM = { macOS: 'macOS', iOS: 'iOS', tvOS: 'tvOS', watchOS: 'watchOS', visionOS: 'visionOS', macCatalyst: 'Mac Catalyst', driverKit: 'DriverKit' };
      const platforms = [];
      const pre = /\.(\w+)\(\s*(?:\.v([\d_]+)|"([^"]+)")/g;
      let m;
      while ((m = pre.exec(platformBlock))) platforms.push(`${PLATFORM[m[1]] || m[1]} ${(m[2] || m[3] || '').replace(/_/g, '.')}`);
      const deps = [];
      const dep = /\.package\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)/g;
      while ((m = dep.exec(body)) && deps.length < 500) {
        const args = m[1];
        const url = (/url\s*:\s*"([^"]+)"/.exec(args) || [])[1];
        const path = (/path\s*:\s*"([^"]+)"/.exec(args) || [])[1];
        const id = (/id\s*:\s*"([^"]+)"/.exec(args) || [])[1];
        const label = (/name\s*:\s*"([^"]+)"/.exec(args) || [])[1] || (url || path || id || '').replace(/\.git$/, '').split('/').pop();
        let version = '';
        let v;
        if ((v = /from\s*:\s*"([^"]+)"/.exec(args))) version = `from ${v[1]}`;
        else if ((v = /exact\s*:\s*"([^"]+)"/.exec(args))) version = v[1];
        else if ((v = /branch\s*:\s*"([^"]+)"/.exec(args))) version = `branch ${v[1]}`;
        else if ((v = /revision\s*:\s*"([^"]+)"/.exec(args))) version = `revision ${v[1].slice(0, 9)}`;
        else if ((v = /"([^"]+)"\s*(\.\.[.<])\s*"([^"]+)"/.exec(args))) version = `${v[1]} ${v[2] === '..<' ? '..<' : '...'} ${v[3]}`;
        else if (path) version = 'local';
        if (label) deps.push({ name: label, version, type: '', note: url ? url.replace(/^https?:\/\//, '') : '' });
      }
      const products = [];
      const product = /\.(library|executable|plugin)\s*\(\s*name\s*:\s*"([^"]+)"/g;
      while ((m = product.exec(body)) && products.length < 100) products.push({ name: m[2], command: m[1] === 'library' ? kit.t('Library') : m[1] === 'executable' ? kit.t('Executable') : kit.t('Plugin') });
      const targets = (body.match(/\.(?:target|executableTarget|testTarget|macro|plugin|binaryTarget|systemLibrary)\s*\(\s*name\s*:/g) || []).length;
      return {
        label: kit.t('Swift package'), title: name || 'Package.swift', version: '', subtitle: '',
        facts: [
          { label: kit.t('Swift Tools'), value: tools, mono: true },
          { label: kit.t('Platforms'), value: platforms.join(', ') },
          { label: kit.t('Targets'), value: targets ? kit.number(targets) : '' },
        ],
        scripts: products, scriptsTitle: kit.t('Products'), deps,
      };
    },

    'pubspec.yaml'(text) {
      const y = Smart.yaml(text);
      if (!Smart.isObject(y)) return null;
      const env = Smart.isObject(y.environment) ? y.environment : {};
      return {
        label: Smart.isObject(y.dependencies) && Smart.isObject(y.dependencies.flutter) ? kit.t('Flutter package') : kit.t('Dart package'),
        title: str(y.name, 120) || 'pubspec.yaml', version: str(y.version, 40), subtitle: str(y.description, 300),
        facts: [
          { label: 'Dart', value: str(env.sdk, 40), mono: true },
          { label: 'Flutter', value: str(env.flutter, 40), mono: true },
          { label: kit.t('Publish'), value: y.publish_to === 'none' ? kit.t('Private') : '' },
          { label: kit.t('Home'), value: Smart.link(y.homepage || y.repository), html: true },
        ],
        scripts: entries(y.executables).map(([name, v]) => ({ name, command: str(v || name, 100) })), scriptsTitle: kit.t('Executables'),
        deps: [...depsOf(y.dependencies, ''), ...depsOf(y.dev_dependencies, 'dev'), ...depsOf(y.dependency_overrides, 'override')],
      };
    },

    'mix.exs'(text) {
      const src = text.slice(0, MAX);
      const app = (/\bapp:\s*:(\w+)/.exec(src) || [])[1] || '';
      const version = (/\bversion:\s*"([^"]+)"/.exec(src) || [])[1] || (/@version\s+"([^"]+)"/.exec(src) || [])[1] || '';
      const elixir = (/\belixir:\s*"([^"]+)"/.exec(src) || [])[1] || '';
      const description = (/\bdescription:\s*"([^"]+)"/.exec(src) || [])[1] || '';
      const licenses = ((/licenses:\s*\[([^\]]*)\]/.exec(src) || [])[1] || '').match(/"[^"]+"/g) || [];
      const block = (src.match(/defp?\s+deps\b[\s\S]*?\bend\b/) || [''])[0];
      const deps = [];
      const dep = /\{\s*:(\w+)\s*(?:,\s*"([^"]*)")?([^{}]*)\}/g;
      let m;
      while ((m = dep.exec(block)) && deps.length < 1000) {
        const only = (/only:\s*(\[[^\]]*\]|:\w+)/.exec(m[3]) || [])[1] || '';
        const envs = only.match(/:\w+/g) || [];
        const dev = envs.length && !envs.includes(':prod');
        const source = /github:|git:/.test(m[3]) ? 'git' : /path:/.test(m[3]) ? 'path' : '';
        deps.push({ name: m[1], version: m[2] || source, type: dev ? 'dev' : '', note: dev ? envs.map((e) => e.slice(1)).filter((e) => e !== 'dev').join(', ') : '' });
      }
      const aliases = (src.match(/defp?\s+aliases\b[\s\S]*?\bend\b/) || [''])[0];
      const scripts = [];
      const alias = /(?:^|\s|\[|,)"?([\w.]+)"?:\s*(\[[^\]]*\]|"[^"]*"|&[\w.]+\/\d)/g;
      while ((m = alias.exec(aliases)) && scripts.length < 100) {
        scripts.push({ name: m[1], command: m[2].startsWith('[') ? (m[2].match(/"[^"]*"/g) || []).map((s) => s.slice(1, -1)).join(', ') : m[2].replace(/^"|"$/g, '') });
      }
      return {
        label: kit.t('Elixir project'), title: app || 'mix.exs', version, subtitle: description,
        facts: [{ label: kit.t('License'), value: licenses.map((l) => l.slice(1, -1)).join(', ') }, { label: 'Elixir', value: elixir, mono: true }],
        scripts, scriptsTitle: kit.t('Aliases'), deps,
      };
    },

    'build.gradle'(text) {
      const src = text.slice(0, MAX);
      const value = (key) => (new RegExp(`\\b${key}\\s*(?:=\\s*)?\\(?\\s*["']([^"']+)["']`).exec(src) || [])[1] || '';
      const number = (key) => (new RegExp(`\\b${key}(?:Version)?\\s*(?:=\\s*)?\\(?\\s*(\\d+)`).exec(src) || [])[1] || '';
      const java = (/JavaVersion\.VERSION_(\d+(?:_\d+)?)/.exec(src) || [])[1] || (/jvmToolchain\s*\(\s*(\d+)/.exec(src) || [])[1] ||
        (/JavaLanguageVersion\.of\s*\(\s*(\d+)/.exec(src) || [])[1] || (/sourceCompatibility\s*=\s*['"]?([\d.]+)/.exec(src) || [])[1] || '';
      const CONFIG = {
        implementation: '', api: '', compile: '', compileOnly: 'compile only', runtimeOnly: 'runtime', classpath: 'build',
        testImplementation: 'test', testRuntimeOnly: 'test', testCompileOnly: 'test', androidTestImplementation: 'test', testFixturesImplementation: 'test',
        debugImplementation: 'debug', releaseImplementation: '', kapt: 'build', ksp: 'build', annotationProcessor: 'build', coreLibraryDesugaring: 'build',
      };
      const deps = [];
      const line = /^\s*(\w+)\s*\(?\s*(?:platform\s*\(\s*)?(["'])([^"']+)\2/gm;
      let m;
      while ((m = line.exec(src)) && deps.length < 2000) {
        if (!(m[1] in CONFIG)) continue;
        const parts = m[3].split(':');
        deps.push({ name: parts.length >= 2 ? `${parts[0]}:${parts[1]}` : m[3], version: parts[2] || '', type: CONFIG[m[1]] });
      }
      const catalog = /^\s*(\w+)\s*\(\s*(libs\.[\w.]+|project\s*\(\s*["'][^"']+["']\s*\))/gm;
      while ((m = catalog.exec(src)) && deps.length < 2000) {
        if (!(m[1] in CONFIG)) continue;
        const project = /project\s*\(\s*["']([^"']+)/.exec(m[2]);
        deps.push({ name: project ? project[1] : m[2], version: project ? 'project' : 'catalog', type: CONFIG[m[1]] });
      }
      const plugins = [];
      const plugin = /\bid\s*\(?\s*["']([^"']+)["']\s*\)?(?:\s*version\s*\(?\s*["']([^"']+)["'])?|\bkotlin\s*\(\s*["']([^"']+)["']\s*\)(?:\s*version\s*["']([^"']+)["'])?|\balias\s*\(\s*(libs\.plugins\.[\w.]+)\s*\)/g;
      const pluginBlock = (/plugins\s*\{([\s\S]*?)\n\}/.exec(src) || [])[1] || '';
      while ((m = plugin.exec(pluginBlock)) && plugins.length < 50) plugins.push({ name: m[1] || (m[3] ? `kotlin(${m[3]})` : m[5]), command: m[2] || m[4] || '' });
      const app = value('applicationId') || value('namespace');
      const minSdk = number('minSdk');
      const targetSdk = number('targetSdk');
      return {
        label: /com\.android\.(application|library)|android\s*\{/.test(src) ? kit.t('Android build') : kit.t('Gradle build'),
        title: app || value('group') || kit.t('Gradle build'), version: value('versionName') || value('version'), subtitle: value('description'),
        facts: [
          { label: 'Java', value: java.replace('_', '.'), mono: true },
          { label: 'Android', value: minSdk ? `API ${minSdk}${targetSdk ? ` – ${targetSdk}` : '+'}` : '' },
          { label: kit.t('Compile SDK'), value: number('compileSdk'), mono: true },
          { label: 'Kotlin', value: /kotlin\s*\(|org\.jetbrains\.kotlin|\.kts$/.test(src) ? kit.t('Yes') : '' },
        ],
        scripts: plugins, scriptsTitle: kit.t('Plugins'),
        deps,
      };
    },
  };

  /** Which parser reads this file name. */
  function parserFor(lower) {
    if (lower === 'package.json' || lower === 'composer.json' || lower === 'cargo.toml' || lower === 'pyproject.toml' ||
        lower === 'go.mod' || lower === 'gemfile' || lower === 'podfile' || lower === 'pubspec.yaml' || lower === 'mix.exs') return lower;
    if (lower === 'package.swift' || /^package@swift-[\d.]+\.swift$/.test(lower)) return 'package.swift';
    if (lower === 'build.gradle' || lower === 'build.gradle.kts') return 'build.gradle';
    return null;
  }

  function parse(fileName, text) {
    const key = parserFor(String(fileName).toLowerCase());
    if (!key) return null;
    try { return parsers[key](String(text)); } catch (_) { return null; }
  }

  // ------------------------------------------------------------------------------ Card

  /** What each kind of dependency is called on its tag, and in the summary of counts. */
  const TYPES = {
    dev: () => kit.t('dev'), test: () => kit.t('test'), peer: () => kit.t('peer'), optional: () => kit.t('optional'),
    build: () => kit.t('build'), indirect: () => kit.t('indirect'), platform: () => kit.t('platform'), override: () => kit.t('override'),
    group: () => kit.t('group'), workspace: () => kit.t('workspace'), debug: () => kit.t('debug'), 'compile only': () => kit.t('compile only'),
    runtime: () => kit.t('runtime'),
  };
  const COUNTS = {
    '': (n) => kit.plural(n, '{0} direct'), dev: (n) => kit.plural(n, '{0} dev'), test: (n) => kit.plural(n, '{0} test'),
    peer: (n) => kit.plural(n, '{0} peer'), optional: (n) => kit.plural(n, '{0} optional'), build: (n) => kit.plural(n, '{0} build'),
    indirect: (n) => kit.plural(n, '{0} indirect'), platform: (n) => kit.plural(n, '{0} platform'), override: (n) => kit.plural(n, '{0} override'),
    group: (n) => kit.plural(n, '{0} group'), workspace: (n) => kit.plural(n, '{0} workspace'), debug: (n) => kit.plural(n, '{0} debug'),
    'compile only': (n) => kit.plural(n, '{0} compile only'), runtime: (n) => kit.plural(n, '{0} runtime'),
  };
  const typeName = (type) => (TYPES[type] ? TYPES[type]() : type);
  const TONES = { dev: 'gray', test: 'gray', peer: 'purple', optional: 'teal', build: 'orange', indirect: 'gray', platform: 'teal', override: 'orange', group: 'teal', workspace: 'teal', debug: 'gray', 'compile only': 'orange', runtime: 'teal' };

  function render({ root, Smart }, model) {
    const esc = Smart.esc;
    const parts = [];
    parts.push(Smart.facts(model.facts));

    const sections = [];
    if (model.scripts && model.scripts.length) {
      const rows = model.scripts.map((s) => `<li><code class="smart-name" title="${esc(s.name)}">${esc(s.name)}</code><span class="smart-command" title="${esc(s.command || '')}">${esc(s.command || '')}</span><span></span></li>`);
      sections.push(Smart.section(model.scriptsTitle || kit.t('Scripts'), `<ul class="smart-list scripts">${Smart.more(rows, 8)}</ul>`, { count: model.scripts.length }));
    }
    if (model.deps && model.deps.length) {
      const byType = new Map();
      model.deps.forEach((d) => byType.set(d.type || '', (byType.get(d.type || '') || 0) + 1));
      const summary = Array.from(byType.entries()).sort((a, b) => (a[0] === '' ? -1 : b[0] === '' ? 1 : b[1] - a[1]))
        .map(([type, count]) => (COUNTS[type] ? COUNTS[type](count) : `${kit.number(count)} ${type}`)).join(' · ');
      const rows = model.deps.map((d) => `<tr><td class="dep-name" title="${esc(d.name)}">${esc(d.name)}</td><td class="dep-version" title="${esc(d.version)}">${esc(d.version || '')}</td><td class="dep-kind">${d.type ? Smart.tag(typeName(d.type), TONES[d.type] || 'gray') : ''}${d.note ? `<span class="smart-dim" title="${esc(d.note)}">${esc(d.note)}</span>` : ''}</td></tr>`);
      const limit = 10;
      const table = `<table class="smart-table deps"><tbody>${rows.slice(0, limit).join('')}</tbody>${rows.length > limit ? `<tbody class="smart-rest" hidden>${rows.slice(limit).join('')}</tbody>` : ''}</table>` +
        (rows.length > limit ? `<button type="button" class="smart-more table" data-more="${rows.length - limit}">${esc(Smart.moreLabel(rows.length - limit))}</button>` : '');
      sections.push(Smart.section(kit.t('Dependencies'), table, { count: model.deps.length, aside: esc(summary) }));
    }
    if (sections.length) parts.push(`<div class="smart-grid">${sections.join('')}</div>`);

    const card = Smart.card(root, {
      kind: 'manifest',
      icon: 'package',
      title: model.title,
      version: model.version,
      label: model.label,
      subtitle: model.subtitle,
      body: parts.join(''),
    });
    // Tables keep their "more" rows in a sibling tbody.
    card.querySelectorAll('.smart-more.table').forEach((button) => {
      button.addEventListener('click', (event) => {
        event.stopPropagation();
        const rest = button.previousElementSibling.querySelector('.smart-rest');
        rest.hidden = !rest.hidden;
        button.textContent = Smart.moreLabel(Number(button.dataset.more), !rest.hidden);
      });
    });
  }

  (Smart.kinds = Smart.kinds || []).push({
    id: 'manifest',
    order: 10,
    yaml: (file) => file.lower === 'pubspec.yaml',
    detect: (file) => !!parserFor(file.lower),
    parse,
    enhance(context) {
      const model = parse(context.file.name, context.file.text);
      if (model) render(context, model);
    },
  });
})(typeof window !== 'undefined' ? window : globalThis);

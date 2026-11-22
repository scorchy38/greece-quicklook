/* Greece — containers and CI: Dockerfile stages, Compose services (with their depends_on
   graph), GitHub Actions workflows (triggers, then jobs and steps, with `needs` as a graph) and
   Kubernetes manifests (one row per resource). */
(function (global) {
  'use strict';
  const Smart = global.GreeceSmart = global.GreeceSmart || {};
  /** The page's strings (Smart.kit), looked up when used: code-smart.js, which sets it, may load after this file. */
  const kit = new Proxy({}, { get: (_, name) => Smart.kit[name] });
  const str = (v, max) => Smart.text(v, max || 200);
  const entries = (v, limit) => Smart.entries(v, limit || 500);
  const arr = (v) => (Array.isArray(v) ? v : v == null ? [] : [v]);

  // ========================================================================= Dockerfile

  function parseDockerfile(text) {
    const raw = String(text).replace(/\r\n?/g, '\n').split('\n').slice(0, 20000);
    const escapeChar = /^#\s*escape\s*=\s*`/im.test(raw.slice(0, 5).join('\n')) ? '`' : '\\';
    const instructions = [];
    for (let i = 0; i < raw.length; i++) {
      let line = raw[i];
      if (/^\s*#/.test(line) || !line.trim()) continue;
      const start = i + 1;
      while (line.trimEnd().endsWith(escapeChar) && i + 1 < raw.length) {
        line = line.trimEnd().slice(0, -1) + ' ';
        i++;
        while (i < raw.length && /^\s*#/.test(raw[i])) i++;  // comments inside continuations
        if (i < raw.length) line += raw[i].trim();
      }
      const m = /^\s*([A-Za-z]+)\s*(.*)$/.exec(line);
      if (m) instructions.push({ op: m[1].toUpperCase(), args: m[2].trim(), line: start });
    }
    const stages = [];
    const args = new Map();
    let stage = null;
    const execForm = (s) => {
      if (!/^\[/.test(s)) return s;
      try { const list = JSON.parse(s); if (Array.isArray(list)) return list.map((x) => (/\s/.test(String(x)) ? JSON.stringify(String(x)) : String(x))).join(' '); } catch (_) { }
      return s;
    };
    for (const ins of instructions) {
      if (ins.op === 'ARG' && !stage) { const [k, v] = ins.args.split('='); args.set(k.trim(), (v || '').trim()); continue; }
      if (ins.op === 'FROM') {
        const m = /^(?:--platform=(\S+)\s+)?(\S+)(?:\s+as\s+(\S+))?/i.exec(ins.args);
        if (!m) continue;
        const image = m[2].replace(/\$\{?(\w+)\}?/g, (all, k) => (args.get(k) ? args.get(k) : all));
        stage = { index: stages.length, name: m[3] || '', image, platform: m[1] || '', line: ins.line, expose: [], entrypoint: '', cmd: '', workdir: '', user: '', healthcheck: false, copiesFrom: [], env: 0, steps: 0 };
        stages.push(stage);
        continue;
      }
      if (!stage) continue;
      stage.steps++;
      switch (ins.op) {
        case 'EXPOSE': stage.expose.push(...ins.args.split(/\s+/).filter(Boolean).slice(0, 50)); break;
        case 'ENTRYPOINT': stage.entrypoint = execForm(ins.args); break;
        case 'CMD': stage.cmd = execForm(ins.args); break;
        case 'WORKDIR': stage.workdir = ins.args; break;
        case 'USER': stage.user = ins.args; break;
        case 'HEALTHCHECK': stage.healthcheck = !/^NONE\b/i.test(ins.args); break;
        case 'ENV': stage.env += Math.max(1, (ins.args.match(/(^|\s)[A-Za-z_][\w.-]*=/g) || []).length); break;
        case 'COPY': case 'ADD': {
          const from = /--from=(\S+)/.exec(ins.args);
          if (from && !stage.copiesFrom.includes(from[1])) stage.copiesFrom.push(from[1]);
          break;
        }
        default: break;
      }
    }
    return { stages };
  }

  function dockerCard({ root, file, Smart }) {
    const { stages } = parseDockerfile(file.text);
    if (!stages.length) return;
    const final = stages[stages.length - 1];
    const ref = (s) => s.name || kit.t('stage {0}', s.index + 1);
    const facts = [
      { label: kit.t('Base'), value: final.image, mono: true },
      { label: kit.t('Ports'), value: final.expose.join(', '), mono: true },
      { label: kit.t('Entrypoint'), value: final.entrypoint, mono: true },
      { label: kit.t('Command'), value: final.cmd, mono: true },
      { label: kit.t('Workdir'), value: final.workdir, mono: true },
      { label: kit.t('User'), value: final.user, mono: true },
      { label: kit.t('Healthcheck'), value: final.healthcheck ? kit.t('Yes') : '' },
    ];
    let body = Smart.facts(facts);
    if (stages.length > 1) {
      const byName = new Map(stages.map((s) => [s.name.toLowerCase(), s]));
      const find = (name) => byName.get(String(name).toLowerCase()) || (/^\d+$/.test(name) ? stages[Number(name)] : null);
      const edges = [];
      stages.forEach((s) => {
        const base = find(s.image);
        if (base) edges.push([String(base.index), String(s.index)]);
        s.copiesFrom.forEach((f) => { const from = find(f); if (from && from !== s) edges.push([String(from.index), String(s.index)]); });
      });
      const graph = Smart.graph(stages.map((s) => ({ id: String(s.index), label: ref(s), sub: find(s.image) ? kit.t('from {0}', ref(find(s.image))) : s.image, tone: s === final ? 'final' : '' })), edges, { label: kit.t('Build stages') });
      body += Smart.section(kit.t('Stages'), `<div class="smart-graph-wrap">${graph}</div>`, { count: stages.length, wide: true });
    }
    Smart.card(root, {
      kind: 'docker', icon: 'container', title: /^containerfile/.test(file.lower) ? 'Containerfile' : 'Dockerfile',
      subtitle: stages.length > 1 ? `${kit.plural(stages.length, '{0} stages')} · ${kit.t('Final: {0}', ref(final))}` : final.image,
      body,
    });
  }

  // ============================================================================ Compose

  function portText(p) {
    if (typeof p === 'string' || typeof p === 'number') return String(p);
    if (Smart.isObject(p)) return `${p.published != null ? p.published + ':' : ''}${p.target != null ? p.target : ''}${p.protocol && p.protocol !== 'tcp' ? '/' + p.protocol : ''}`;
    return '';
  }
  function volumeText(v) {
    if (typeof v === 'string') return v;
    if (Smart.isObject(v)) return `${v.source ? v.source + ':' : ''}${v.target || ''}`;
    return '';
  }

  function parseCompose(doc) {
    if (!Smart.isObject(doc) || !Smart.isObject(doc.services)) return null;
    const services = entries(doc.services, 200).map(([name, s]) => {
      const svc = Smart.isObject(s) ? s : {};
      const build = typeof svc.build === 'string' ? svc.build : Smart.isObject(svc.build) ? [svc.build.context, svc.build.dockerfile === 'Dockerfile' ? '' : svc.build.dockerfile].filter(Boolean).map((x) => str(x, 80)).join(' · ') || '.' : '';
      const depends = Array.isArray(svc.depends_on) ? svc.depends_on.map((d) => str(d, 80)) : Smart.isObject(svc.depends_on) ? Object.keys(svc.depends_on).slice(0, 50) : [];
      const env = Array.isArray(svc.environment) ? svc.environment.length : Smart.isObject(svc.environment) ? Object.keys(svc.environment).length : 0;
      return {
        name, image: str(svc.image, 120), build, depends,
        ports: arr(svc.ports).slice(0, 20).map(portText).filter(Boolean),
        volumes: arr(svc.volumes).slice(0, 20).map(volumeText).filter(Boolean),
        env, profiles: arr(svc.profiles).map((p) => str(p, 40)), restart: str(svc.restart, 40),
      };
    });
    return {
      name: str(doc.name, 80), services,
      volumes: Smart.isObject(doc.volumes) ? Object.keys(doc.volumes).length : 0,
      networks: Smart.isObject(doc.networks) ? Object.keys(doc.networks).length : 0,
    };
  }

  function composeCard({ root, file, Smart }) {
    const esc = Smart.esc;
    const compose = parseCompose(Smart.yaml(file.text));
    if (!compose || !compose.services.length) return;
    const rows = compose.services.map((s) => `<tr><td class="svc-name"><code>${esc(s.name)}</code>${s.profiles.length ? Smart.tag(s.profiles.join(', '), 'gray') : ''}</td>` +
      `<td class="svc-image">${s.image ? `<code title="${esc(s.image)}">${esc(s.image)}</code>` : ''}${s.build ? `<span class="smart-dim">build</span> <code>${esc(s.build)}</code>` : ''}</td>` +
      `<td class="svc-ports">${s.ports.map((p) => `<code>${esc(p)}</code>`).join(' ')}</td>` +
      `<td class="svc-volumes">${s.volumes.slice(0, 3).map((v) => `<code title="${esc(v)}">${esc(v)}</code>`).join(' ')}${s.volumes.length > 3 ? `<span class="smart-dim">+${s.volumes.length - 3}</span>` : ''}</td></tr>`);
    const head = `<thead><tr><th>${esc(kit.t('Service'))}</th><th>${esc(kit.t('Image [container]'))}</th><th>${esc(kit.t('Ports'))}</th><th>${esc(kit.t('Volumes'))}</th></tr></thead>`;
    let body = `<div class="smart-scroll"><table class="smart-table services">${head}<tbody>${rows.join('')}</tbody></table></div>`;
    const edges = [];
    compose.services.forEach((s) => s.depends.forEach((d) => edges.push([d, s.name])));
    if (edges.length) {
      const graph = Smart.graph(compose.services.map((s) => ({ id: s.name, label: s.name, sub: s.image ? s.image.split('/').pop() : s.build ? 'build' : '' })), edges, { label: kit.t('Start Order') });
      body += Smart.section(kit.t('Start Order'), `<div class="smart-graph-wrap">${graph}</div>`, { wide: true, aside: 'depends_on' });
    }
    Smart.card(root, {
      kind: 'compose', icon: 'stack', title: compose.name || 'Compose', label: compose.name ? 'Compose' : '',
      subtitle: [kit.plural(compose.services.length, '{0} services'), compose.volumes ? kit.plural(compose.volumes, '{0} volumes') : '', compose.networks ? kit.plural(compose.networks, '{0} networks') : ''].filter(Boolean).join(' · '),
      body,
    });
  }

  // ===================================================================== GitHub Actions

  function triggers(on) {
    const out = [];
    const describe = (name, value) => {
      const v = Smart.isObject(value) ? value : {};
      const branches = arr(v.branches).concat(arr(v.tags).map((t) => kit.t('tag {0}', str(t, 60)))).map((b) => str(b, 60)).slice(0, 6);
      // "1 input" is its own phrase: plural forms for 1 may also serve 21, 31… (Russian, Ukrainian).
      const inputs = (n) => (n === 1 ? kit.t('1 input') : kit.plural(n, '{0} inputs'));
      switch (name) {
        case 'push': return { event: name, name: kit.t('Push'), detail: branches.length ? kit.t('to {0}', branches.join(', ')) : '' };
        case 'pull_request': case 'pull_request_target': return { event: name, name: name === 'pull_request' ? kit.t('Pull request') : kit.t('Pull request target'), detail: [arr(v.types).join(', '), branches.length ? kit.t('into {0}', branches.join(', ')) : ''].filter(Boolean).join(' · ') };
        case 'schedule': return { event: name, name: kit.t('Schedule'), detail: arr(value).map((s) => (Smart.isObject(s) && s.cron ? ((Smart.cron && Smart.cron.describe(s.cron)) || s.cron) : '')).filter(Boolean).join('; ') };
        case 'workflow_dispatch': return { event: name, name: kit.t('Manual'), detail: Smart.isObject(v.inputs) ? inputs(Object.keys(v.inputs).length) : '' };
        case 'workflow_call': return { event: name, name: kit.t('Called by workflows'), detail: Smart.isObject(v.inputs) ? inputs(Object.keys(v.inputs).length) : '' };
        case 'release': return { event: name, name: kit.t('Release'), detail: arr(v.types).join(', ') };
        case 'workflow_run': return { event: name, name: kit.t('After workflow'), detail: arr(v.workflows).map((w) => str(w, 60)).join(', ') };
        default: return { event: name, name: name.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase()), detail: arr(v.types).join(', ') };
      }
    };
    if (typeof on === 'string') out.push(describe(on, null));
    else if (Array.isArray(on)) on.slice(0, 30).forEach((n) => out.push(describe(str(n, 60), null)));
    else entries(on, 30).forEach(([n, v]) => out.push(describe(n, v)));
    return out;
  }

  function runsOn(v) {
    if (typeof v === 'string') return v;
    if (Array.isArray(v)) return v.map((x) => str(x, 40)).join(', ');
    if (Smart.isObject(v)) return str(v.group || v.labels, 60);
    return '';
  }

  function parseWorkflow(doc) {
    if (!Smart.isObject(doc) || !Smart.isObject(doc.jobs)) return null;
    const on = doc.on !== undefined ? doc.on : doc.true;
    const jobs = entries(doc.jobs, 100).map(([id, j]) => {
      const job = Smart.isObject(j) ? j : {};
      const steps = arr(job.steps).slice(0, 200).map((s) => {
        const step = Smart.isObject(s) ? s : {};
        const run = typeof step.run === 'string' ? step.run.trim().split('\n')[0] : '';
        return { name: str(step.name, 120), uses: str(step.uses, 120), run: str(run, 160) };
      });
      const matrix = Smart.isObject(job.strategy) && Smart.isObject(job.strategy.matrix) ? Object.keys(job.strategy.matrix).filter((k) => k !== 'include' && k !== 'exclude') : [];
      return { id, name: str(job.name, 120), runsOn: runsOn(job['runs-on']), needs: arr(job.needs).map((n) => str(n, 80)), steps, uses: str(job.uses, 160), matrix, environment: str(Smart.isObject(job.environment) ? job.environment.name : job.environment, 60) };
    });
    return { name: str(doc.name, 120), triggers: triggers(on), jobs };
  }

  /** A trigger as it reads inside the card's subtitle, "On push, pull request and schedule". */
  const TRIGGER_RUN_IN = {
    push: () => kit.t('push'), pull_request: () => kit.t('pull request'), pull_request_target: () => kit.t('pull request target'),
    schedule: () => kit.t('schedule'), workflow_dispatch: () => kit.t('manual'), workflow_call: () => kit.t('called by workflows'),
    release: () => kit.t('release'), workflow_run: () => kit.t('after workflow'),
  };

  function workflowCard({ root, file, Smart }) {
    const esc = Smart.esc;
    const flow = parseWorkflow(Smart.yaml(file.text));
    if (!flow || !flow.jobs.length) return;
    const triggerHTML = flow.triggers.length ? `<ul class="smart-list triggers">${flow.triggers.map((t) => `<li><span class="smart-name plain">${esc(t.name)}</span><span class="smart-description">${esc(t.detail)}</span></li>`).join('')}</ul>` : '';
    let body = '';
    let top = triggerHTML ? Smart.section(kit.t('Triggers'), triggerHTML) : '';
    const hasNeeds = flow.jobs.some((j) => j.needs.length);
    if (hasNeeds) {
      const edges = [];
      flow.jobs.forEach((j) => j.needs.forEach((n) => edges.push([n, j.id])));
      const graph = Smart.graph(flow.jobs.map((j) => ({ id: j.id, label: j.name || j.id, sub: j.uses ? kit.t('reusable workflow') : `${kit.plural(j.steps.length, '{0} steps')}${j.matrix.length ? ' · matrix' : ''}` })), edges, { label: kit.t('Jobs') });
      top += Smart.section(kit.t('Jobs'), `<div class="smart-graph-wrap">${graph}</div>`, { count: flow.jobs.length, aside: 'needs' });
    }
    const jobsHTML = flow.jobs.map((j) => {
      const steps = j.steps.map((s, k) => {
        const what = s.uses || s.run;
        const label = s.name ? `<span class="step-name">${esc(s.name)}</span>${what ? `<code class="step-detail" title="${esc(what)}">${esc(what)}</code>` : ''}`
          : what ? `<code class="step-detail only" title="${esc(what)}">${esc(what)}</code>` : `<span class="step-name">${esc(kit.t('Step'))}</span>`;
        return `<li><span class="step-n">${k + 1}</span>${label}</li>`;
      }).join('');
      const meta = [j.runsOn && `<code>${esc(j.runsOn)}</code>`, j.matrix.length && `<span class="smart-dim">matrix</span> ${esc(j.matrix.join(', '))}`, j.environment && `<span class="smart-dim">env</span> ${esc(j.environment)}`, j.needs.length && `<span class="smart-dim">needs</span> ${esc(j.needs.join(', '))}`].filter(Boolean).join('<span class="sep"></span>');
      return `<details class="job"${!hasNeeds && flow.jobs.length <= 2 ? ' open' : ''}><summary><span class="job-name">${esc(j.name || j.id)}</span>${j.name && j.name !== j.id ? `<code class="smart-dim">${esc(j.id)}</code>` : ''}<span class="job-meta">${meta}</span><span class="smart-count">${esc(j.uses ? kit.t('reusable') : kit.plural(j.steps.length, '{0} steps'))}</span></summary>${j.uses ? `<p class="job-uses"><span class="smart-dim">${esc(kit.t('Uses'))}</span> <code>${esc(j.uses)}</code></p>` : steps ? `<ol class="steps">${steps}</ol>` : ''}</details>`;
    }).join('');
    if (top) body += `<div class="smart-grid">${top}</div>`;
    body += Smart.section(hasNeeds ? kit.t('Steps') : kit.t('Jobs'), `<div class="jobs">${jobsHTML}</div>`, { count: hasNeeds ? undefined : flow.jobs.length, wide: true });
    Smart.card(root, {
      kind: 'workflow', icon: 'workflow', title: flow.name || file.name, label: 'GitHub Actions',
      subtitle: [kit.plural(flow.jobs.length, '{0} jobs'), kit.plural(flow.jobs.reduce((n, j) => n + j.steps.length, 0), '{0} steps'),
        flow.triggers.length ? kit.t('On {0}', flow.triggers.map((t) => (TRIGGER_RUN_IN[t.event] ? TRIGGER_RUN_IN[t.event]() : t.event.replace(/_/g, ' '))).join(', ')) : ''].filter(Boolean).join(' · '),
      body,
    });
  }

  // ========================================================================= Kubernetes

  function containersOf(spec, depth = 0) {
    if (!Smart.isObject(spec) || depth > 6) return [];
    if (Array.isArray(spec.containers)) return spec.containers.concat(arr(spec.initContainers));
    for (const key of ['template', 'spec', 'jobTemplate']) {
      if (Smart.isObject(spec[key])) {
        const found = containersOf(spec[key], depth + 1);
        if (found.length) return found;
      }
    }
    return [];
  }

  function parseKubernetes(docs) {
    const resources = [];
    const add = (doc, depth) => {
      if (!Smart.isObject(doc) || resources.length >= 300 || depth > 3) return;
      if (doc.kind === 'List' && Array.isArray(doc.items)) { doc.items.slice(0, 300).forEach((d) => add(d, depth + 1)); return; }
      if (typeof doc.kind !== 'string' || typeof doc.apiVersion !== 'string') return;
      const meta = Smart.isObject(doc.metadata) ? doc.metadata : {};
      const spec = Smart.isObject(doc.spec) ? doc.spec : {};
      const containers = containersOf(spec).filter(Smart.isObject).slice(0, 20);
      const details = [];
      if (spec.replicas != null) details.push({ label: kit.t('replicas'), value: str(spec.replicas, 10) });
      if (doc.kind === 'Service') {
        if (spec.type) details.push({ label: kit.t('type'), value: str(spec.type, 30) });
        const ports = arr(spec.ports).filter(Smart.isObject).slice(0, 8).map((p) => `${p.port}${p.targetPort != null && p.targetPort !== p.port ? '→' + p.targetPort : ''}${p.protocol && p.protocol !== 'TCP' ? '/' + p.protocol : ''}`);
        if (ports.length) details.push({ label: kit.t('ports'), value: ports.join(', ') });
      }
      if (doc.kind === 'Ingress') {
        const hosts = arr(spec.rules).filter(Smart.isObject).map((r) => str(r.host, 80)).filter(Boolean);
        if (hosts.length) details.push({ label: kit.t('hosts'), value: hosts.slice(0, 4).join(', ') });
      }
      if (doc.kind === 'CronJob' && spec.schedule) details.push({ label: kit.t('schedule'), value: (Smart.cron && Smart.cron.describe(spec.schedule)) || str(spec.schedule, 40) });
      if ((doc.kind === 'ConfigMap' || doc.kind === 'Secret') && (Smart.isObject(doc.data) || Smart.isObject(doc.stringData))) {
        const keys = Object.keys(Object.assign({}, Smart.isObject(doc.data) ? doc.data : {}, Smart.isObject(doc.stringData) ? doc.stringData : {}));
        details.push({ label: kit.t('keys'), value: kit.number(keys.length) });
      }
      if (doc.kind === 'HorizontalPodAutoscaler' && spec.minReplicas != null) details.push({ label: kit.t('replicas'), value: `${spec.minReplicas}–${spec.maxReplicas}` });
      resources.push({
        kind: doc.kind, apiVersion: doc.apiVersion, name: str(meta.name || meta.generateName, 120), namespace: str(meta.namespace, 80),
        images: Array.from(new Set(containers.map((c) => str(c.image, 160)).filter(Boolean))), details,
      });
    };
    docs.forEach((d) => add(d, 0));
    return resources;
  }

  const KIND_TONE = { Deployment: 'blue', StatefulSet: 'blue', DaemonSet: 'blue', ReplicaSet: 'blue', Pod: 'blue', Job: 'purple', CronJob: 'purple', Service: 'green', Ingress: 'green', ConfigMap: 'orange', Secret: 'red', PersistentVolumeClaim: 'teal', Namespace: 'gray' };

  function kubernetesCard({ root, file, Smart }) {
    const esc = Smart.esc;
    const resources = parseKubernetes(Smart.yamlDocuments(file.text));
    if (!resources.length) return;
    const counts = new Map();
    resources.forEach((r) => counts.set(r.kind, (counts.get(r.kind) || 0) + 1));
    const rows = resources.map((r) => `<li class="k8s-resource"><span class="k8s-kind">${Smart.tag(r.kind, KIND_TONE[r.kind] || 'gray')}</span>` +
      `<span class="k8s-name"><code>${esc(r.name || kit.t('(unnamed)'))}</code>${r.namespace ? `<span class="smart-dim">${esc(r.namespace)}</span>` : ''}</span>` +
      `<span class="k8s-details">${r.images.map((i) => `<code class="k8s-image" title="${esc(i)}">${esc(i)}</code>`).join('')}${r.details.map((d) => `<span><span class="smart-dim">${esc(d.label)}</span> ${esc(d.value)}</span>`).join('')}</span></li>`);
    const namespaces = new Set(resources.map((r) => r.namespace).filter(Boolean));
    Smart.card(root, {
      kind: 'kubernetes', icon: 'cluster', title: resources.length === 1 ? resources[0].name || resources[0].kind : 'Kubernetes', label: resources.length === 1 ? resources[0].kind : '',
      subtitle: [kit.plural(resources.length, '{0} resources'), Array.from(counts.entries()).slice(0, 5).map(([k, n]) => (n > 1 ? kit.plural(n, '{0} {1}s', k) : k)).join(', '),
        namespaces.size ? kit.t('namespace {0}', Array.from(namespaces).slice(0, 2).join(', ')) : ''].filter(Boolean).join(' · '),
      body: `<ul class="k8s-list">${Smart.more(rows, 10)}</ul>`,
    });
  }

  // ======================================================================= Registration

  const kinds = Smart.kinds = Smart.kinds || [];
  kinds.push({
    id: 'docker', order: 20,
    detect: (file) => /^(dockerfile|containerfile)([.-][\w.-]+)?$/.test(file.lower) || /\.(dockerfile|containerfile)$/.test(file.lower),
    parse: parseDockerfile, enhance: dockerCard,
  });
  kinds.push({
    id: 'compose', order: 50, yaml: true,
    detect: (file) => Smart.isYAML(file) && (/^(docker-)?compose([.-][\w.-]+)?\.ya?ml$/.test(file.lower) ||
      (/^services:\s*$/m.test(file.head) && /^\s{2,}(image|build):/m.test(file.head) && !/^jobs:/m.test(file.head))),
    parse: (text) => parseCompose(Smart.yaml(text)), enhance: composeCard,
  });
  kinds.push({
    id: 'workflow', order: 51, yaml: true,
    detect: (file) => Smart.isYAML(file) && /^jobs:\s*$/m.test(file.head) && /^(on|"on"|'on'|true):/m.test(file.head) && /^\s+(runs-on|uses|steps):/m.test(file.head),
    parse: (text) => parseWorkflow(Smart.yaml(text)), enhance: workflowCard,
  });
  kinds.push({
    id: 'kubernetes', order: 53, yaml: true,
    detect: (file) => Smart.isYAML(file) && /^apiVersion:\s*\S/m.test(file.head) && /^kind:\s*[A-Z]\w*/m.test(file.head),
    parse: (text) => parseKubernetes(Smart.yamlDocuments(text)), enhance: kubernetesCard,
  });
})(typeof window !== 'undefined' ? window : globalThis);

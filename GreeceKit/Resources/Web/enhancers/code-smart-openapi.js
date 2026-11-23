/* Greece — OpenAPI 3 and Swagger 2 documents (JSON or YAML): the API's title, version and
   servers, then every endpoint grouped by tag, with a coloured method, its summary, and its
   parameters, request body and responses on expand. Local $refs are followed, with limits. */
(function (global) {
  'use strict';
  const Smart = global.GreeceSmart = global.GreeceSmart || {};
  /** The page's strings (Smart.kit), looked up when used: code-smart.js, which sets it, may load after this file. */
  const kit = new Proxy({}, { get: (_, name) => Smart.kit[name] });
  const str = (v, max) => Smart.text(v, max || 200);
  const METHODS = ['get', 'put', 'post', 'delete', 'options', 'head', 'patch', 'trace'];

  /** Follows a local "#/a/b" reference a few levels deep. */
  function resolver(doc) {
    const resolve = (node, depth = 0) => {
      if (!Smart.isObject(node) || typeof node.$ref !== 'string' || depth > 8) return node;
      if (!node.$ref.startsWith('#/')) return node;
      let target = doc;
      for (const raw of node.$ref.slice(2).split('/').slice(0, 12)) {
        const part = raw.replace(/~1/g, '/').replace(/~0/g, '~');
        if (!Smart.isObject(target) || !Object.prototype.hasOwnProperty.call(target, part)) return node;
        target = target[part];
      }
      return resolve(target, depth + 1);
    };
    return resolve;
  }

  function schemaType(schema, resolve, depth = 0) {
    const s = resolve(schema);
    if (!Smart.isObject(s) || depth > 4) return '';
    if (typeof schema.$ref === 'string') return schema.$ref.split('/').pop();
    if (s.type === 'array') return `[${schemaType(s.items, resolve, depth + 1) || 'any'}]`;
    if (Array.isArray(s.enum)) return s.enum.slice(0, 4).map((v) => str(v, 20)).join(' | ') + (s.enum.length > 4 ? ' | …' : '');
    const type = Array.isArray(s.type) ? s.type.join(' | ') : str(s.type, 30);
    return type + (s.format ? ` (${str(s.format, 20)})` : '') || (Array.isArray(s.oneOf) ? 'oneOf' : Array.isArray(s.anyOf) ? 'anyOf' : Array.isArray(s.allOf) ? 'allOf' : 'object');
  }

  function parse(doc) {
    if (!Smart.isObject(doc) || !(doc.openapi || doc.swagger) || !Smart.isObject(doc.paths)) return null;
    const resolve = resolver(doc);
    const info = Smart.isObject(doc.info) ? doc.info : {};
    const servers = Array.isArray(doc.servers) ? doc.servers.filter(Smart.isObject).map((s) => str(s.url, 200)) :
      doc.host ? [`${(Array.isArray(doc.schemes) && doc.schemes[0]) || 'https'}://${str(doc.host, 120)}${str(doc.basePath, 120)}`] : [];
    const tagInfo = new Map((Array.isArray(doc.tags) ? doc.tags : []).filter(Smart.isObject).map((t) => [str(t.name, 80), str(t.description, 200)]));
    const groups = new Map();
    let count = 0;
    for (const [path, rawItem] of Smart.entries(doc.paths, 3000)) {
      const item = resolve(rawItem);
      if (!Smart.isObject(item)) continue;
      const shared = Array.isArray(item.parameters) ? item.parameters : [];
      for (const method of METHODS) {
        const op = resolve(item[method]);
        if (!Smart.isObject(op) || count >= 5000) continue;
        count++;
        const params = shared.concat(Array.isArray(op.parameters) ? op.parameters : []).slice(0, 80).map((p) => resolve(p)).filter(Smart.isObject)
          .filter((p) => p.in !== 'body')
          .map((p) => ({ name: str(p.name, 80), in: str(p.in, 20), required: p.required === true, type: schemaType(p.schema || p, resolve), description: str(p.description, 200) }));
        let body = null;
        const requestBody = resolve(op.requestBody);
        if (Smart.isObject(requestBody) && Smart.isObject(requestBody.content)) {
          const [type, media] = Smart.entries(requestBody.content, 10)[0] || [];
          body = { type: str(type, 60), schema: Smart.isObject(media) ? schemaType(media.schema, resolve) : '', required: requestBody.required === true };
        } else {
          const swaggerBody = (Array.isArray(op.parameters) ? op.parameters : []).map((p) => resolve(p)).find((p) => Smart.isObject(p) && p.in === 'body');
          if (swaggerBody) body = { type: 'body', schema: schemaType(swaggerBody.schema, resolve), required: swaggerBody.required === true };
        }
        const responses = Smart.entries(op.responses, 30).map(([code, r]) => ({ code: str(code, 10), description: str(Smart.isObject(resolve(r)) ? resolve(r).description : '', 120) }));
        const tags = Array.isArray(op.tags) && op.tags.length ? op.tags.map((t) => str(t, 80)) : [kit.t('Other')];
        const endpoint = { method: method.toUpperCase(), path: str(path, 300), summary: str(op.summary || op.operationId || '', 200), description: str(op.description, 400), deprecated: op.deprecated === true, params, body, responses };
        const tag = tags[0];
        if (!groups.has(tag)) groups.set(tag, []);
        groups.get(tag).push(endpoint);
      }
    }
    const schemas = Smart.isObject(doc.components) && Smart.isObject(doc.components.schemas) ? Object.keys(doc.components.schemas).length : Smart.isObject(doc.definitions) ? Object.keys(doc.definitions).length : 0;
    return {
      title: str(info.title, 120) || 'API', version: str(info.version, 40), description: str(info.description, 300),
      spec: doc.openapi ? `OpenAPI ${str(doc.openapi, 10)}` : `Swagger ${str(doc.swagger, 10)}`,
      servers, count, schemas,
      groups: Array.from(groups.entries()).map(([name, endpoints]) => ({ name, description: tagInfo.get(name) || '', endpoints })),
    };
  }

  function card({ root, file, Smart }) {
    const esc = Smart.esc;
    let doc = null;
    if (file.text.length <= 8 * 1024 * 1024) {
      if (Smart.isJSON(file) || /^\s*\{/.test(file.head)) { try { doc = JSON.parse(file.text); } catch (_) { doc = null; } }
      else doc = Smart.yaml(file.text);
    }
    const api = parse(doc);
    if (!api || !api.count) return;
    const endpoint = (e) => {
      const params = e.params.length ? `<table class="smart-table params"><tbody>${e.params.map((p) => `<tr><td><code>${esc(p.name)}</code>${p.required ? `<span class="required" title="${esc(kit.t('Required'))}">*</span>` : ''}</td><td class="smart-dim">${esc(p.in)}</td><td><code class="type">${esc(p.type)}</code></td><td class="desc">${esc(p.description)}</td></tr>`).join('')}</tbody></table>` : '';
      const body = e.body ? `<p class="api-row"><span class="smart-dim">${esc(kit.t('Body'))}</span> <code>${esc(e.body.type)}</code>${e.body.schema ? ` <code class="type">${esc(e.body.schema)}</code>` : ''}${e.body.required ? `<span class="required" title="${esc(kit.t('Required'))}">*</span>` : ''}</p>` : '';
      const responses = e.responses.length ? `<p class="api-row responses">${e.responses.map((r) => `<span class="status s${esc(r.code[0])}" title="${esc(r.description)}">${esc(r.code)}</span>`).join('')}</p>` : '';
      const detail = (e.description && e.description !== e.summary ? `<p class="api-description">${esc(e.description)}</p>` : '') + params + body + responses;
      return `<details class="endpoint${e.deprecated ? ' deprecated' : ''}"><summary><span class="method m-${e.method.toLowerCase()}">${esc(e.method)}</span><code class="path">${esc(e.path)}</code><span class="summary">${esc(e.summary)}</span>${e.params.length ? `<span class="smart-count">${esc(kit.plural(e.params.length, '{0} params'))}</span>` : ''}</summary>${detail ? `<div class="endpoint-detail">${detail}</div>` : ''}</details>`;
    };
    const groups = api.groups.map((g) => `<section class="api-group"><h4>${esc(g.name)}<span class="smart-count">${kit.number(g.endpoints.length)}</span>${g.description ? `<span class="smart-dim">${esc(g.description)}</span>` : ''}</h4>${g.endpoints.slice(0, 400).map(endpoint).join('')}</section>`).join('');
    Smart.card(root, {
      kind: 'openapi', icon: 'api', title: api.title, version: api.version, label: api.spec,
      subtitle: [kit.plural(api.count, '{0} endpoints'), api.groups.length > 1 ? kit.plural(api.groups.length, '{0} tags') : '', api.schemas ? kit.plural(api.schemas, '{0} schemas') : '', api.servers[0] || ''].filter(Boolean).join(' · '),
      body: (api.description ? `<p class="api-intro">${esc(api.description)}</p>` : '') + `<div class="api-groups">${groups}</div>`,
    });
  }

  (Smart.kinds = Smart.kinds || []).push({
    id: 'openapi', order: 52,
    yaml: (file) => Smart.isYAML(file),
    detect: (file) => (Smart.isYAML(file) && /^(openapi|swagger):\s*["']?\d/m.test(file.head) && /^paths:/m.test(file.text)) ||
      (Smart.isJSON(file) && /^\s*\{[\s\S]{0,4000}?"(openapi|swagger)"\s*:\s*"\d/.test(file.head) && /"paths"\s*:/.test(file.text)),
    parse, enhance: card,
  });
})(typeof window !== 'undefined' ? window : globalThis);

// Rivo FX devtools page (client/devtools.lua sends it the data).
// Every string from the game is put in with textContent, never as HTML: span
// names, attributes and error messages can come from players.
(() => {
  'use strict';

  const IN_GAME = typeof window.GetParentResourceName === 'function';
  const RES = IN_GAME ? window.GetParentResourceName() : 'rivo_fx';
  const SIDES = ['server', 'client'];
  const MAX_SPANS = 3000;
  const MAX_FAILURES = 300;
  const HISTORY = 60;
  const STALE_MS = 5000;
  const THEME_KEY = 'rivo_fx.devtools.theme';
  // Long lists are cut to these until "show all" (a server can run hundreds of resources).
  const ROWS_OVERVIEW = 50;
  const ROWS_FIBERS = 400;
  const SERIES_PER_FAMILY = 8;
  const FOLD_FIBERS_OVER = 60; // fiber groups start folded when there are more fibers than this

  const ICONS = {
    overview: ['M4 4h6v6H4z', 'M14 4h6v6h-6z', 'M4 14h6v6H4z', 'M14 14h6v6h-6z'],
    fibers: ['M6 3v12', 'M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6z', 'M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6z', 'M18 9a9 9 0 0 1-9 9'],
    spans: ['M3 5h10', 'M7 10h11', 'M10 15h8', 'M5 20h6'],
    failures: ['M12 3 2 20h20L12 3z', 'M12 10v4', 'M12 17h.01'],
    metrics: ['M4 20V10', 'M10 20V4', 'M16 20v-7', 'M22 20H2'],
  };
  const VIEWS = [
    { id: 'overview', label: 'Overview', sub: 'Every resource using Rivo FX, on the server and on this client' },
    { id: 'fibers', label: 'Fibers', sub: 'Fibers alive right now, each child under its parent' },
    { id: 'spans', label: 'Traces', sub: 'Recent spans as traces. A client call and the server handler it reached share one trace' },
    { id: 'failures', label: 'Failures', sub: 'Error logs, unhandled fiber failures and defects' },
    { id: 'metrics', label: 'Metrics', sub: 'Counters, gauges and histograms of each resource' },
  ];

  const $ = (id) => document.getElementById(id);
  const pageErrors = [];
  window.addEventListener('error', (e) => pageErrors.push(String(e.message)));
  const app = $('app');
  const main = $('main');
  const tabs = $('tabs');

  let state = initialState();

  function initialState(prev) {
    return {
      view: prev ? prev.view : 'overview',
      side: prev ? prev.side : 'all',
      filter: prev ? prev.filter : '',
      paused: prev ? prev.paused : false,
      overview: { server: [], client: [] },
      fibers: { server: [], client: [] },
      metrics: { server: [], client: [] },
      loaded: {},
      history: [],
      spans: new Map(),
      failures: new Map(),
      trace: null,
      span: null,
      failure: null,
      updated: 0,
      poll: 1000,
      clock: prev ? prev.clock : {},
      sort: prev ? prev.sort : { key: 'activity', dir: -1 },
      showAll: {},
      open: {}, // group or family key -> folded (false) or open (true), set by a click
      errorsOnly: prev ? prev.errorsOnly : false,
    };
  }

  // Helpers ------------------------------------------------------------------

  function post(name, body) {
    if (!IN_GAME) return;
    fetch(`https://${RES}/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(body || {}),
    }).catch(() => {});
  }

  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    if (props) {
      for (const [k, v] of Object.entries(props)) {
        if (v == null || v === false) continue;
        if (k === 'class') el.className = v;
        else if (k === 'text') el.textContent = String(v);
        else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, String(v));
      }
    }
    for (const c of children.flat(Infinity)) {
      if (c == null || c === false) continue;
      el.append(c instanceof Node ? c : String(c));
    }
    return el;
  }

  function icon(paths) {
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');
    for (const d of paths) {
      const p = document.createElementNS(NS, 'path');
      p.setAttribute('d', d);
      svg.append(p);
    }
    return svg;
  }

  // Lua sends an empty table as [] or {}; lists may arrive as objects.
  const list = (v) => (Array.isArray(v) ? v : v && typeof v === 'object' ? Object.values(v) : []);
  const entries = (v) => (v && typeof v === 'object' && !Array.isArray(v) ? Object.entries(v) : []);
  const str = (v) => (v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v));
  const isId = (v) => typeof v === 'string' && /^[0-9a-f]{8,32}$/.test(v);

  // A duration as [figure, unit], so the unit can be set smaller and grey.
  function msParts(ms) {
    if (typeof ms !== 'number' || !isFinite(ms)) return ['', ''];
    if (ms < 1) return ['<1', 'ms'];
    if (ms < 1000) return [String(Math.round(ms)), 'ms'];
    if (ms < 60000) return [(ms / 1000).toFixed(ms < 10000 ? 2 : 1), 's'];
    const m = Math.floor(ms / 60000);
    if (m < 60) return [`${m}m ${Math.floor((ms % 60000) / 1000)}`, 's'];
    return [`${Math.floor(m / 60)}h ${m % 60}`, 'm'];
  }
  const fmtMs = (ms) => msParts(ms).join(' ').trim();
  const dur = (ms) => {
    const [v, u] = msParts(ms);
    return h('span', { class: 'mono' }, v, u ? h('span', { class: 'unit', text: u }) : null);
  };

  // Times are the clock of the side that recorded them; the page's own clock
  // can be far off (another machine), so compare with that side's last "now".
  function ago(t, side) {
    if (typeof t !== 'number') return '';
    const d = Date.now() + (state.clock[side] || 0) - t;
    if (d < 1500) return 'just now';
    if (d < 60000) return `${Math.round(d / 1000)}s ago`;
    if (d < 3600000) return `${Math.round(d / 60000)}m ago`;
    return `${Math.round(d / 3600000)}h ago`;
  }

  function fmtNum(v) {
    if (typeof v !== 'number') return str(v);
    if (Number.isInteger(v)) return v.toLocaleString('en-US');
    return Math.abs(v) >= 100 ? v.toFixed(1) : v.toPrecision(3);
  }

  const showSide = (side) => state.side === 'all' || state.side === side;
  const sidesShown = () => SIDES.filter(showSide);
  const who = (side, name) => h('span', { class: `who ${side}`, title: `${name} (${side})` }, h('span', { class: 'name', text: name }));
  // A resource on one line: side rule, name, side, then any tags.
  const resCell = (side, name, ...tags) => h('div', { class: 'res' }, who(side, name), h('span', { class: 'side-tag', text: side }), tags);
  const CHEVRON = ['m9 6 6 6-6 6'];

  function matches(...fields) {
    const f = state.filter.trim().toLowerCase();
    if (!f) return true;
    return fields.some((x) => str(x).toLowerCase().includes(f));
  }

  const empty = (title, detail) => h('div', { class: 'empty' }, h('div', { class: 't', text: title }), detail ? h('div', { class: 'd', text: detail }) : null);
  const waiting = () => empty('Waiting for the first update', 'Data arrives about once a second.');
  const label = (text) => h('div', { class: 'section-label' }, h('span', { text }));

  // Data ---------------------------------------------------------------------

  function addSpan(s) {
    if (!s || !isId(s.spanId) || !isId(s.traceId)) return;
    const key = `${s.side}|${s.resource}|${s.spanId}`;
    state.spans.delete(key);
    state.spans.set(key, s);
    while (state.spans.size > MAX_SPANS) state.spans.delete(state.spans.keys().next().value);
  }

  function addFailure(f) {
    if (!f || typeof f.seq !== 'number') return;
    const key = `${f.side}|${f.resource}|${f.seq}|${f.time}`;
    state.failures.set(key, Object.assign({ key }, f));
    while (state.failures.size > MAX_FAILURES) state.failures.delete(state.failures.keys().next().value);
  }

  function liveTotal() {
    let n = 0;
    for (const side of sidesShown()) for (const r of state.overview[side]) n += Number(r && r.live) || 0;
    return n;
  }

  function onData(side, view, data, now, poll) {
    if (!SIDES.includes(side)) return;
    state.updated = Date.now();
    if (typeof poll === 'number' && poll > 0) state.poll = poll;
    if (typeof now === 'number' && isFinite(now)) state.clock[side] = now - Date.now();
    state.loaded[view] = true;
    if (view === 'overview' || view === 'fibers' || view === 'metrics') {
      state[view][side] = list(data);
    } else if (view === 'spans') {
      for (const s of list(data)) addSpan(s);
    } else if (view === 'failures') {
      for (const f of list(data)) addFailure(f);
    }
    if (view === 'overview') {
      // one sample a second, whichever side answered last
      const last = state.history[state.history.length - 1];
      const sample = { t: Date.now(), live: liveTotal() };
      if (last && sample.t - last.t < 800) state.history[state.history.length - 1] = sample;
      else state.history.push(sample);
      if (state.history.length > HISTORY) state.history.shift();
    }
    render();
  }

  // Traces -------------------------------------------------------------------

  function traces() {
    const byTrace = new Map();
    for (const s of state.spans.values()) {
      let t = byTrace.get(s.traceId);
      if (!t) {
        t = { id: s.traceId, spans: [] };
        byTrace.set(s.traceId, t);
      }
      t.spans.push(s);
    }
    const out = [];
    for (const t of byTrace.values()) {
      const ids = new Set(t.spans.map((s) => s.spanId));
      const roots = t.spans.filter((s) => !s.parentSpanId || !ids.has(s.parentSpanId));
      roots.sort((a, b) => a.startTime - b.startTime);
      t.root = roots[0] || t.spans[0];
      // when it ended on the page's clock, to sort traces from both sides together
      t.seen = Math.max(...t.spans.map((s) => s.endTime - (state.clock[s.side] || 0)));
      t.errors = t.spans.filter((s) => s.status === 'error').length;
      t.sides = SIDES.filter((side) => t.spans.some((s) => s.side === side));
      t.resources = [...new Set(t.spans.map((s) => s.resource))];
      t.remote = Boolean(t.root.parentSpanId); // continues a trace from elsewhere
      if (!t.sides.some(showSide)) continue;
      if (!t.spans.some((s) => matches(s.name, s.resource))) continue;
      if (state.errorsOnly && !t.errors) continue;
      out.push(t);
    }
    out.sort((a, b) => b.seen - a.seen);
    return out;
  }

  // Lays a trace out as rows. Each side and resource has its own clock (the
  // server and a player's PC can be seconds apart), so a span that falls
  // outside its parent from another clock is moved into the middle of it.
  function waterfall(t) {
    const domain = (s) => `${s.side}|${s.resource}`;
    const byId = new Map(t.spans.map((s) => [s.spanId, s]));
    const kids = new Map();
    const roots = [];
    for (const s of t.spans) {
      if (s.parentSpanId && byId.has(s.parentSpanId) && s.parentSpanId !== s.spanId) {
        if (!kids.has(s.parentSpanId)) kids.set(s.parentSpanId, []);
        kids.get(s.parentSpanId).push(s);
      } else {
        roots.push(s);
      }
    }
    const byStart = (a, b) => a.startTime - b.startTime;
    roots.sort(byStart);
    const offset = new Map();
    const moved = new Set();
    const rows = [];
    const seen = new Set();
    const visit = (s, depth, parent) => {
      if (seen.has(s.spanId) || depth > 40) return;
      seen.add(s.spanId);
      const d = domain(s);
      if (!offset.has(d)) {
        let off = 0;
        if (parent && domain(parent) !== d) {
          const po = offset.get(domain(parent)) || 0;
          const ps = parent.startTime + po;
          const pe = parent.endTime + po;
          if (s.startTime < ps || s.endTime > pe) {
            const len = s.endTime - s.startTime;
            off = ps + Math.max(0, (pe - ps - len) / 2) - s.startTime;
            moved.add(d);
          }
        }
        offset.set(d, off);
      }
      const o = offset.get(d);
      rows.push({ s, depth, start: s.startTime + o, end: s.endTime + o, moved: moved.has(d) });
      for (const k of (kids.get(s.spanId) || []).sort(byStart)) visit(k, depth + 1, s);
    };
    for (const r of roots) visit(r, 0, null);
    const t0 = Math.min(...rows.map((r) => r.start));
    const t1 = Math.max(...rows.map((r) => r.end));
    return { rows, t0, length: t1 - t0, total: Math.max(1, t1 - t0) };
  }

  const spanKey = (s) => `${s.side}|${s.resource}|${s.spanId}`;

  // Views --------------------------------------------------------------------

  function cell(k, v, s, bad) {
    return h('div', { class: 'cell' }, h('div', { class: 'k', text: k }),
      h('div', { class: `v${bad ? ' bad' : ''}`, text: v }), s != null ? h('div', { class: 's', text: s }) : null);
  }

  // Busiest first: failures, then live fibers, then spans, then the name.
  const SORTS = {
    activity: (a, b) => (b.failures || 0) - (a.failures || 0) || (b.live || 0) - (a.live || 0)
      || (b.spans || 0) - (a.spans || 0) || a.resource.localeCompare(b.resource),
    resource: (a, b) => a.resource.localeCompare(b.resource) || a.side.localeCompare(b.side),
  };
  function sortRows(rows) {
    const { key, dir } = state.sort;
    if (key === 'activity') return rows.slice().sort(SORTS.activity);
    if (key === 'resource') return rows.slice().sort((a, b) => dir * SORTS.resource(a, b));
    return rows.slice().sort((a, b) => dir * ((Number(a[key]) || 0) - (Number(b[key]) || 0)) || SORTS.resource(a, b));
  }

  function sortButton(key, text) {
    const on = state.sort.key === key;
    return h('button', {
      type: 'button',
      class: `sort${on ? ' on' : ''}`,
      title: on && state.sort.dir === -1 ? 'Sorted high to low; click to flip' : 'Sort',
      onclick: () => {
        // a click on the sorted column flips it; a third click goes back to busiest first
        const first = key === 'resource' ? 1 : -1; // A to Z, or high to low
        if (!on) state.sort = { key, dir: first };
        else if (state.sort.dir === first) state.sort = { key, dir: -first };
        else state.sort = { key: 'activity', dir: -1 };
        render();
      },
    }, text, on ? h('span', { class: 'dir', text: state.sort.dir === -1 ? '▼' : '▲' }) : null);
  }

  // "Show all N" under a list cut to limit rows.
  function more(key, total, limit, noun) {
    if (total <= limit) return null;
    const all = state.showAll[key];
    return h('div', { class: 'more' }, h('button', {
      type: 'button',
      class: 'btn',
      onclick: () => { state.showAll[key] = !all; render(); },
    }, all ? `Show the first ${fmtNum(limit)}` : `Show all ${fmtNum(total)} ${noun}`));
  }

  function renderOverview() {
    const rows = [];
    for (const side of sidesShown()) {
      for (const r of state.overview[side]) if (r && matches(r.resource)) rows.push(Object.assign({ side }, r));
    }
    if (!state.loaded.overview) return waiting();
    if (!rows.length) return empty('No resources match', 'Nothing using Rivo FX matches this side and filter.');
    const sum = (k, side) => rows.reduce((n, r) => n + (!side || r.side === side ? Number(r[k]) || 0 : 0), 0);
    const count = (side) => rows.filter((r) => r.side === side).length;
    const split = (k) => `${fmtNum(sum(k, 'server'))} server · ${fmtNum(sum(k, 'client'))} client`;
    const failures = sum('failures');
    const kpis = h('div', { class: 'cells' },
      cell('Resources', fmtNum(rows.length), `${count('server')} server · ${count('client')} client`),
      cell('Live fibers', fmtNum(sum('live')), split('live')),
      cell('Timers', fmtNum(sum('timers')), split('timers')),
      cell('Spans finished', fmtNum(sum('spans')), 'since start'),
      cell('Failures', fmtNum(failures), failures ? split('failures') : 'none recorded', failures > 0));

    const hist = state.history;
    const peak = Math.max(1, ...hist.map((x) => x.live));
    const now = hist[hist.length - 1];
    const level = now ? `top:calc(30px + (100% - 60px) * ${(1 - now.live / peak).toFixed(3)})` : '';
    const chart = h('div', { class: 'card' },
      h('div', { class: 'card-head' }, h('span', { class: 'card-title', text: 'Live fibers' }),
        h('span', { class: 'side-tag', text: `last ${hist.length}s · peak ${fmtNum(peak)}` })),
      hist.length < 2
        ? h('div', { class: 'chart' }, h('div', { class: 'empty', style: 'position:absolute;inset:14px 18px;min-height:0' },
          h('div', { class: 'd', text: 'Collecting a sample a second while this view is open' })))
        : h('div', { class: 'chart' },
          h('div', { class: 'bars' }, Array.from({ length: HISTORY }, (_, i) => {
            const x = hist[i - (HISTORY - hist.length)];
            if (!x) return h('i', { style: 'height:0' });
            return h('i', { class: x === now ? 'now' : null, style: `height:${Math.max(2, (x.live / peak) * 100).toFixed(1)}%` });
          })),
          h('div', { class: 'guide', style: level }),
          h('div', { class: 'flag', style: level, text: `now ${fmtNum(now.live)}` }),
          h('div', { class: 'axis' }, h('span', { text: `-${hist.length}s` }), h('span', { text: 'now' }))));

    const sorted = sortRows(rows);
    const shown = state.showAll.overview ? sorted : sorted.slice(0, ROWS_OVERVIEW);
    const maxLive = Math.max(1, ...rows.map((r) => Number(r.live) || 0));
    const head = (key, text, num) => h('th', { class: num ? 'num' : null }, sortButton(key, text));
    const table = h('div', { class: 'card' }, h('div', { class: 'scroll' }, h('table', null,
      h('thead', null, h('tr', null,
        head('resource', 'Resource'), head('live', 'Live fibers', true), head('timers', 'Timers', true),
        head('spans', 'Spans', true), head('failures', 'Failures', true), h('th', { text: 'Last failure' }))),
      h('tbody', null, shown.map((r) => h('tr', null,
        h('td', null, resCell(r.side, r.resource,
          r.tracing === false ? h('span', { class: 'pill plain', title: 'set rivo_fx:tracing off', text: 'tracing off' }) : null)),
        h('td', null, h('div', { class: 'meter' }, h('span', { class: 'mono', text: fmtNum(r.live) }),
          h('span', { class: 'bar' }, h('span', { style: `width:${(((Number(r.live) || 0) / maxLive) * 100).toFixed(1)}%` })))),
        h('td', { class: 'num', text: fmtNum(r.timers) }),
        h('td', { class: 'num', text: fmtNum(r.spans) }),
        h('td', { class: 'num' }, r.failures > 0 ? h('span', { class: 'pill error plain', text: fmtNum(r.failures) }) : h('span', { class: 'muted', text: '0' })),
        h('td', null, r.lastFailureMessage != null
          ? [str(r.lastFailureMessage), ' ', h('span', { class: 'side-tag', text: ago(r.lastFailure, r.side) })]
          : h('span', { class: 'muted', text: 'None' })))))),
      more('overview', sorted.length, ROWS_OVERVIEW, 'resources')));
    return [kpis, chart, label(`Resources · ${fmtNum(rows.length)}`), table];
  }

  // One folding group per resource and side; big servers start folded.
  function renderFibers() {
    if (!state.loaded.fibers) return waiting();
    const groups = [];
    const by = { waiting: 0, running: 0, interrupting: 0 };
    let total = 0;
    for (const side of sidesShown()) {
      for (const r of state.fibers[side]) {
        if (!r || !matches(r.resource)) continue;
        const fibers = list(r.list);
        if (!fibers.length) continue;
        const depth = new Map();
        const rows = fibers.map((f) => {
          const d = f.parent != null && depth.has(f.parent) ? depth.get(f.parent) + 1 : 0;
          depth.set(f.id, d);
          if (by[f.status] != null) by[f.status] += 1;
          return { f, depth: d };
        });
        total += Number(r.total) || fibers.length;
        groups.push({ key: `fib|${side}|${r.resource}`, side, resource: r.resource, total: Number(r.total) || fibers.length, rows });
      }
    }
    if (!groups.length) return empty('No live fibers', 'Fibers show up here while they run or wait.');
    groups.sort((a, b) => b.total - a.total || a.resource.localeCompare(b.resource));
    const foldAll = total > FOLD_FIBERS_OVER && !state.filter.trim();
    const kpis = h('div', { class: 'cells' },
      cell('Live', fmtNum(total), `in ${fmtNum(groups.length)} resource${groups.length === 1 ? '' : 's'}`),
      cell('Waiting', fmtNum(by.waiting), 'parked on a timer, event or join'),
      cell('Running', fmtNum(by.running), 'running or queued this tick'),
      cell('Interrupting', fmtNum(by.interrupting), 'finishing their cleanup', by.interrupting > 0));
    const body = [];
    let drawn = 0;
    for (const g of groups) {
      const open = state.open[g.key] ?? !foldAll;
      const counts = {};
      for (const { f } of g.rows) counts[f.status] = (counts[f.status] || 0) + 1;
      body.push(h('tr', { class: `group${open ? ' open' : ''}`, onclick: () => { state.open[g.key] = !open; render(); } },
        h('td', { colspan: 6 }, h('div', { class: 'group-row' },
          h('span', { class: 'chev' }, icon(CHEVRON)),
          resCell(g.side, g.resource),
          h('span', { class: 'gmeta' }, h('span', { text: `${fmtNum(g.total)} fiber${g.total === 1 ? '' : 's'}` }),
            Object.entries(counts).map(([k, n]) => h('span', { class: k === 'running' || k === 'interrupting' ? `pill ${k}` : 'pill', text: `${n} ${k}` })))))));
      if (!open) continue;
      for (const { f, depth } of g.rows) {
        if (drawn >= ROWS_FIBERS && !state.showAll.fibers) break;
        drawn += 1;
        body.push(h('tr', null,
          h('td', { class: 'mono' }, h('span', { style: `padding-left:${36 + Math.min(depth, 12) * 16}px` },
            depth ? h('span', { class: 'muted', text: '└ ' }) : null, `#${f.id}`)),
          h('td', null, h('span', { class: `pill ${f.status === 'running' || f.status === 'interrupting' ? f.status : ''}`, text: str(f.status) })),
          h('td', { class: 'num' }, dur(f.age)),
          h('td', { class: 'num' }, f.children ? fmtNum(f.children) : h('span', { class: 'muted', text: '–' })),
          h('td', null, f.span ? traceLink(f.traceId, f.span) : h('span', { class: 'muted', text: '–' })),
          h('td')));
      }
      if (g.total > g.rows.length) {
        body.push(h('tr', null, h('td', { colspan: 6, class: 'muted', style: 'padding-left:30px;font-size:12px',
          text: `${fmtNum(g.total - g.rows.length)} more not sent (the first ${g.rows.length} of each resource are shown)` })));
      }
    }
    return [
      kpis,
      h('div', { class: 'card' }, h('div', { class: 'scroll' }, h('table', null,
        h('thead', null, h('tr', null,
          h('th', { text: 'Fiber' }), h('th', { text: 'Status' }), h('th', { class: 'num', text: 'Age' }),
          h('th', { class: 'num', text: 'Children' }), h('th', { text: 'In span' }), h('th'))),
        h('tbody', null, body))),
      drawn >= ROWS_FIBERS ? more('fibers', total, ROWS_FIBERS, 'fibers') : null),
    ];
  }

  function traceLink(traceId, text) {
    if (!isId(traceId)) return h('span', { text });
    return h('a', {
      class: 'link',
      text,
      title: 'Open the trace',
      href: '#',
      onclick: (e) => {
        e.preventDefault();
        e.stopPropagation();
        state.trace = traceId;
        state.span = null;
        setView('spans');
      },
    });
  }

  function renderSpans() {
    if (!state.loaded.spans) return waiting();
    const ts = traces();
    const errorsToggle = h('button', {
      type: 'button',
      class: `toggle${state.errorsOnly ? ' on' : ''}`,
      'aria-pressed': state.errorsOnly ? 'true' : 'false',
      onclick: () => { state.errorsOnly = !state.errorsOnly; render(); },
    }, 'errors only');
    if (!ts.length) {
      if (state.errorsOnly) return [h('div', { class: 'section-label' }, h('span'), errorsToggle), empty('No traces with errors', 'Every recent trace finished without an error.')];
      return empty('No traces yet', 'Wrap an effect in :withSpan(name), or make an Fx.rpc call, and it shows up here.');
    }
    if (!state.trace || !ts.some((t) => t.id === state.trace)) state.trace = ts[0].id;
    const listCard = h('div', { class: 'card' },
      h('div', { class: 'card-head' }, h('span', { class: 'card-title' }, 'Recent traces ', h('span', { class: 'side-tag', text: fmtNum(ts.length) })), errorsToggle),
      h('div', { class: 'trace-list' }, ts.slice(0, 200).map((t) => {
        const wf = waterfall(t);
        return h('button', {
          type: 'button',
          class: `trace-item${t.id === state.trace ? ' selected' : ''}`,
          onclick: () => { state.trace = t.id; state.span = null; render(); },
        },
        h('div', { class: 't-name' }, t.errors ? h('i', { class: 'err-dot', title: 'has errors' }) : null, h('span', { text: t.root.name })),
        h('div', { class: 't-dur' }, dur(wf.length)),
        h('div', { class: 't-meta' }, h('span', { class: 'dots' }, t.sides.map((s) => h('i', { class: s, title: s }))),
          h('span', { class: 'res', text: `${t.spans.length} span${t.spans.length === 1 ? '' : 's'} · ${t.resources.join(', ')}` })),
        h('div', { class: 't-when', text: ago(t.seen, 'page') }));
      })));
    const t = ts.find((x) => x.id === state.trace);
    return h('div', { class: 'split' }, listCard, renderTrace(t));
  }

  function renderTrace(t) {
    const { rows, t0, total, length } = waterfall(t);
    let lit = rows.find((r) => spanKey(r.s) === state.span);
    if (!lit) lit = rows[0];
    const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => h('span', { style: `left:${f * 100}%`, text: f === 0 ? '0' : fmtMs(total * f) }));
    return h('div', { class: 'card' },
      h('div', { class: 'trace-head' },
        h('div', { style: 'min-width:0' }, h('div', { class: 'tt', text: t.root.name }), h('div', { class: 'tid', text: t.id })),
        h('div', { class: 'stats' },
          h('div', { class: 'stat' }, h('div', { class: 'k', text: 'Duration' }), h('div', { class: 'v' }, dur(length))),
          h('div', { class: 'stat' }, h('div', { class: 'k', text: 'Spans' }), h('div', { class: 'v', text: rows.length })),
          h('div', { class: 'stat' }, h('div', { class: 'k', text: 'Errors' }), h('div', { class: `v${t.errors ? ' bad' : ''}`, text: t.errors })))),
      h('div', { class: 'legend' }, t.sides.map((s) => who(s, s)),
        t.remote ? h('span', { text: 'Continues a trace started outside Rivo FX' }) : null,
        rows.some((r) => r.moved) ? h('span', null, h('span', { class: 'skew', text: '~ ' }), 'another clock, placed inside its parent') : null),
      h('div', { class: 'wf' },
        h('div', { class: 'wf-axis' }, h('span'), h('div', { class: 'ticks' }, ticks), h('span')),
        h('div', { class: 'wf-rows' }, rows.map((r) => {
          const s = r.s;
          const key = spanKey(s);
          const left = ((r.start - t0) / total) * 100;
          const width = Math.max(0.5, ((r.end - r.start) / total) * 100);
          const err = s.status === 'error';
          const nodes = [h('div', {
            class: `wf-row${state.span === key ? ' selected' : ''}`,
            onclick: () => { state.span = state.span === key ? null : key; render(); },
          },
          h('div', { class: `wf-name${err ? ' err' : ''}`, title: `${s.name} · ${s.resource} (${s.side})`, style: `padding-left:${Math.min(r.depth, 10) * 14}px` },
            who(s.side, s.name), h('span', { class: 'res', text: s.resource }),
            r.moved ? h('span', { class: 'skew', title: 'Another clock: placed inside its parent', text: '~' }) : null),
          h('div', { class: 'wf-track' }, h('div', {
            class: `wf-bar${err ? ' error' : r === lit ? ' lit' : ''}`,
            style: `left:${left.toFixed(2)}%;width:${Math.min(width, 100 - left).toFixed(2)}%`,
          })),
          h('div', { class: 'wf-dur' }, dur(s.endTime - s.startTime)))];
          if (state.span === key) nodes.push(spanDetail(s));
          return nodes;
        }))));
  }

  function spanDetail(s) {
    const kv = h('dl', { class: 'kv' });
    const add = (k, v) => { if (v != null && v !== '') kv.append(h('dt', { text: k }), h('dd', { text: str(v) })); };
    add('status', s.status);
    add('message', s.message);
    add('kind', s.kind);
    add('resource', `${s.resource} (${s.side})`);
    add('duration', fmtMs(s.endTime - s.startTime));
    add('span id', s.spanId);
    add('parent', s.parentSpanId);
    add('traceparent', `00-${s.traceId}-${s.spanId}-01`);
    for (const [k, v] of entries(s.attributes).sort(([a], [b]) => a.localeCompare(b))) add(k, v);
    const events = list(s.events);
    return h('div', { class: 'tray span-detail' },
      h('div', { class: 'tray-head' }, h('span', { class: 'card-title', text: s.name }),
        h('span', { class: `pill ${s.status === 'error' ? 'error' : s.status === 'ok' ? 'on' : ''}`, text: str(s.status) })),
      h('div', { class: 'card' }, kv,
        events.length ? h('div', { class: 'events' }, events.map((e) => h('div', null,
          h('span', { class: 'muted', text: `+${fmtMs((e.time || s.startTime) - s.startTime)}  ` }), str(e.name),
          entries(e.attributes).length ? h('span', { class: 'muted', text: `  ${str(e.attributes)}` }) : null))) : null));
  }

  // The same message from the same resource is one row with a count, so a
  // failure that repeats every tick does not bury the rest.
  function renderFailures() {
    if (!state.loaded.failures) return waiting();
    const pageTime = (f) => (f.time || 0) - (state.clock[f.side] || 0);
    const groups = new Map();
    for (const f of state.failures.values()) {
      if (!showSide(f.side) || !matches(f.resource, f.message, f.cause)) continue;
      const key = `${f.side}|${f.resource}|${str(f.message)}`;
      const g = groups.get(key);
      if (!g) groups.set(key, { key, latest: f, first: f, count: 1 });
      else {
        g.count += 1;
        if (pageTime(f) >= pageTime(g.latest)) g.latest = f;
        if (pageTime(f) < pageTime(g.first)) g.first = f;
      }
    }
    const items = [...groups.values()].sort((a, b) => pageTime(b.latest) - pageTime(a.latest));
    if (!items.length) return empty('No failures', 'Unhandled fiber failures, defects and error logs show up here.');
    const total = items.reduce((n, g) => n + g.count, 0);
    const rows = [];
    for (const g of items.slice(0, MAX_FAILURES)) {
      const f = g.latest;
      const open = state.failure === g.key;
      rows.push(h('tr', { class: `click${open ? ' open' : ''}`, onclick: () => { state.failure = open ? null : g.key; render(); } },
        h('td', null, h('span', { class: 'pill error plain', text: 'error' }), ' ', str(f.message),
          g.count > 1 ? h('span', { class: 'count-x', title: `${g.count} times`, text: `×${fmtNum(g.count)}` }) : null),
        h('td', null, who(f.side, f.resource)),
        h('td', { class: 'num', text: f.fiber != null ? `#${f.fiber}` : '–' }),
        h('td', null, isId(f.traceId) ? traceLink(f.traceId, f.traceId.slice(0, 8)) : h('span', { class: 'muted', text: '–' })),
        h('td', { class: 'num muted', text: ago(f.time, f.side) })));
      if (open) {
        const kv = h('dl', { class: 'kv' });
        if (g.count > 1) kv.append(h('dt', { text: 'seen' }), h('dd', { text: `${g.count} times, first ${ago(g.first.time, g.first.side)}` }));
        for (const [k, v] of entries(f.fields)) kv.append(h('dt', { text: k }), h('dd', { text: str(v) }));
        rows.push(h('tr', { class: 'detail' }, h('td', { colspan: 5 }, h('div', { class: 'failure-detail' },
          f.cause ? h('pre', { text: f.cause }) : null, kv.childNodes.length ? kv : null))));
      }
    }
    return [
      h('div', { class: 'cells' },
        cell('Recorded', fmtNum(total), 'the last 50 of each resource', total > 0),
        cell('Distinct', fmtNum(items.length), 'same message and resource folded'),
        cell('Resources', fmtNum(new Set(items.map((g) => `${g.latest.side}|${g.latest.resource}`)).size), 'with at least one'),
        cell('Latest', ago(items[0].latest.time, items[0].latest.side) || '–', str(items[0].latest.message))),
      h('div', { class: 'card' }, h('div', { class: 'scroll' }, h('table', null,
        h('thead', null, h('tr', null, h('th', { text: 'Message' }), h('th', { text: 'Resource' }),
          h('th', { class: 'num', text: 'Fiber' }), h('th', { text: 'Trace' }), h('th', { class: 'num', text: 'When' }))),
        h('tbody', null, rows)))),
    ];
  }

  // Estimated quantile from per-bucket counts (the last count is above every bucket).
  function quantile(buckets, counts, total, q) {
    if (!total) return null;
    const target = q * total;
    let cum = 0;
    for (let i = 0; i < counts.length; i++) {
      const c = Number(counts[i]) || 0;
      if (cum + c >= target && c > 0) {
        if (i >= buckets.length) return { text: `>${fmtNum(buckets[buckets.length - 1])}`, bucket: i };
        const lo = i === 0 ? 0 : buckets[i - 1];
        return { text: fmtNum(lo + (buckets[i] - lo) * ((target - cum) / c)), bucket: i };
      }
      cum += c;
    }
    return null;
  }

  function labelPills(labels) {
    const ls = entries(labels).sort(([a], [b]) => a.localeCompare(b));
    if (!ls.length) return h('span', { class: 'muted', text: 'no labels' });
    return h('span', { class: 'labels' }, ls.map(([k, v]) => h('span', { class: 'pill plain' }, `${k}=`, h('b', { text: str(v) }))));
  }

  function distribution(counts, p50) {
    const max = Math.max(1, ...counts.map((c) => Number(c) || 0));
    return h('div', { class: 'dist', title: 'observations per bucket; p50 lit, above the last bucket hatched' },
      counts.map((c, i) => h('i', {
        class: i === counts.length - 1 ? 'over' : p50 && p50.bucket === i ? 'p50' : null,
        style: `height:${Math.max(4, ((Number(c) || 0) / max) * 100).toFixed(0)}%`,
      })));
  }

  function renderMetrics() {
    if (!state.loaded.metrics) return waiting();
    const fams = [];
    for (const side of sidesShown()) {
      for (const f of state.metrics[side]) {
        if (!f) continue;
        const series = list(f.series).filter((s) => matches(f.name, s.labels && s.labels.resource));
        if (series.length) fams.push({ side, f, series });
      }
    }
    if (!fams.length) return empty('No metrics', 'Counters, gauges and histograms from Fx.metrics show up here.');
    return fams.map(({ side, f, series }) => {
      const hist = f.kind === 'histogram';
      const famKey = `fam|${side}|${f.name}`;
      const buckets = list(f.buckets);
      const head = hist ? ['Labels', 'Count', 'Avg', 'p50', 'p95', 'p99', ''] : ['Labels', 'Value'];
      return h('section', { class: 'tray' },
        h('div', { class: 'tray-head' }, h('span', { class: `who ${side}`, title: side }), h('span', { class: 'fam-name', text: f.name }),
          h('span', { class: 'pill plain', text: f.kind }), h('span', { class: 'side-tag', text: side }),
          f.help ? h('span', { class: 'help', text: f.help }) : null),
        h('div', { class: 'card' },
          f.dropped ? h('div', { class: 'note', style: 'margin:10px', text: `${fmtNum(f.dropped)} more series not shown` }) : null,
          h('div', { class: 'scroll' }, h('table', null,
            h('thead', null, h('tr', null, head.map((x, i) => h('th', { class: i ? 'num' : null, text: x })))),
            h('tbody', null, (state.showAll[famKey] ? series : series.slice(0, SERIES_PER_FAMILY)).map((s) => {
              if (!hist) return h('tr', null, h('td', null, labelPills(s.labels)), h('td', { class: 'num', text: fmtNum(s.value) }));
              const counts = list(s.counts);
              const n = Number(s.count) || 0;
              const qs = [0.5, 0.95, 0.99].map((q) => quantile(buckets, counts, n, q));
              return h('tr', null, h('td', null, labelPills(s.labels)),
                h('td', { class: 'num', text: fmtNum(n) }),
                h('td', { class: 'num', text: n && typeof s.sum === 'number' ? fmtNum(s.sum / n) : '–' }),
                qs.map((q) => h('td', { class: 'num', text: q ? q.text : '–' })),
                h('td', null, distribution(counts, qs[0])));
            })))),
          more(famKey, series.length, SERIES_PER_FAMILY, 'series')));
    });
  }

  // Shell ----------------------------------------------------------------------

  const RENDER = { overview: renderOverview, fibers: renderFibers, spans: renderSpans, failures: renderFailures, metrics: renderMetrics };

  function navCount(id) {
    if (id === 'fibers') {
      const n = state.loaded.fibers
        ? sidesShown().reduce((a, side) => a + state.fibers[side].reduce((b, r) => b + (Number(r && r.total) || 0), 0), 0)
        : state.loaded.overview ? liveTotal() : null;
      return n == null ? null : h('span', { class: 'count', text: fmtNum(n) });
    }
    if (id === 'spans' && state.spans.size) return h('span', { class: 'count', text: fmtNum(new Set([...state.spans.values()].map((s) => s.traceId)).size) });
    if (id === 'failures' && state.failures.size) return h('span', { class: 'count bad', text: fmtNum(state.failures.size) });
    if (id === 'metrics' && state.loaded.metrics) {
      const n = sidesShown().reduce((a, side) => a + state.metrics[side].length, 0);
      return h('span', { class: 'count', text: fmtNum(n) });
    }
    return null;
  }

  function renderTabs() {
    tabs.replaceChildren(...VIEWS.map((v) => h('button', {
      type: 'button',
      class: state.view === v.id ? 'active' : null,
      'aria-current': state.view === v.id ? 'page' : null,
      title: v.label,
      onclick: () => setView(v.id),
    }, icon(ICONS[v.id]), h('span', { class: 'label', text: v.label }), navCount(v.id))));
    const view = VIEWS.find((v) => v.id === state.view);
    $('title').textContent = view.label;
    $('subtitle').textContent = view.sub;
    for (const b of $('side').querySelectorAll('button')) b.classList.toggle('active', b.dataset.side === state.side);
  }

  let reveal = false;

  function render() {
    renderTabs();
    const top = main.scrollTop;
    const content = RENDER[state.view]();
    main.replaceChildren(...(Array.isArray(content) ? content.flat(Infinity) : [content]).filter(Boolean));
    main.classList.toggle('reveal', reveal);
    reveal = false;
    main.scrollTop = top;
    renderUpdated();
  }

  function renderUpdated() {
    const live = $('live');
    const stale = state.updated && Date.now() - state.updated > STALE_MS;
    live.classList.toggle('paused', state.paused);
    live.classList.toggle('stale', !state.paused && Boolean(stale));
    $('updated').textContent = state.paused ? 'Paused'
      : !state.updated ? 'Waiting for data'
        : stale ? `No update for ${Math.round((Date.now() - state.updated) / 1000)}s`
          : state.poll > 1500 ? `Live · every ${Math.round(state.poll / 100) / 10}s` : 'Live';
  }

  function setView(view) {
    if (!RENDER[view]) return;
    if (state.view !== view) reveal = true;
    state.view = view;
    post('view', { view });
    main.scrollTop = 0;
    render();
  }

  function setPaused(p) {
    state.paused = p;
    $('pause').classList.toggle('on', p);
    $('pause').textContent = p ? 'Resume' : 'Pause';
  }

  function applyTheme(theme) {
    document.documentElement.dataset.theme = theme;
    $('theme').setAttribute('aria-label', theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
  }

  function open(msg) {
    state = initialState(state);
    if (msg && RENDER[msg.view]) state.view = msg.view;
    if (msg && typeof msg.paused === 'boolean') setPaused(msg.paused);
    reveal = true;
    app.hidden = false;
    render();
  }

  function close() {
    app.hidden = true;
    post('close');
  }

  $('side').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-side]');
    if (!b) return;
    state.side = b.dataset.side;
    render();
  });
  $('filter').addEventListener('input', (e) => { state.filter = e.target.value; render(); });
  $('pause').addEventListener('click', () => {
    setPaused(!state.paused);
    post('pause', { paused: state.paused });
    renderUpdated();
  });
  $('theme').addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    try { localStorage.setItem(THEME_KEY, next); } catch (_) { /* storage can be off */ }
  });
  $('close').addEventListener('click', close);
  window.addEventListener('keydown', (e) => {
    if (app.hidden) return;
    if (e.key === 'Escape') close();
    else if (e.key === '/' && document.activeElement !== $('filter')) {
      e.preventDefault();
      $('filter').focus();
    }
  });
  setInterval(() => { if (!app.hidden) renderUpdated(); }, 1000);

  try {
    const saved = localStorage.getItem(THEME_KEY);
    if (saved === 'light' || saved === 'dark') applyTheme(saved);
  } catch (_) { /* storage can be off */ }

  window.addEventListener('message', (e) => {
    const msg = e.data;
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'open') open(msg);
    else if (msg.type === 'close') app.hidden = true;
    else if (msg.type === 'data') onData(msg.side, msg.view, msg.data, msg.now, msg.poll);
    else if (msg.type === 'view' && RENDER[msg.view]) {
      if (state.view !== msg.view) reveal = true;
      state.view = msg.view;
      main.scrollTop = 0;
      render();
    } else if (msg.type === 'probe') {
      post('probe', {
        open: !app.hidden,
        view: state.view,
        rows: main.querySelectorAll('tbody tr, .wf-row, .trace-item').length,
        text: main.textContent.slice(0, 4000),
        errors: pageErrors.slice(-5),
      });
    }
  });
})();

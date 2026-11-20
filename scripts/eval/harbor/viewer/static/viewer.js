'use strict';
// Harbor bench viewer. Every value from the API reaches the page through
// textContent or CSSOM properties, never as markup.

const STATUS = {
  pass: '通过', partial: '部分通过', fail: '失败', timeout: 'agent 超时',
  invalid: '无效', running: '运行中',
};
const ORDER = ['pass', 'partial', 'fail', 'timeout', 'invalid', 'running'];
const PHASES = [['environment', '环境'], ['setup', '安装'], ['agent', 'agent'], ['verifier', '判分']];
const REFRESH_S = 10;

const state = { auto: true, countdown: REFRESH_S, timer: null, busy: false, live: false,
  jobFilter: 'all', jobSearch: '', suite: null, category: 'all', sort: { key: 'task', dir: 1 }, selected: new Set(),
  scope: null, batchPick: null, batchSuite: 'all', taskFilter: 'all', taskSearch: '' };

// ------------------------------------------------------------ DOM helpers
function h(tag, props, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') el.className = value;
    else if (key === 'text') el.textContent = value;
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else if (key === 'width') el.style.width = value;
    else if (key === 'height') el.style.height = value;
    else el.setAttribute(key, value === true ? '' : String(value));
  }
  for (const child of children.flat()) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}
const $ = (sel) => document.querySelector(sel);

// ------------------------------------------------------------ formatting
const dash = () => h('span', { class: 'na', text: '—' });
function int(n) { return n === null || n === undefined ? '—' : Math.round(n).toLocaleString('en-US'); }
function compact(n) {
  if (n === null || n === undefined) return '—';
  if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'k';
  return String(Math.round(n));
}
function pct(x, digits = 0) { return x === null || x === undefined ? '—' : (x * 100).toFixed(digits) + '%'; }
function usd(x) { return x === null || x === undefined ? '—' : '$' + x.toFixed(x < 1 ? 3 : 2); }
function dur(s) {
  if (s === null || s === undefined) return '—';
  const t = Math.round(s);
  if (t < 60) return t + 's';
  if (t < 3600) return Math.floor(t / 60) + 'm' + String(t % 60).padStart(2, '0') + 's';
  return Math.floor(t / 3600) + 'h' + String(Math.floor((t % 3600) / 60)).padStart(2, '0') + 'm';
}
function when(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return isNaN(d) ? '—' : d.toLocaleString('zh-CN', { hour12: false, month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
}
function badge(status, extra) {
  return h('span', { class: 'badge s-' + status, title: extra || null, text: STATUS[status] || status });
}
function outcomeBar(counts, total, big) {
  const bar = h('div', { class: 'outcome-bar' + (big ? ' big' : ''), role: 'img',
    'aria-label': ORDER.filter((s) => counts[s]).map((s) => `${STATUS[s]} ${counts[s]}`).join('，') || '无数据' });
  if (total > 0) for (const s of ORDER) if (counts[s]) bar.append(h('span', { class: 'seg s-' + s, width: (100 * counts[s] / total) + '%', title: `${STATUS[s]} ${counts[s]}` }));
  return bar;
}
function legend(counts) {
  return h('div', { class: 'legend' }, ORDER.filter((s) => counts[s]).map((s) => h('span', { class: 'badge s-' + s }, STATUS[s], h('b', { text: counts[s] }))));
}
function metric(label, value, note, lead, extra) {
  return h('div', { class: 'metric' + (lead ? ' lead' : '') }, h('span', { text: label }), h('strong', { text: value }), note ? h('small', { text: note }) : null, extra || null);
}
function tps(value) { return value === null || value === undefined ? '未采集' : value.toFixed(1) + ' tok/s'; }
function ttft(value) { return value === null || value === undefined ? '未采集' : (value / 1000).toFixed(2) + 's'; }
function measurementCards(s) {
  return [
    metric('一次性完成率', pct(s.one_shot_pass_rate), `${s.counts.pass} 通过 / ${s.valid || 0} 有效`, true),
    metric('首轮满分率', pct(s.first_pass_rate), `${s.first_passed || 0} 首次满分 / ${s.first_valid || 0} 首次有效 · 无效 ${s.first_invalid || 0}`),
    metric('任务总 Token', compact(s.total_tokens), `输入含缓存 + 输出 · ${s.token_trials || 0}/${s.trials || 0} 次有数据${s.partial_token_trials ? ' · 含部分记录' : ''}`),
    metric('初始 Token（均值）', compact(s.initial_input_tokens_mean), `首个请求完整输入 · ${s.initial_token_trials || 0} 次有数据`, false,
      s.initial_composition_mean ? stackBar(compositionSegments(s.initial_composition_mean), true) : null),
    metric('TPS（生成）', tps(s.tps), `${s.profiled_requests || 0}/${s.requests || 0} 个请求有计时与输出用量 · 不含工具执行`),
    metric('TTFT（均值）', ttft(s.ttft_ms), `P50 ${ttft(s.ttft_p50_ms)} · P95 ${ttft(s.ttft_p95_ms)} · ${s.ttft_samples_ms?.length || 0} 个请求`),
    metric('估算成本', usd(s.cost_usd), `metacodes 价目表估算 · ${s.cost_trials || 0}/${s.trials || 0} 次有价格数据`),
  ];
}
function panel(title, sub, body, actions) {
  return h('section', { class: 'panel' },
    h('div', { class: 'panel-heading' }, h('h2', {}, title, sub ? h('small', { text: sub }) : null), actions || null),
    body);
}
function link(href, text) { return h('a', { href, text }); }

// ------------------------------------------------------------ data
async function api(path, payload) {
  const res = await fetch(path, { cache: 'no-store', ...(payload === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
  }) });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || res.statusText);
  return body;
}
function setConnection(ok, message) {
  const c = $('#connection');
  c.classList.toggle('failed', !ok);
  c.lastChild.textContent = ok ? '已连接' : '连接失败';
  const err = $('#error');
  err.hidden = ok;
  if (!ok) err.textContent = message;
}

// ------------------------------------------------------------ routing
function route() {
  const parts = location.hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
  if (parts[0] === 'new') return { view: 'new' };
  if (parts[0] === 'settings') return { view: 'settings' };
  if (parts[0] === 'providers') return { view: 'providers' };
  if (parts[0] === 'run' && parts[1]) return { view: 'run', name: parts[1] };
  if (parts[0] === 'batch' && parts[1] && parts[2] === 'task' && parts[3] && parts[4]) return { view: 'task', batch: parts[1], job: parts[3], task: parts[4], trial: parts[5] || null };
  if (parts[0] === 'batch' && parts[1]) return { view: 'batch', batch: parts[1] };
  if (parts[0] === 'job' && parts[1] && parts[2]) return { view: 'trial', job: parts[1], trial: parts[2] };
  if (parts[0] === 'job' && parts[1]) return { view: 'job', job: parts[1] };
  if (parts[0] === 'compare') return { view: 'compare', jobs: (parts[1] || '').split(',').filter(Boolean) };
  return { view: 'overview' };
}
function crumbs(items) {
  const box = $('#crumbs');
  box.replaceChildren(...items.flatMap((item, i) => [i ? h('span', { text: '/' }) : null, item.href ? link(item.href, item.text) : h('span', { text: item.text })]).filter(Boolean));
}
function navCurrent(name) {
  for (const a of document.querySelectorAll('.rail nav a')) a.toggleAttribute('aria-current', a.dataset.nav === name);
  for (const a of document.querySelectorAll('.rail nav a[aria-current]')) a.setAttribute('aria-current', 'page');
}

async function render() {
  if (state.busy) return;
  state.busy = true;
  const r = route();
  try {
    let node;
    if (r.view === 'new') node = await renderNewBatch();
    else if (r.view === 'settings') node = await renderSettings();
    else if (r.view === 'providers') node = await renderProviders();
    else if (r.view === 'run') node = await renderRun(r.name);
    else if (r.view === 'overview') node = await renderOverview();
    else if (r.view === 'batch') node = await renderBatch(r.batch);
    else if (r.view === 'task') node = await renderBatchTask(r.batch, r.job, r.task, r.trial);
    else if (r.view === 'job') node = await renderJob(r.job);
    else if (r.view === 'trial') node = await renderTrial(r.job, r.trial);
    else node = await renderCompare(r.jobs);
    // Keep open <details> and scroll position across a live refresh.
    const open = new Set([...document.querySelectorAll('#app details[open]')].map((d) => d.dataset.key));
    $('#app').replaceChildren(node);
    for (const d of document.querySelectorAll('#app details')) if (open.has(d.dataset.key)) d.open = true;
    setConnection(true);
    $('#updated').textContent = '更新于 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false });
  } catch (e) {
    setConnection(false, '读取失败：' + e.message + '（保留上一次的数据）');
  } finally {
    state.busy = false;
  }
}

// ------------------------------------------------------------ context composition
const PARTS = [['system', '系统提示'], ['tools', '工具定义'], ['user', '任务 / 用户消息'], ['assistant', '模型历史输出'], ['tool_results', '工具结果']];
function partsTotal(c) { return PARTS.reduce((acc, [k]) => acc + (c[k] || 0), 0); }
function stackBar(segments, mini) {
  const total = segments.reduce((acc, [, v]) => acc + (v || 0), 0);
  return h('div', { class: 'stack-bar' + (mini ? ' mini' : ''), role: 'img', 'aria-label': segments.filter(([, v]) => v).map(([, v, l]) => `${l} ${compact(v)}`).join('，') },
    total > 0 ? segments.map(([cls, v, l]) => v ? h('span', { class: cls, width: (100 * v / total) + '%', title: `${l} ${compact(v)}（${pct(v / total)}）` }) : null) : null);
}
function compositionSegments(c) { return PARTS.map(([k, l]) => ['c-' + k, c[k] || 0, l]); }
function compositionPanel(summary, scopeText) {
  const c = summary.initial_composition_mean;
  const body = c ? h('div', { class: 'panel-body' },
    stackBar(compositionSegments(c)),
    h('div', { class: 'legend keys' }, PARTS.map(([k, l]) => h('span', { class: 'key' }, h('i', { class: 'c-' + k }), `${l} ${compact(c[k])} · ${pct((c[k] || 0) / Math.max(1, partsTotal(c)))}`))),
    h('p', { class: 'muted', text: `首个模型请求的完整输入按各部分字节占比分摊实测输入 Token · ${summary.initial_composition_trials} 次有组成数据 / ${summary.initial_token_trials || 0} 次有初始 Token` }))
    : h('div', { class: 'empty', text: '还没有上下文组成数据：计时代理从本版本起记录每个请求中系统提示、工具定义、消息和工具结果的字节数，新运行会自动出现。' });
  return panel('初始上下文窗口组成', scopeText || '均值', body);
}

// ------------------------------------------------------------ overview
const BATCH_STATUS = { queued: '排队中', running: '运行中', cancelling: '正在停止', finished: '已完成', cancelled: '已停止' };
const ITEM_STATUS = { pending: '等待', running: '运行中', finished: '完成', failed: '执行失败', cancelled: '已停止', interrupted: '中断', skipped: '跳过' };
const batchActive = (b) => ['queued', 'running', 'cancelling'].includes(b.status);
const batchName = (b) => b.name || b.id;

async function renderOverview() {
  navCurrent('overview');
  $('#title').textContent = 'Bench 看板';
  let body = await api('/api/jobs?batch=' + encodeURIComponent(state.scope || 'all'));
  if (!state.scope) {
    state.scope = body.batches.length ? body.batches[0].id : 'all';
    if (state.scope !== 'all') body = await api('/api/jobs?batch=' + encodeURIComponent(state.scope));
  }
  const { jobs, runs = [], summary, batches = [] } = body;
  if (!['all', 'none'].includes(state.scope) && !batches.some((b) => b.id === state.scope)) {
    state.scope = 'all';
    return renderOverview();
  }
  const current = batches.find((b) => b.id === state.scope);
  crumbs([{ text: current ? '批次 ' + batchName(current) : state.scope === 'none' ? '未分批的作业' : '所有作业' }]);
  state.live = jobs.some((j) => j.running) || batches.some(batchActive) || runs.some((r) => ['queued', 'starting', 'running', 'cancelling'].includes(r.status));

  const select = h('select', { 'aria-label': '按批次查看', onchange: () => { state.scope = select.value; state.selected.clear(); render(); } },
    batches.map((b) => h('option', { value: b.id, selected: b.id === state.scope }, `${batchName(b)} · ${b.metacodes?.label || '—'} · ${BATCH_STATUS[b.status] || b.status}`)),
    h('option', { value: 'all', selected: state.scope === 'all' }, `全部作业（${body.job_total}）`),
    h('option', { value: 'none', selected: state.scope === 'none' }, '未分批的作业'));
  const scopeBar = h('div', { class: 'scope' }, h('b', { text: '数据范围' }), select,
    current ? h('span', { class: 'meta', text: `metacodes ${current.metacodes?.label || '—'} · ${current.model || '—'} · ${current.items.length} 个评测集 · ${current.progress.done}/${current.progress.planned} trial · ${BATCH_STATUS[current.status] || current.status}` }) : null,
    current ? link('#/batch/' + encodeURIComponent(current.id), '查看批次详情 →') : null);

  const all = { trials: 0, running: 0, invalid: 0 };
  for (const j of jobs) { all.trials += j.summary.trials; all.running += j.summary.counts.running; all.invalid += j.summary.counts.invalid; }
  const metrics = h('section', { class: 'metrics' }, measurementCards(summary),
    metric('作业', String(jobs.length), jobs.filter((j) => j.running).length + ' 个运行中'),
    metric('trial', String(all.trials), all.running + ' 个运行中'),
    metric('无效', String(all.invalid), '基础设施原因，不计入通过率'));

  const batchRows = batches.map((b) => h('tr', { class: 'link', onclick: () => { location.hash = '#/batch/' + encodeURIComponent(b.id); } },
    h('td', {}, h('span', { text: batchName(b) }), h('span', { class: 'sub mono', text: b.name ? b.id : when(b.created_at) })),
    h('td', {}, h('span', { class: 'mono', text: b.metacodes?.label || '—' }), h('span', { class: 'sub mono', text: b.metacodes?.digest ? '冻结 ' + b.metacodes.digest : '' })),
    h('td', { text: b.model || '—' }),
    h('td', {}, h('span', { text: b.items.map((i) => i.suite_name || i.suite).join('、') }), h('span', { class: 'sub', text: `${b.items.length} 个评测集` })),
    h('td', {}, h('span', { text: BATCH_STATUS[b.status] || b.status }), h('span', { class: 'sub', text: b.items.filter((i) => ['finished', 'failed', 'cancelled', 'interrupted', 'skipped'].includes(i.status)).length + ' / ' + b.items.length + ' 数据集结束' })),
    h('td', {}, h('span', { class: 'num', text: `${b.progress.done} / ${b.progress.planned}` }), h('div', { class: 'track' }, h('span', { width: (b.progress.planned ? 100 * b.progress.done / b.progress.planned : 0) + '%' }))),
    h('td', {}, outcomeBar(b.summary.counts, b.summary.trials || 0)),
    h('td', { class: 'num', text: pct(b.summary.first_pass_rate) }),
    h('td', { class: 'num', text: compact(b.summary.total_tokens) }),
    h('td', { class: 'num', text: dur(b.wall_s) }),
    h('td', { class: 'num', text: when(b.created_at) })));
  const batchPanel = panel('批次', `${batches.length} 个 · 每个批次冻结一个 metacodes 版本`, h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['批次', 'metacodes 版本', '模型', '评测集', '状态', '进度', '结局分布', '首次满分率', '总 Token', '用时', '创建'].map((t, i) => h('th', { class: i >= 7 ? 'num' : null, text: t })))),
    h('tbody', {}, batchRows.length ? batchRows : h('tr', {}, h('td', { colspan: 11, class: 'empty' }, '还没有批次。', link('#/new', '新建一个批次'), '：选择一个 metacodes 版本和多个评测集。'))))),
  h('a', { class: 'button', href: '#/new', text: '新建批次' }));

  const compareBtn = h('button', { class: 'button primary', type: 'button', disabled: state.selected.size < 2 || null,
    onclick: () => { location.hash = '#/compare/' + [...state.selected].map(encodeURIComponent).join(','); } }, `对比所选 (${state.selected.size})`);
  const present = new Map();
  for (const j of jobs) present.set(j.category || 'none', j.category_name || '未分类');
  if (state.category !== 'all' && !present.has(state.category)) state.category = 'all';
  const filter = present.size > 1 || state.category !== 'all' ? h('div', { class: 'chips', role: 'group', 'aria-label': '按类别筛选' },
    [['all', '全部类别'], ...present].map(([id, name]) => h('button', { type: 'button', class: 'chip', 'aria-pressed': String(state.category === id),
      onclick: () => { state.category = id; render(); } }, name))) : null;
  const visible = state.category === 'all' ? jobs : jobs.filter((j) => (j.category || 'none') === state.category);
  const rows = visible.map((j) => {
    const s = j.summary;
    const done = s.trials - s.counts.running;
    const box = h('input', { type: 'checkbox', 'aria-label': '选择 ' + j.name, onclick: (e) => e.stopPropagation(),
      onchange: (e) => { e.target.checked ? state.selected.add(j.name) : state.selected.delete(j.name); compareBtn.disabled = state.selected.size < 2; compareBtn.textContent = `对比所选 (${state.selected.size})`; } });
    box.checked = state.selected.has(j.name);
    return h('tr', { class: 'link', onclick: () => { location.hash = '#/job/' + encodeURIComponent(j.name); } },
      h('td', {}, box),
      h('td', {}, h('span', { text: j.name }), h('span', { class: 'sub', text: [j.category_name, j.suite_name || j.dataset, j.metacodes?.label ? 'metacodes ' + j.metacodes.label : null].filter(Boolean).join(' · ') + (j.running ? ' · 运行中' : '') })),
      h('td', { text: j.model || '—' }),
      h('td', {}, h('span', { class: 'num', text: `${done} / ${j.planned}` }), h('div', { class: 'track' }, h('span', { width: (j.planned ? 100 * done / j.planned : 0) + '%' }))),
      h('td', {}, outcomeBar(s.counts, s.trials)),
      h('td', { class: 'num', text: pct(s.first_pass_rate) }, h('span', { class: 'sub', text: `${s.first_passed}/${s.first_valid} 首次有效` })),
      h('td', { class: 'num', text: String(s.counts.invalid) }),
      h('td', { class: 'num', text: compact(s.total_tokens) }, h('span', { class: 'sub', text: '缓存 ' + pct(s.input_tokens ? s.cache_tokens / s.input_tokens : null) })),
      h('td', { class: 'num', text: compact(s.initial_input_tokens_mean) }),
      h('td', { class: 'num', text: tps(s.tps) }),
      h('td', { class: 'num', text: ttft(s.ttft_ms) }),
      h('td', { class: 'num', text: usd(s.cost_usd) }),
      h('td', { class: 'num', text: dur(j.wall_s) }),
      h('td', { class: 'num', text: when(j.started_at) }));
  });
  const table = h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['', '作业', '模型', '进度', '结局分布', '首次满分率', '无效', '任务总 Token', '初始 Token（均值）', 'TPS', 'TTFT', '估算成本', '用时', '开始'].map((t, i) => h('th', { class: i >= 5 ? 'num' : null, text: t })))),
    h('tbody', {}, rows.length ? rows : h('tr', {}, h('td', { colspan: 14, class: 'empty', text: jobs.length ? '该类别下没有作业' : '这个范围内还没有作业' })))));
  const loose = runs.filter((r) => !r.batch);
  const launches = state.scope !== 'all' && state.scope !== 'none' || !loose.length ? null : panel('单独发起的评测', `${loose.length} 次（未归入批次）`,
    h('div', { class: 'launches' }, loose.map((r) => h('a', { class: 'launch', href: '#/run/' + r.name },
      h('b', { text: r.name }), h('span', { class: 'muted', text: [r.suite_name, r.model].filter(Boolean).join(' · ') }),
      h('span', { text: RUN_STATUS[r.status] || r.status })))));
  const jobsTitle = current ? '本批次的作业（每个评测集一个）' : '作业';
  return h('div', {}, scopeBar, metrics, compositionPanel(summary, current ? '本批次均值' : '均值'), batchPanel,
    panel(jobsTitle, state.category === 'all' ? `${jobs.length} 个` : `${visible.length} / ${jobs.length} 个`, h('div', {}, filter, table), compareBtn), launches);
}

// ------------------------------------------------------------ batch
async function renderBatch(id) {
  navCurrent('overview');
  const b = await api('/api/batch?id=' + encodeURIComponent(id));
  state.live = batchActive(b);
  $('#title').textContent = batchName(b);
  crumbs([{ text: '看板', href: '#/' }, { text: '批次 ' + b.id }]);
  const s = b.summary;
  const metrics = h('section', { class: 'metrics' }, measurementCards(s),
    metric('进度', `${b.progress.done} / ${b.progress.planned}`, `${BATCH_STATUS[b.status] || b.status} · ${dur(b.wall_s)}`),
    metric('评测集', String(b.items.length), b.items.filter((i) => i.status === 'finished').length + ' 个完成'),
    metric('无效', String(s.counts.invalid), '基础设施原因，不计入通过率'));

  const stop = batchActive(b) && b.can_run ? h('button', { type: 'button', class: 'button', onclick: async (event) => {
    event.currentTarget.disabled = true;
    try { await api('/api/batch/cancel', { id: b.id }); state.countdown = 1; }
    catch (error) { event.currentTarget.disabled = false; setConnection(false, error.message); }
  } }, '停止批次') : null;
  const remove = !batchActive(b) && b.can_run ? h('button', { type: 'button', class: 'button', onclick: async (event) => {
    const button = event.currentTarget;
    if (!confirm(`删除批次 ${batchName(b)}？它的运行记录、日志和评测结果都会从工作台和数据库删除，不能恢复。`)) return;
    button.disabled = true;
    try { await api('/api/batch/delete', { id: b.id }); location.hash = '#/'; }
    catch (error) { button.disabled = false; setConnection(false, error.message); }
  } }, '删除批次') : null;
  const m = b.metacodes || {};
  const info = h('div', { class: 'panel-body' }, h('dl', { class: 'kv' },
    h('dt', { text: 'metacodes 版本' }), h('dd', {}, h('b', { class: 'mono', text: m.label || '—' }), m.release ? h('span', { class: 'muted', text: ' · 发行包 ' + m.release }) : null),
    h('dt', { text: '冻结' }), h('dd', { class: 'mono', text: m.digest ? `内容摘要 ${m.digest}${m.commit ? ' · commit ' + m.commit : ''}` : '—' }),
    h('dt', { text: '二进制 SHA-256' }), h('dd', { class: 'mono', text: m.binary_sha256 || '—' }),
    h('dt', { text: '冻结副本' }), h('dd', { class: 'mono', text: m.bundle || '—' }),
    h('dt', { text: '模型' }), h('dd', { text: b.model || '—' }),
    h('dt', { text: '执行机器' }), h('dd', { text: b.executor || '—' }),
    h('dt', { text: '每题次数 / 并发' }), h('dd', { text: `${b.attempts} 次 · 并发 ${b.concurrency}（不超过各评测集上限）` }),
    h('dt', { text: '时间' }), h('dd', { text: `创建 ${when(b.created_at)} · 开始 ${when(b.started_at)} · 结束 ${when(b.finished_at)}` })),
    h('p', { class: 'muted', text: '批次创建时复制并锁定这个 metacodes 发行包；之后重新构建或切换工作台的版本不影响本批次。各评测集依次运行，每个评测集一个作业。' }));

  const itemRows = b.items.map((item) => {
    const j = item.job; const js = j?.summary;
    return h('tr', { class: j ? 'link' : null, onclick: j ? () => { location.hash = '#/job/' + encodeURIComponent(j.name); } : null },
      h('td', {}, h('span', { text: item.suite_name || item.suite }), h('span', { class: 'sub', text: [item.category_name, `${item.tasks.length} 道题`].filter(Boolean).join(' · ') })),
      h('td', {}, h('span', { text: ITEM_STATUS[item.status] || item.status }), item.error ? h('span', { class: 'sub flag', text: item.error }) : null),
      h('td', { class: 'num', text: js ? `${js.trials - js.counts.running} / ${j.planned}` : `0 / ${item.tasks.length * b.attempts}` }),
      h('td', {}, js ? outcomeBar(js.counts, js.trials) : dash()),
      h('td', { class: 'num', text: js ? pct(js.first_pass_rate) : '—' }),
      h('td', { class: 'num', text: js ? compact(js.total_tokens) : '—' }),
      h('td', { class: 'num', text: js ? compact(js.initial_input_tokens_mean) : '—' }),
      h('td', { class: 'num', text: j ? dur(j.wall_s) : '—' }),
      h('td', { class: 'mono', text: item.run || '—' }));
  });
  const items = panel('评测集', `${b.items.length} 个 · 依次运行`, h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['评测集', '状态', '完成', '结局分布', '首次满分率', '总 Token', '初始 Token（均值）', '用时', '作业'].map((t, i) => h('th', { class: i >= 2 && i <= 7 && i !== 3 ? 'num' : null, text: t })))),
    h('tbody', {}, itemRows))));

  // Per task: every dataset's tasks, attempts in order.
  const suitesPresent = [...new Map(b.tasks.map((t) => [t.suite, t.suite_name || t.suite]))];
  if (state.batchSuite && !suitesPresent.some(([id]) => id === state.batchSuite)) state.batchSuite = 'all';
  const chips = suitesPresent.length > 1 ? h('div', { class: 'chips', role: 'group', 'aria-label': '按评测集筛选' },
    [['all', '全部评测集'], ...suitesPresent].map(([sid, name]) => h('button', { type: 'button', class: 'chip', 'aria-pressed': String((state.batchSuite || 'all') === sid),
      onclick: () => { state.batchSuite = sid; render(); } }, name))) : null;
  const firstFilter = h('div', { class: 'filters' }, ['all', ...ORDER].map((key) => h('button', {
    type: 'button', class: (state.taskFilter || 'all') === key ? 'on' : null, onclick: () => { state.taskFilter = key; render(); },
  }, key === 'all' ? '全部' : '首次' + STATUS[key])));
  const search = h('input', { type: 'search', placeholder: '搜索任务', value: state.taskSearch || '', 'aria-label': '搜索任务',
    oninput: (e) => { state.taskSearch = e.target.value; drawTasks(); } });
  const tbody = h('tbody', {});
  function drawTasks() {
    const q = (state.taskSearch || '').trim().toLowerCase();
    const shown = b.tasks.filter((t) => (state.batchSuite || 'all') === 'all' || t.suite === state.batchSuite)
      .filter((t) => (state.taskFilter || 'all') === 'all' || t.first_status === state.taskFilter)
      .filter((t) => !q || t.task.toLowerCase().includes(q));
    tbody.replaceChildren(...(shown.length ? shown.map((t) => {
      const href = t.job ? `#/batch/${encodeURIComponent(b.id)}/task/${encodeURIComponent(t.job)}/${encodeURIComponent(t.task)}` : null;
      return h('tr', { class: href ? 'link' : null, onclick: href ? () => { location.hash = href; } : null },
        h('td', {}, h('span', { class: 'mono', text: t.task })),
        h('td', { text: t.suite_name || t.suite }),
        h('td', {}, t.attempts.length ? h('span', { class: 'dots' }, t.attempts.map((a) => h('a', { href: href + '/' + encodeURIComponent(a.trial), onclick: (e) => e.stopPropagation(), title: `第 ${a.attempt_number} 次 · ${STATUS[a.status] || a.status}${a.cause ? ' · ' + a.cause : ''}` }, badge(a.status)))) : h('span', { class: 'muted', text: '等待运行' })),
        h('td', { class: 'num', text: t.attempts.length ? `${t.passed} / ${t.valid}` : '—' }),
        h('td', { class: 'num', text: compact(t.mean_total_tokens) }),
        h('td', { class: 'num', text: compact(t.mean_initial_input_tokens) }),
        h('td', { class: 'num', text: t.mean_turns === null || t.mean_turns === undefined ? '—' : t.mean_turns.toFixed(1) }),
        h('td', { class: 'num', text: t.mean_tool_calls === null || t.mean_tool_calls === undefined ? '—' : t.mean_tool_calls.toFixed(1) }),
        h('td', { class: 'num', text: dur(t.mean_elapsed_s) }));
    }) : [h('tr', {}, h('td', { colspan: 9, class: 'empty', text: '没有符合条件的任务' }))]));
  }
  drawTasks();
  const tasks = panel('逐任务', `${b.tasks.length} 道 · 点开看每次尝试的轨迹、Token 分布和耗时`, h('div', {}, chips,
    h('div', { class: 'panel-body toolbar' }, firstFilter, search),
    h('div', { class: 'table-scroll' }, h('table', {}, h('thead', {}, h('tr', {}, ['任务', '评测集', '各次结局', '通过 / 有效', '平均总 Token', '平均初始 Token', '平均轮数', '平均工具调用', '平均用时'].map((t, i) => h('th', { class: i >= 3 ? 'num' : null, text: t })))), tbody))));
  return h('div', {}, metrics, panel('批次信息', BATCH_STATUS[b.status] || b.status, info, stop || remove), compositionPanel(s, '本批次均值'), items, tasks);
}

async function renderBatchTask(batchId, jobName, taskName, trialName) {
  navCurrent('overview');
  const b = await api('/api/batch?id=' + encodeURIComponent(batchId));
  const ordered = b.tasks.filter((t) => t.job);
  const index = ordered.findIndex((t) => t.job === jobName && t.task === taskName);
  const group = ordered[index];
  if (!group) throw new Error('批次中没有这个任务');
  const chosen = group.attempts.find((a) => a.trial === trialName) || group.attempts[0];
  $('#title').textContent = taskName;
  crumbs([{ text: '看板', href: '#/' }, { text: '批次 ' + batchName(b), href: '#/batch/' + encodeURIComponent(b.id) },
    { text: group.suite_name || group.suite }, { text: taskName }]);
  const taskHref = (t) => `#/batch/${encodeURIComponent(b.id)}/task/${encodeURIComponent(t.job)}/${encodeURIComponent(t.task)}`;
  const prev = ordered[index - 1]; const next = ordered[index + 1];
  const nav = h('div', { class: 'header-actions' },
    h('span', { class: 'muted num', text: `${index + 1} / ${ordered.length}` }),
    prev ? h('a', { class: 'button', href: taskHref(prev), title: prev.task }, '← 上一个任务') : h('button', { class: 'button', type: 'button', disabled: true }, '← 上一个任务'),
    next ? h('a', { class: 'button', href: taskHref(next), title: next.task }, '下一个任务 →') : h('button', { class: 'button', type: 'button', disabled: true }, '下一个任务 →'));
  const cards = h('div', { class: 'panel-body attempts' }, group.attempts.map((a) => h('a', {
    class: 'attempt', href: taskHref(group) + '/' + encodeURIComponent(a.trial), 'aria-pressed': String(chosen && a.trial === chosen.trial) },
    h('span', {}, `第 ${a.attempt_number} 次 `, badge(a.status, a.cause)),
    h('span', { class: 'sub', text: `${compact(a.total_tokens)} tok · 初始 ${compact(a.initial_input_tokens)} · ${dur(a.elapsed_s)}` }),
    h('span', { class: 'sub', text: `${int(a.turns)} 轮 · ${int(a.tool_calls)} 次工具 · ${a.tests ? a.tests.passed + '/' + a.tests.total + ' 测试' : 'reward ' + (a.reward ?? '—')}` }))));
  const maxTokens = Math.max(1, ...group.attempts.map((a) => a.total_tokens || 0));
  const maxTime = Math.max(1, ...group.attempts.map((a) => a.elapsed_s || 0));
  const compare = group.attempts.length > 1 ? h('div', { class: 'panel-body split' }, group.attempts.map((a) => h('div', { class: 'split-row' },
    h('span', { text: `第 ${a.attempt_number} 次 · ${STATUS[a.status] || a.status}` }),
    h('div', {}, h('div', { class: 'stack-bar', title: `总 Token ${int(a.total_tokens)}` }, h('span', { class: 't-input', width: (100 * (a.total_tokens || 0) / maxTokens) + '%' })),
      h('div', { class: 'stack-bar mini', title: `用时 ${dur(a.elapsed_s)}` }, h('span', { class: 't-other', width: (100 * (a.elapsed_s || 0) / maxTime) + '%' }))),
    h('span', { class: 'num muted', text: `${compact(a.total_tokens)} · ${dur(a.elapsed_s)}` })))) : null;
  const parts = [panel('各次尝试', `${group.attempts.length} 次 · 通过 ${group.passed} / 有效 ${group.valid}`, h('div', {}, cards, compare), nav)];
  if (chosen) {
    const t = await api(`/api/trial?job=${encodeURIComponent(jobName)}&trial=${encodeURIComponent(chosen.trial)}`);
    state.live = t.row.status === 'running' || batchActive(b);
    parts.push(...trialBody(t));
  } else {
    state.live = batchActive(b);
  }
  return h('div', {}, parts);
}

// ------------------------------------------------------------ run workbench
const SETUP_STATUS = { running: '进行中', ok: '已就绪', done: '已完成', planned: '将执行', manual: '需要你操作',
  failed: '失败', skipped: '跳过' };
const SETUP_RESULT = { running: '进行中', ready: '已就绪', planned: '预演完成', needs_user: '还有需要你操作的步骤',
  failed: '有步骤失败', interrupted: '已中断' };
const RUN_STATUS = { queued: '等待启动', starting: '准备环境', running: '运行中',
  cancelling: '正在停止', cancelled: '已停止', finished: '运行完成', failed: '执行失败', interrupted: '执行中断' };

const RUNNERS = { 'harbor-registry': 'Harbor 注册表', 'harbor-local': '本地生成数据集', workbuddy: 'WorkBuddy' };
// The LLM judge that scores a suite/run: model id and how it is reached.
const judgeText = (j) => '评委 ' + j.model + (j.via === 'metask' ? '（Metask 网关）' : j.via === 'host_env' ? '（执行机器环境变量）' : '');

async function renderNewBatch() {
  state.live = false;
  navCurrent('new');
  $('#title').textContent = '新建批次';
  crumbs([{ text: '看板', href: '#/' }, { text: '冻结一个 metacodes 版本，选择多个评测集' }]);
  const c = await api('/api/workbench');
  const suites = c.suites || [];
  const byId = new Map(suites.map((s) => [s.id, s]));
  // Selected suites, in the order picked: id -> {tasks, defaults, selected, error, loaded}.
  if (!state.batchPick) state.batchPick = new Map();
  for (const id of [...state.batchPick.keys()]) if (!byId.has(id)) state.batchPick.delete(id);
  if (!state.batchPick.size && byId.has(c.default_suite)) state.batchPick.set(c.default_suite, null);
  const executorsList = c.executors || [];
  if (!executorsList.some((e) => e.name === state.executor)) state.executor = c.default_executor;
  const selectedExecutor = () => executorsList.find((e) => e.name === state.executor) || { reasons: [], ready: true };
  const comboReasons = (s) => ((s.executors || {})[state.executor] || s).reasons || [];
  const comboReady = (s) => !comboReasons(s).length;
  const form = h('form', { class: 'run-form' });

  const executor = h('select', { name: 'executor', onchange: () => {
    state.executor = executor.value;
    for (const id of state.batchPick.keys()) { state.batchPick.set(id, null); loadTasks(id); }
    drawNotes(); drawPicker(); drawBoxes(); syncSubmit();
  } }, executorsList.map((e) => h('option', { value: e.name, selected: e.name === state.executor },
    e.label + (e.ready ? '' : ' · 待配置'))));
  const bundles = c.bundles || [];
  const bundle = h('select', { name: 'bundle' }, bundles.map((b) => h('option', { value: b.id, selected: b.current },
    `${b.label}${b.current ? '（当前配置）' : ''}`)));
  const name = h('input', { name: 'name', type: 'text', maxlength: 80, placeholder: '例如：v0.12 回归 · DeepSeek' });
  const picker = h('div', { class: 'suite-picker' });
  const boxes = h('div', { class: 'stack' });
  const model = h('select', { name: 'model', required: true },
    (c.models || []).map((m) => h('option', { value: m.id, selected: m.id === c.default_model }, m.label)));
  const runDefaults = c.defaults || { attempts: 4, concurrency: 10 };
  const attempts = h('input', { name: 'attempts', type: 'number', inputmode: 'numeric', value: runDefaults.attempts, min: 1, max: 5, step: 1, required: true });
  const concurrency = h('input', { name: 'concurrency', type: 'number', inputmode: 'numeric', value: runDefaults.concurrency, min: 1, max: 16, step: 1, required: true });
  const feedback = h('div', { role: 'status', class: 'form-feedback' });
  const submit = h('button', { type: 'submit', class: 'button primary', disabled: true }, '创建批次');

  function setupReasons() {
    const harbor = [...state.batchPick.keys()].some((id) => (byId.get(id) || {}).runner !== 'workbuddy');
    return [...(c.global_reasons || []), ...(harbor ? (c.harbor_reasons || []) : []),
      ...(harbor ? (selectedExecutor().reasons || []) : [])];
  }
  function syncSubmit() {
    const picked = [...state.batchPick.entries()];
    const total = picked.reduce((acc, [, e]) => acc + (e ? e.selected.size : 0), 0);
    const problems = picked.filter(([id, e]) => !comboReady(byId.get(id)) || !e || !e.selected.size || e.selected.size > byId.get(id).max_tasks);
    submit.disabled = !picked.length || problems.length > 0 || !c.can_run || !bundles.length;
    submit.textContent = picked.length ? `创建批次（${picked.length} 个评测集 · ${total} 道题 × ${attempts.value || '?'} 次）` : '创建批次';
  }
  function drawPicker() {
    picker.replaceChildren(...(c.categories || []).map((cat) => {
      const members = suites.filter((s) => s.category === cat.id);
      if (!members.length) return null;
      return h('div', { class: members.length > 2 ? 'suite-group wide' : 'suite-group' },
        h('div', { class: 'suite-group-head' }, h('b', { text: cat.name }), h('span', { class: 'muted', text: cat.description })),
        h('div', { class: 'suite-cards' }, members.map((s) => h('button', {
          type: 'button', class: 'suite-card', 'aria-pressed': String(state.batchPick.has(s.id)), 'data-suite': s.id,
          onclick: () => {
            if (state.batchPick.has(s.id)) state.batchPick.delete(s.id); else { state.batchPick.set(s.id, null); loadTasks(s.id); }
            drawPicker(); drawNotes(); drawBoxes(); syncSubmit();
          },
        }, h('span', { class: 'suite-name', text: s.name }),
        h('span', { class: 'sub', text: (s.task_count === null ? '任务待准备' : s.task_count + ' 题') + ' · ' + (RUNNERS[s.runner] || s.runner) }),
        h('span', { class: 'suite-state ' + (comboReady(s) ? 'ok' : s.available ? 'todo' : 'off'), text: (state.batchPick.has(s.id) ? '已加入 · ' : '') + (comboReady(s) ? '可运行' : s.available ? '待配置' : '尚未接入') })))));
    }).filter(Boolean));
  }
  function suiteBox(s, entry) {
    const shown = new Set(setupReasons());
    const reasons = comboReasons(s).filter((text) => !shown.has(text));
    const remove = h('button', { type: 'button', class: 'button', onclick: () => { state.batchPick.delete(s.id); drawPicker(); drawBoxes(); syncSubmit(); } }, '移出批次');
    const head = h('div', { class: 'suite-box-head' }, h('span', { class: 'muted', text: s.description }), remove);
    const box = h('fieldset', {}, h('legend', { text: `${s.name} · ${(c.categories || []).find((x) => x.id === s.category)?.name || ''}` }), head,
      reasons.length ? h('div', { class: 'callout' }, reasons.map((text) => h('p', { text }))) : null);
    if (!entry) { box.append(h('div', { class: 'empty', text: '读取任务列表…' })); return box; }
    if (!entry.tasks.length) { box.append(h('div', { class: 'empty', text: entry.error || '该评测集暂无可选任务' })); return box; }
    const list = h('div', { class: 'task-options' });
    const search = h('input', { type: 'search', placeholder: `搜索 ${entry.tasks.length} 道任务`, 'aria-label': '搜索 ' + s.name + ' 的任务' });
    const count = h('span', { class: 'muted num' });
    const random = h('input', { type: 'number', min: 1, max: Math.min(s.max_tasks, entry.tasks.length), value: Math.min(10, s.max_tasks, entry.tasks.length), 'aria-label': '随机题数' });
    const choose = (names) => { entry.selected.clear(); for (const n of names) entry.selected.add(n); drawList(); };
    function drawList() {
      const q = search.value.trim().toLowerCase();
      const visible = q ? entry.tasks.filter((t) => t.toLowerCase().includes(q)) : entry.tasks;
      list.replaceChildren(...visible.map((task) => {
        const check = h('input', { type: 'checkbox', value: task, onchange: (e) => { e.target.checked ? entry.selected.add(task) : entry.selected.delete(task); count.textContent = `已选 ${entry.selected.size} / 上限 ${s.max_tasks}`; syncSubmit(); } });
        check.checked = entry.selected.has(task);
        return h('label', { class: 'task-option' }, check, h('span', { class: 'mono', text: task }));
      }));
      count.textContent = `已选 ${entry.selected.size} / 上限 ${s.max_tasks}`;
      syncSubmit();
    }
    search.addEventListener('input', drawList);
    box.append(h('div', { class: 'task-tools' }, search,
      entry.defaults.length ? h('button', { type: 'button', class: 'button', onclick: () => choose(entry.defaults) }, `推荐样例（${entry.defaults.length}）`) : null,
      entry.tasks.length <= s.max_tasks ? h('button', { type: 'button', class: 'button', onclick: () => choose(entry.tasks) }, `全部（${entry.tasks.length}）`) : null,
      h('span', { class: 'task-random' }, '随机', random, '题',
        h('button', { type: 'button', class: 'button', onclick: () => {
          const n = Math.max(1, Math.min(Number(random.value) || 1, s.max_tasks, entry.tasks.length));
          const pool = [...entry.tasks];
          for (let i = pool.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [pool[i], pool[j]] = [pool[j], pool[i]]; }
          choose(pool.slice(0, n));
        } }, '抽取')),
      h('button', { type: 'button', class: 'button', onclick: () => choose([]) }, '清空'), count),
      list, h('small', { class: 'muted', text: `每个评测集 1–${s.max_tasks} 道；并发不超过 ${s.max_concurrency}。` }));
    drawList();
    return box;
  }
  function drawBoxes() {
    boxes.replaceChildren(...(state.batchPick.size ? [...state.batchPick.entries()].map(([id, entry]) => suiteBox(byId.get(id), entry))
      : [h('div', { class: 'empty', text: '在上面点选一个或多个评测集加入批次。' })]));
  }
  const taskRequests = new Map();
  async function loadTasks(id) {
    const wanted = state.executor;
    const ticket = (taskRequests.get(id) || 0) + 1;
    taskRequests.set(id, ticket);
    let entry = { tasks: [], defaults: [], selected: new Set(), error: null };
    try {
      const body = await api('/api/suite?id=' + encodeURIComponent(id) + '&executor=' + encodeURIComponent(wanted || ''));
      entry = { tasks: body.tasks || [], defaults: body.default_tasks || [], selected: new Set(body.default_tasks || []), error: body.error || null };
    } catch (e) { entry.error = e.message; }
    // Only the suite's latest request counts: an older one may be for another
    // executor, or for this one before a switch away and back.
    if (state.batchPick.has(id) && taskRequests.get(id) === ticket) { state.batchPick.set(id, entry); drawBoxes(); syncSubmit(); }
  }
  attempts.addEventListener('input', syncSubmit);

  if (executorsList.length) {
    form.append(h('label', { class: 'field' }, h('span', { text: '执行机器' }), executor,
      h('small', { text: '运行 Harbor 和 Docker 的机器。SSH 执行机器的结果会同步回本机作业目录并写入评测数据库。' })));
  }
  form.append(
    h('div', { class: 'form-row' },
      h('label', { class: 'field' }, h('span', { text: 'metacodes 版本' }), bundle,
        h('small', { text: bundles.length ? '创建时按内容摘要复制并锁定这个发行包；之后重新构建或切换版本不影响本批次。' : '还没有可用的 Linux 发行包，请先运行一键配置。' })),
      h('label', { class: 'field' }, h('span', { text: '批次名称（可选）' }), name, h('small', { text: '不填则用批次编号。' }))),
    h('fieldset', {}, h('legend', { text: '评测集（可多选）' }), picker), boxes,
    h('label', { class: 'field' }, h('span', { text: '模型' }), model,
      h('small', { text: c.authentication?.label || '使用执行服务上配置的 Provider 和凭证' }),
      h('small', {}, c.providers?.models ? `另有 ${c.providers.count} 个导入的 Provider · ${c.providers.models} 个模型 · ` : '',
        link('#/providers', '用 URL + API Key 导入 Provider')),
      c.account_summary ? h('small', { text: `${c.account_summary.available_groups} / ${c.account_summary.groups} 个模型组可用 · ${c.account_summary.models} 个模型` }) : null,
      c.reasoning_effort ? h('small', { text: '推理强度：' + c.reasoning_effort }) : null),
    h('div', { class: 'form-row' }, h('label', { class: 'field' }, h('span', { text: '每题次数' }), attempts),
      h('label', { class: 'field' }, h('span', { text: '并发数' }), concurrency, h('small', { text: '每个评测集按自己的上限截断。' }))),
    h('p', { class: 'muted', text: '评测会调用所选模型。各评测集依次运行；创建后可在批次页持续查看进度、逐任务轨迹、Token 分布和耗时。' }), feedback, submit);
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    submit.disabled = true;
    feedback.textContent = '正在冻结 metacodes 版本并创建批次…';
    try {
      const request = { model: model.value, attempts: Number(attempts.value), concurrency: Number(concurrency.value),
        items: [...state.batchPick.entries()].map(([id, entry]) => ({ suite: id, tasks: entry.tasks.filter((t) => entry.selected.has(t)) })) };
      if (bundle.value) request.bundle = bundle.value;
      if (name.value.trim()) request.name = name.value.trim();
      if (executorsList.length) request.executor = executor.value;
      const record = await api('/api/batches', request);
      state.batchPick = null;
      state.scope = record.id;
      location.hash = '#/batch/' + encodeURIComponent(record.id);
    } catch (error) {
      feedback.textContent = error.message;
      syncSubmit();
    }
  });
  const callout = h('div', { class: 'callout' });
  const setupBox = h('div', {});
  function drawNotes() {
    const reasons = setupReasons();
    const notes = [...reasons, ...(c.warnings || [])];
    for (const id of state.batchPick.keys()) {
      const s = byId.get(id);
      if (s && s.judge) notes.push(s.name + '：' + judgeText(s.judge) + '；分数与使用其他评委（如官方 openai/gpt-4o-mini）的结果不可直接比较');
    }
    if (!suites.length) notes.push(...(c.reasons || []));
    if (!c.can_run) notes.push('当前服务为只读模式（未用 metacodes bench 启动），不能发起评测。');
    const actions = [];
    if (c.can_run && reasons.length) {
      actions.push(h('button', { type: 'button', class: 'button primary', onclick: () => startSetup(false) }, '一键配置'),
        h('button', { type: 'button', class: 'button', onclick: () => startSetup(true) }, '预演（不修改）'));
    }
    if (c.can_run && c.login?.available && !c.login?.signed_in) {
      actions.push(h('button', { type: 'button', class: 'button', onclick: startLogin }, '登录 Metask'));
    }
    callout.hidden = !notes.length && !actions.length;
    callout.replaceChildren(...notes.map((text) => h('p', { text })),
      actions.length ? h('div', { class: 'header-actions setup-actions' }, actions) : '');
  }
  async function startSetup(dryRun) {
    try {
      await api('/api/setup', { executor: state.executor, dry_run: dryRun });
      state.setupWatch = true;
      await drawSetup();
    } catch (error) { setupBox.replaceChildren(h('div', { class: 'callout', text: error.message })); }
  }
  async function startLogin() {
    try { await api('/api/login', {}); state.setupWatch = true; await drawSetup(); }
    catch (error) { setupBox.replaceChildren(h('div', { class: 'callout', text: error.message })); }
  }
  async function drawSetup() {
    if (!c.can_run) return;
    let latest = null;
    try { latest = (await api('/api/setup')).setup; } catch (_) { return; }
    let login = null;
    if (c.login?.available) { try { login = await api('/api/login'); } catch (_) { login = null; } }
    const parts = [];
    // The device code matters only while the sign-in waits for approval, or
    // when it ended without signing in; once signed in it is stale.
    if (login && (login.running || (login.verification_uri && !login.signed_in && !c.login?.signed_in))) {
      parts.push(panel('Metask 登录', login.running ? '等待确认' : '未完成，请重新登录',
        h('div', { class: 'panel-body run-state' },
          login.verification_uri ? h('p', {}, '在自己的浏览器打开 ',
            h('a', { href: login.verification_uri, target: '_blank', rel: 'noopener noreferrer', text: login.verification_uri }),
            ' 并输入代码 ', h('b', { class: 'mono', text: login.user_code || '' })) : h('p', { class: 'muted', text: '正在获取设备码…' }),
          h('p', { class: 'muted', text: '工作台只显示设备码，不接触密码。确认后页面会刷新模型列表。' }))));
    }
    if (latest) {
      const rows = (latest.steps || []).map((step) => h('details', { class: 'setup-step', 'data-key': 'setup-' + step.id },
        h('summary', {}, h('span', { class: 'setup-status s-' + step.status, text: SETUP_STATUS[step.status] || step.status }),
          h('b', { text: step.title }), h('span', { class: 'muted', text: step.detail || '' })),
        step.command ? h('p', { class: 'mono', text: '请运行：' + step.command }) : null,
        (step.commands || []).length ? h('pre', { text: step.commands.map((x) => (x.executed ? '$ ' : '将执行 ') + x.command).join('\n') }) : null,
        (step.log || []).length ? h('pre', { class: 'muted', text: step.log.join('\n') }) : null));
      parts.push(panel('一键配置 · ' + latest.executor, (latest.dry_run ? '预演 · ' : '') + (SETUP_RESULT[latest.status] || latest.status),
        h('div', { class: 'panel-body' }, rows.length ? rows : h('p', { class: 'muted', text: '正在检查…' }))));
    }
    const open = new Set([...setupBox.querySelectorAll('details[open]')].map((d) => d.dataset.key));
    setupBox.replaceChildren(...parts);
    for (const d of setupBox.querySelectorAll('details')) if (open.has(d.dataset.key)) d.open = true;
    const active = (latest && latest.status === 'running') || (login && login.running);
    if (active && route().view === 'new') { state.setupWatch = true; setTimeout(drawSetup, 2000); }
    else if (state.setupWatch && !active) { state.setupWatch = false; setTimeout(render, 500); }
  }
  drawPicker();
  drawNotes();
  drawBoxes();
  for (const [id, entry] of state.batchPick) if (!entry) loadTasks(id);
  drawSetup();
  syncSubmit();
  const groupRows = (c.account_groups || []).map((g) => h('tr', {},
    h('td', { text: g.name }), h('td', { text: g.configured ? '已有账号 Key' : '尚未配置 Key' })));
  const groupTable = h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, h('th', {}, '模型组'), h('th', {}, '凭证状态'))), h('tbody', {}, groupRows)));
  const groups = groupRows.length ? panel('账号可选模型组', `${groupRows.length} 个`,
    h('div', { class: 'panel-body' },
      h('p', { class: 'muted', text: '模型下拉框合并了已有 Key 的模型目录。其他可选组需要先在 Metask 账号中配置对应 Key，刷新后自动加入。' }),
      groupTable)) : null;
  return h('div', {}, callout, setupBox,
    panel('新建批次', '冻结 metacodes 版本 · 多个评测集依次运行 · 独立容器 · 完整轨迹 · 自动判分', form), groups);
}

async function renderRun(name) {
  const run = await api('/api/run?name=' + encodeURIComponent(name));
  let results;
  try { results = await renderJob(name); } catch (_) { results = h('div', { class: 'empty', text: '等待 Harbor 创建作业；进度和逐题结果将在这里自动出现。' }); }
  state.live = ['queued', 'starting', 'running', 'cancelling'].includes(run.status);
  navCurrent('overview');
  $('#title').textContent = RUN_STATUS[run.status] || run.status;
  crumbs([{ text: '看板', href: '#/' }, { text: name }]);
  const url = location.origin + '/#/run/' + encodeURIComponent(name);
  const stop = state.live ? h('button', { type: 'button', class: 'button', onclick: async (event) => {
    event.currentTarget.disabled = true;
    try { await api('/api/cancel', { name }); state.countdown = 1; }
    catch (error) { event.currentTarget.disabled = false; setConnection(false, error.message); }
  } }, '停止评测') : null;
  const copy = h('button', { type: 'button', class: 'button', onclick: async (event) => {
    try { await navigator.clipboard.writeText(url); event.currentTarget.textContent = '链接已复制'; }
    catch (_) { event.currentTarget.textContent = '请复制下方链接'; }
  } }, '复制结果链接');
  const summary = h('div', { class: 'panel-body run-state' },
    h('p', { text: `${run.suite_name ? run.suite_name + ' · ' : ''}${run.model} · ${run.tasks.length} 道题 × ${run.attempts} 次 · 并发 ${run.concurrency}${run.judge ? ' · ' + judgeText(run.judge) : ''}` }),
    h('p', { class: 'muted', text: run.error || (state.live ? '运行中，页面每 10 秒更新。' : '执行已结束，逐题结果和轨迹已保留。') }),
    h('a', { class: 'mono', href: url, text: url }));
  const log = h('details', { class: 'panel', 'data-key': 'runlog' }, h('summary', { text: '执行日志' }), h('pre', { text: run.log || '正在准备执行环境…' }));
  return h('div', {}, panel('运行状态', RUN_STATUS[run.status], summary, h('div', { class: 'header-actions' }, copy, stop)), log, results);
}

// ------------------------------------------------------------ job
const COLUMNS = [
  ['task', '任务', (r) => r.task],
  ['status', '结局', (r) => ORDER.indexOf(r.status)],
  ['reward', 'reward', (r) => r.reward ?? -1],
  ['tests', '测试', (r) => r.tests ? r.tests.passed / Math.max(1, r.tests.total) : -1],
  ['stop_reason', '停止原因', (r) => r.stop_reason || ''],
  ['turns', '轮数', (r) => r.turns ?? -1],
  ['tool_calls', '工具调用', (r) => r.tool_calls ?? -1],
  ['total_tokens', '任务总 Token', (r) => r.total_tokens ?? -1],
  ['initial_input_tokens', '初始 Token', (r) => r.initial_input_tokens ?? -1],
  ['input_tokens', '输入 token', (r) => r.input_tokens ?? -1],
  ['output_tokens', '输出 token', (r) => r.output_tokens ?? -1],
  ['tps', 'TPS', (r) => r.tps ?? -1],
  ['ttft_ms', 'TTFT', (r) => r.ttft_ms ?? -1],
  ['cost_usd', '成本', (r) => r.cost_usd ?? -1],
  ['phases', '时间分段', (r) => r.phases.agent ?? -1],
  ['elapsed_s', '总用时', (r) => r.elapsed_s ?? -1],
];

async function renderJob(name) {
  navCurrent('overview');
  const job = await api('/api/job?name=' + encodeURIComponent(name));
  state.live = job.running;
  $('#title').textContent = job.name;
  crumbs([{ text: '看板', href: '#/' }, job.batch ? { text: '批次 ' + job.batch, href: '#/batch/' + encodeURIComponent(job.batch) } : null, { text: job.name }].filter(Boolean));
  const s = job.summary;
  const causes = Object.entries(s.invalid_causes).map(([k, v]) => `${k} ${v}`).join(' · ');
  const metrics = h('section', { class: 'metrics' }, measurementCards(s),
    metric('平均 reward', s.mean_reward === null ? '—' : s.mean_reward.toFixed(2), '只算有效 trial'),
    metric('完成', `${s.trials - s.counts.running} / ${job.planned}`, job.running ? '运行中' : '已结束 · ' + dur(job.wall_s)),
    metric('无效', String(s.counts.invalid), causes || '无'),
    metric('空回复结束', String(s.empty_final), '以空回复收尾的 trial（harness 信号）'),
    metric('输入 / 输出 Token', `${compact(s.input_tokens)} / ${compact(s.output_tokens)}`, `缓存 ${pct(s.input_tokens ? s.cache_tokens / s.input_tokens : null)}`));

  const identity = h('div', { class: 'panel-body' },
    h('div', { class: 'muted' }, `${job.suite_name ? '评测集 ' + job.suite_name + '（' + job.category_name + '） · ' : ''}${job.metacodes?.label ? 'metacodes ' + job.metacodes.label + (job.metacodes.frozen ? '（批次冻结）' : '') + ' · ' : ''}模型 ${job.model || '—'} · agent ${job.agent || '—'} · 数据集 ${job.dataset || '—'} · 每题 ${job.attempts ?? '—'} 次 · 并发 ${job.concurrency ?? '—'}${job.judge ? ' · ' + judgeText(job.judge) : ''}`),
    outcomeBar(s.counts, s.trials, true), legend(s.counts));

  const filters = h('div', { class: 'filters' }, ['all', ...ORDER].map((key) => h('button', {
    type: 'button', class: state.jobFilter === key ? 'on' : null,
    onclick: () => { state.jobFilter = key; render(); },
  }, key === 'all' ? `全部 ${s.trials}` : `${STATUS[key]} ${s.counts[key]}`)));
  const search = h('input', { type: 'search', placeholder: '搜索任务', value: state.jobSearch, 'aria-label': '搜索任务',
    oninput: (e) => { state.jobSearch = e.target.value; drawRows(); } });
  const tbody = h('tbody', {});
  const head = h('tr', {}, COLUMNS.map(([key, label]) => {
    const th = h('th', { class: 'sortable' + (key === 'task' || key === 'status' || key === 'stop_reason' || key === 'phases' ? '' : ' num'), text: label,
      onclick: () => { state.sort = { key, dir: state.sort.key === key ? -state.sort.dir : 1 }; render(); } });
    if (state.sort.key === key) th.setAttribute('aria-sort', state.sort.dir > 0 ? 'ascending' : 'descending');
    return th;
  }));

  function drawRows() {
    const getter = COLUMNS.find(([key]) => key === state.sort.key)[2];
    const q = state.jobSearch.trim().toLowerCase();
    const rows = job.rows
      .filter((r) => state.jobFilter === 'all' || r.status === state.jobFilter)
      .filter((r) => !q || r.task.toLowerCase().includes(q))
      .sort((a, b) => { const x = getter(a), y = getter(b); return (x < y ? -1 : x > y ? 1 : 0) * state.sort.dir; });
    const maxTime = Math.max(1, ...job.rows.map((r) => PHASES.reduce((acc, [k]) => acc + (r.phases[k] || 0), 0)));
    tbody.replaceChildren(...(rows.length ? rows.map((r) => {
      const bar = h('div', { class: 'phase-bar', title: PHASES.map(([k, l]) => `${l} ${dur(r.phases[k])}`).join(' · ') },
        PHASES.map(([k]) => r.phases[k] ? h('span', { class: 'p-' + k, width: (100 * r.phases[k] / maxTime) + '%' }) : null));
      return h('tr', { class: 'link', onclick: () => { location.hash = `#/job/${encodeURIComponent(job.name)}/${encodeURIComponent(r.trial)}`; } },
        h('td', {}, h('span', { text: r.task }), h('span', { class: 'sub mono', text: `${r.first_attempt ? '首次执行' : '第 ' + r.attempt_number + ' 次'} · ${r.trial.split('__')[1] || ''}` })),
        h('td', {}, badge(r.status, r.cause), r.cause ? h('span', { class: 'sub', text: r.cause }) : null),
        h('td', { class: 'num' }, r.reward === null ? dash() : r.reward.toFixed(2)),
        h('td', { class: 'num' }, r.tests ? `${r.tests.passed}/${r.tests.total}` : dash()),
        h('td', {}, h('span', { text: r.stop_reason || '—' }), r.empty_final ? h('span', { class: 'sub flag', text: '空回复结束', title: '最后一条回复没有正文也没有工具调用，metacodes 把它当成了最终答案' }) : null),
        h('td', { class: 'num', text: int(r.turns) }),
        h('td', { class: 'num', text: int(r.tool_calls) }),
        h('td', { class: 'num', text: int(r.total_tokens) }, r.tokens_partial ? h('span', { class: 'sub flag', text: '部分记录' }) : null),
        h('td', { class: 'num', text: int(r.initial_input_tokens) }),
        h('td', { class: 'num', text: compact(r.input_tokens) }, h('span', { class: 'sub', text: '缓存 ' + pct(r.cache_ratio) })),
        h('td', { class: 'num', text: compact(r.output_tokens) }),
        h('td', { class: 'num', text: tps(r.tps) }),
        h('td', { class: 'num', text: ttft(r.ttft_ms) }),
        h('td', { class: 'num', text: usd(r.cost_usd) }),
        h('td', {}, bar),
        h('td', { class: 'num', text: dur(r.elapsed_s) }));
    }) : [h('tr', {}, h('td', { colspan: COLUMNS.length, class: 'empty', text: '没有符合条件的 trial' }))]));
  }
  drawRows();

  const keys = h('div', { class: 'panel-body' }, PHASES.map(([k, l]) => h('span', { class: 'key' }, h('i', { class: 'p-' + k }), l)),
    h('span', { class: 'faint', text: '时间分段条按本作业最长 trial 归一' }));
  const table = h('div', {}, h('div', { class: 'panel-body toolbar' }, filters, search),
    h('div', { class: 'table-scroll' }, h('table', {}, h('thead', {}, head), tbody)), keys);
  const csv = h('a', { class: 'button', href: '/api/job.csv?name=' + encodeURIComponent(job.name), text: '下载 CSV' });
  return h('div', {}, metrics, panel('概况', null, identity), panel('逐题结果', `${job.rows.length} 个 trial`, table, csv));
}

// ------------------------------------------------------------ trial
function msf(v) {
  if (v === null || v === undefined) return '—';
  if (v < 1000) return Math.round(v) + 'ms';
  return v < 60000 ? (v / 1000).toFixed(v < 10000 ? 2 : 1) + 's' : dur(v / 1000);
}
function columns(series, short) {
  const max = Math.max(1, ...series.map((s) => s.segments.reduce((acc, [, v]) => acc + (v || 0), 0)));
  return h('div', { class: 'cols' + (short ? ' short' : '') }, series.map((s) => h('div', { class: 'col', title: s.title },
    s.segments.map(([cls, v]) => v ? h('span', { class: cls, height: (100 * v / max) + '%' }) : null))));
}
function keys(items) { return h('div', { class: 'legend keys' }, items.map(([cls, label]) => h('span', { class: 'key' }, h('i', { class: cls }), label))); }

function tokenPanel(t) {
  const reqs = t.requests || [];
  if (!reqs.length) return panel('Token 分布', null, h('div', { class: 'empty', text: '没有逐请求数据：这次运行没有经过计时代理（历史运行），只有上方的总量。' }));
  const withParts = reqs.some((r) => r.composition);
  const title = (r) => [`请求 #${r.seq}${r.offset_s !== null && r.offset_s !== undefined ? ' · +' + dur(r.offset_s) : ''}`,
    `输入 ${int(r.input_tokens)}（缓存 ${int(r.cache_tokens)}）· 输出 ${int(r.output_tokens)}`,
    `用时 ${msf(r.duration_ms)} · TTFT ${msf(r.ttft_ms)}`,
    ...(r.composition ? PARTS.map(([k, l]) => `${l} ${int(r.composition[k])}`) : [])].join('\n');
  const context = columns(reqs.map((r) => ({ title: title(r), segments: r.composition
    ? PARTS.map(([k]) => ['c-' + k, r.composition[k]])
    : [['t-cached', r.cache_tokens || 0], ['t-input', Math.max(0, (r.input_tokens || 0) - (r.cache_tokens || 0))]] })));
  const outputs = columns(reqs.map((r) => ({ title: title(r), segments: [['t-output', r.output_tokens || 0]] })), true);
  const cache = reqs.map((r) => ({ title: title(r), segments: [['t-cached', r.cache_tokens || 0], ['t-input', Math.max(0, (r.input_tokens || 0) - (r.cache_tokens || 0))]] }));
  const sum = (k) => reqs.reduce((acc, r) => acc + (r[k] || 0), 0);
  const peak = Math.max(0, ...reqs.map((r) => r.input_tokens || 0));
  const last = reqs[reqs.length - 1];
  const rows = reqs.map((r) => h('tr', {},
    h('td', { class: 'num', text: '#' + r.seq }),
    h('td', { class: 'num', text: r.offset_s === null || r.offset_s === undefined ? '—' : '+' + dur(r.offset_s) }),
    h('td', { class: 'num', text: msf(r.duration_ms) }),
    h('td', { class: 'num', text: msf(r.ttft_ms) }),
    h('td', { class: 'num', text: int(r.input_tokens) }),
    h('td', { class: 'num', text: int(r.cache_tokens) }),
    h('td', { class: 'num', text: int(r.output_tokens) }),
    h('td', {}, r.composition ? stackBar(compositionSegments(r.composition)) : h('span', { class: 'na', text: '未采集' })),
    h('td', { class: 'num', text: r.complete ? String(r.http_status ?? '') : `${r.http_status ?? '—'} 未完成` })));
  return panel('Token 分布', `${reqs.length} 个模型请求 · 输入 ${compact(sum('input_tokens'))}（缓存 ${compact(sum('cache_tokens'))}）· 输出 ${compact(sum('output_tokens'))} · 峰值上下文 ${compact(peak)}`,
    h('div', { class: 'panel-body' },
      h('p', { class: 'muted', text: withParts ? '每列一个模型请求：该次请求的完整输入上下文，按组成部分分色（按字节占比分摊实测输入 Token）。' : '每列一个模型请求的输入上下文（深色为缓存命中）。这次运行没有记录组成。' }),
      context, withParts ? keys(PARTS.map(([k, l]) => ['c-' + k, l])) : keys([['t-cached', '缓存命中'], ['t-input', '未缓存输入']]),
      withParts ? h('div', {}, h('p', { class: 'muted', text: '缓存命中（深色）/ 未缓存输入：' }), columns(cache, true)) : null,
      h('p', { class: 'muted', text: '输出 Token：' }), outputs,
      last && last.composition ? h('div', {}, h('p', { class: 'muted', text: `最后一个请求的上下文组成（${int(last.input_tokens)} tok）：` }), stackBar(compositionSegments(last.composition)),
        keys(PARTS.map(([k, l]) => ['c-' + k, `${l} ${compact(last.composition[k])}`]))) : null,
      h('details', { class: 'call', 'data-key': 'requests' }, h('summary', { text: '逐请求明细' }),
        h('div', { class: 'table-scroll' }, h('table', {}, h('thead', {}, h('tr', {}, ['请求', '开始', '用时', 'TTFT', '输入', '缓存', '输出', '上下文组成', 'HTTP'].map((x, i) => h('th', { class: i === 7 ? null : 'num', text: x })))), h('tbody', {}, rows))))));
}

function timePanel(t) {
  const r = t.row;
  const split = t.time_split || {};
  const phaseTotal = PHASES.reduce((acc, [k]) => acc + (r.phases[k] || 0), 0);
  const phases = h('div', { class: 'split' }, PHASES.map(([k, l]) => h('div', { class: 'split-row' }, h('span', { text: l }),
    h('div', { class: 'stack-bar' }, h('span', { class: 'p-' + k, width: (phaseTotal ? 100 * (r.phases[k] || 0) / phaseTotal : 0) + '%' })),
    h('span', { class: 'num muted', text: dur(r.phases[k]) }))));
  const agent = split.agent_s;
  const segs = [['t-model', split.model_s, '等待模型'], ['t-tool', split.tool_s, '执行工具'], ['t-other', split.other_s, '其他（harness、I/O）']];
  const agentBlock = agent !== null && agent !== undefined && (split.model_s !== null || split.tool_s !== null) ? h('div', {},
    h('p', { class: 'muted', text: `agent 阶段 ${dur(agent)} 拆分：` }),
    stackBar(segs.map(([c, v, l]) => [c, v || 0, l])),
    keys(segs.map(([c, v, l]) => [c, `${l} ${dur(v)}${agent ? ' · ' + pct((v || 0) / agent) : ''}`])),
    h('p', { class: 'faint', text: `模型时间为 ${split.requests} 个请求的总用时（含排队与网络）；工具时间为 ${split.tool_calls} 次调用的实测执行时间。并行工具调用时两者之和可能超过阶段时长。` }))
    : h('p', { class: 'muted', text: 'agent 阶段没有逐请求或逐工具计时，无法再拆分。' });
  const timing = t.tool_timing || [];
  const maxTool = Math.max(1, ...timing.map((x) => x.total_ms || 0));
  const tools = timing.length ? h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['工具', '调用', '错误', '总耗时', '', '平均', '最长'].map((x, i) => h('th', { class: i === 0 || i === 4 ? null : 'num', text: x })))),
    h('tbody', {}, timing.map((x) => h('tr', {},
      h('td', {}, h('span', { class: 'tool-name', text: x.name })),
      h('td', { class: 'num', text: String(x.calls) }),
      h('td', { class: 'num' + (x.errors ? ' flag' : ''), text: String(x.errors) }),
      h('td', { class: 'num', text: msf(x.total_ms) }),
      h('td', {}, h('div', { class: 'phase-bar' }, h('span', { class: 't-tool', width: (100 * (x.total_ms || 0) / maxTool) + '%' }))),
      h('td', { class: 'num', text: msf(x.mean_ms) }),
      h('td', { class: 'num', text: msf(x.max_ms) })))))) : h('div', { class: 'empty', text: '没有工具调用' });
  return h('div', { class: 'grid-2' },
    panel('耗时', `总用时 ${dur(r.elapsed_s)}`, h('div', { class: 'panel-body split' }, phases, agentBlock)),
    panel('工具耗时', `${timing.reduce((a, x) => a + x.calls, 0)} 次`, tools));
}

function trialBody(t) {
  const r = t.row;
  const metrics = h('section', { class: 'metrics' },
    h('div', { class: 'metric lead' }, h('span', { text: '结局' }), h('strong', {}, badge(r.status)), h('small', { text: r.cause || (r.reward === null ? '' : 'reward ' + r.reward) })),
    metric('测试', r.tests ? `${r.tests.passed}/${r.tests.total}` : '—', '判分脚本的测试用例'),
    metric('轮数 / 工具调用', `${int(r.turns)} / ${int(r.tool_calls)}`, '停止原因 ' + (r.stop_reason || '—')),
    metric('任务总 Token', int(r.total_tokens), `输入 ${int(r.input_tokens)}（含缓存）+ 输出 ${int(r.output_tokens)}${r.tokens_partial ? ' · 部分记录' : ''}`),
    metric('初始 Token', int(r.initial_input_tokens), '首个模型请求的完整输入上下文', false,
      r.initial_composition ? stackBar(compositionSegments(r.initial_composition), true) : null),
    metric('TPS（生成）', tps(r.tps), '输出 Token / 首输出至响应结束的生成秒数'),
    metric('TTFT（均值）', ttft(r.ttft_ms), `P50 ${ttft(r.ttft_p50_ms)} · P95 ${ttft(r.ttft_p95_ms)}`),
    metric('估算成本', usd(r.cost_usd), 'metacodes 价目表估算，非账单'),
    metric('用时', dur(r.elapsed_s), PHASES.map(([k, l]) => `${l} ${dur(r.phases[k])}`).join(' · ')));
  const parts = [metrics];
  if (t.exception_message) parts.push(h('div', { class: 'callout', text: `${r.exception}: ${t.exception_message}` }));
  if (r.initial_composition) {
    const c = r.initial_composition;
    parts.push(panel('初始上下文窗口组成', `${int(r.initial_input_tokens)} tok`, h('div', { class: 'panel-body' }, stackBar(compositionSegments(c)),
      keys(PARTS.map(([k, l]) => ['c-' + k, `${l} ${compact(c[k])} · ${pct((c[k] || 0) / Math.max(1, partsTotal(c)))}`])))));
  }
  parts.push(tokenPanel(t), timePanel(t));

  const tests = t.tests ? h('div', { class: 'panel-body tests' }, [...t.tests.tests]
    .sort((a, b) => (a.status === 'passed') - (b.status === 'passed'))
    .map((x) => h('div', { class: 'test' }, badge(x.status === 'passed' ? 'pass' : x.status === 'failed' ? 'fail' : 'invalid'),
      h('span', { class: 'mono', text: x.name.split('::').pop() }), x.message ? h('span', { class: 'msg', text: x.message }) : null)))
    : h('div', { class: 'empty', text: '判分没有写出逐条测试报告' });
  const maxTool = Math.max(1, ...t.tools.map(([, n]) => n));
  const tools = t.tools.length ? h('div', { class: 'panel-body bars' }, t.tools.map(([name, n]) =>
    h('div', { class: 'bar-row' }, h('span', { class: 'tool-name', text: name }), h('div', { class: 'bar' }, h('span', { width: (100 * n / maxTool) + '%' })), h('span', { class: 'num', text: n }))))
    : h('div', { class: 'empty', text: '没有工具调用' });
  parts.push(h('div', { class: 'grid-2' }, panel('判分测试', t.tests ? `${t.tests.passed}/${t.tests.total} 通过` : null, tests), panel('工具使用', `${t.tools.reduce((a, [, n]) => a + n, 0)} 次`, tools)));

  const steps = t.steps.map((s, i) => {
    const body = h('div', { class: 'step-body' });
    if (s.message) body.append(h('div', { class: 'msg-text', text: s.message }));
    if (s.reasoning) body.append(h('details', { class: 'reason', 'data-key': `r${i}` }, h('summary', { text: '思考过程' }), h('pre', { text: s.reasoning })));
    for (const c of s.tool_calls) {
      const obs = s.observations.filter((o) => o.call === c.id);
      body.append(h('details', { class: 'call', 'data-key': `c${i}-${c.id}` },
        h('summary', {}, h('span', { class: 'tool-name', text: c.name }), c.elapsed_ms !== null && c.elapsed_ms !== undefined ? h('span', { class: 'num muted', text: msf(c.elapsed_ms) }) : null,
          h('span', { class: 'faint', text: c.arguments.slice(0, 120) })),
        h('pre', { text: c.arguments })));
      for (const o of obs) body.append(h('details', { class: 'obs' + (o.is_error ? ' error' : ''), 'data-key': `o${i}-${o.call}` },
        h('summary', {}, h('span', { text: o.is_error ? '结果（错误）' : '结果' }), h('span', { class: 'faint', text: o.content.slice(0, 120) })),
        h('pre', { text: o.content })));
    }
    for (const o of s.observations.filter((o) => !s.tool_calls.some((c) => c.id === o.call))) {
      body.append(h('details', { class: 'obs', 'data-key': `x${i}-${o.call}` }, h('summary', { text: '结果' }), h('pre', { text: o.content })));
    }
    return h('div', { class: 'step' }, h('div', { class: 'step-src' }, h('b', { text: s.source === 'agent' ? 'agent' : s.source === 'user' ? '任务' : s.source }), '#' + s.id), body);
  });
  parts.push(panel('轨迹', `${t.steps.length} 步`, h('div', { class: 'panel-body timeline' }, steps.length ? steps : h('div', { class: 'empty', text: '还没有轨迹（trial 结束后才会写出）' }))));
  parts.push(h('div', { class: 'grid-2' },
    panel('判分输出', '末尾', h('div', { class: 'panel-body' }, t.verifier_output ? h('pre', { class: 'block', text: t.verifier_output }) : h('div', { class: 'empty', text: '无' }))),
    panel('metacodes stderr', '末尾', h('div', { class: 'panel-body' }, t.stderr ? h('pre', { class: 'block', text: t.stderr }) : h('div', { class: 'empty', text: '无' })))));
  return parts;
}

async function renderTrial(jobName, trialName) {
  navCurrent('overview');
  const t = await api(`/api/trial?job=${encodeURIComponent(jobName)}&trial=${encodeURIComponent(trialName)}`);
  const r = t.row;
  state.live = r.status === 'running';
  $('#title').textContent = r.task;
  crumbs([{ text: '看板', href: '#/' }, { text: jobName, href: '#/job/' + encodeURIComponent(jobName) }, { text: r.trial }]);
  return h('div', {}, trialBody(t));
}

// ------------------------------------------------------------ compare
async function renderCompare(names) {
  navCurrent('compare');
  $('#title').textContent = '对比';
  crumbs([{ text: '看板', href: '#/' }, { text: '对比' }]);
  if (names.length < 2) {
    state.live = false;
    return panel('对比', null, h('div', { class: 'empty', text: '在总览里勾选两个以上的作业，再点「对比所选」。' }));
  }
  const jobs = await Promise.all(names.map((n) => api('/api/job?name=' + encodeURIComponent(n))));
  state.live = jobs.some((j) => j.running);
  // Compare each task's first execution, consistently with the headline rate.
  const byJob = jobs.map((j) => {
    const m = new Map();
    for (const r of j.rows) if (r.first_attempt) m.set(r.task, r);
    return m;
  });
  const tasks = [...new Set(jobs.flatMap((j) => j.rows.map((r) => r.task)))].sort();
  const common = tasks.filter((t) => byJob.every((m) => m.has(t) && ['pass', 'partial', 'fail', 'timeout'].includes(m.get(t).status)));
  const metrics = h('section', { class: 'metrics' },
    metric('共同首次有效题', String(common.length), '每个作业的首次执行都有有效结局', true),
    ...jobs.map((j, i) => metric(j.model || j.name, pct(common.length ? common.filter((t) => byJob[i].get(t).status === 'pass').length / common.length : null),
      `${j.name} · 共同题首次满分率`)));
  const rows = tasks.map((task) => {
    const statuses = byJob.map((m) => m.get(task)?.status);
    const differ = new Set(statuses.filter(Boolean)).size > 1;
    return h('tr', { class: differ ? 'diff' : null }, h('td', { text: task }),
      byJob.map((m, i) => {
        const r = m.get(task);
        if (!r) return h('td', { class: 'cell' }, dash());
        return h('td', { class: 'cell' }, h('a', { href: `#/job/${encodeURIComponent(jobs[i].name)}/${encodeURIComponent(r.trial)}` }, badge(r.status, r.cause)),
          h('span', { class: 'sub', text: `${r.tests ? r.tests.passed + '/' + r.tests.total + ' · ' : ''}${compact(r.total_tokens)} tok · ${dur(r.elapsed_s)}` }),
          h('span', { class: 'sub', text: `${tps(r.tps)} · TTFT ${ttft(r.ttft_ms)}` }));
      }));
  });
  const table = h('div', { class: 'table-scroll' }, h('table', { class: 'matrix' },
    h('thead', {}, h('tr', {}, h('th', { text: '任务' }), jobs.map((j) => h('th', { class: 'center' }, h('span', { text: j.model || j.name }), h('span', { class: 'sub', text: j.name }))))),
    h('tbody', {}, rows)));
  return h('div', {}, metrics, panel('逐题对比', '首次执行成绩 · 重跑不回填 · 深色行表示结局不同', table));
}

// ------------------------------------------------------------ settings (database)
async function renderSettings() {
  state.live = false;
  navCurrent('settings');
  $('#title').textContent = '数据库';
  crumbs([{ text: '看板', href: '#/' }, { text: '评测数据库' }]);
  const st = await api('/api/store');
  const db = st.database;
  const counts = st.counts || {};
  const current = panel('当前数据库', db.format, h('div', { class: 'panel-body' }, h('dl', { class: 'kv' },
    h('dt', { text: '类型' }), h('dd', { text: `${db.format}（schema v${db.schema_version}）` }),
    h('dt', { text: '位置' }), h('dd', { class: 'mono', text: db.location }),
    db.password_env ? h('dt', { text: '密码环境变量' }) : null, db.password_env ? h('dd', { class: 'mono', text: db.password_env }) : null,
    h('dt', { text: '内容' }), h('dd', { text: `批次 ${counts.batches ?? 0} · 作业 ${counts.jobs ?? 0} · trial ${counts.trials ?? 0} · 请求 ${counts.requests ?? 0} · 文件 ${counts.files ?? 0} · 启动记录 ${counts.runs ?? 0}` }),
    h('dt', { text: '最近导入' }), h('dd', { text: st.last_ingested_at ? when(st.last_ingested_at) : '—' }),
    h('dt', { text: '待重算投影' }), h('dd', { text: String(st.stale_projections) }),
    h('dt', { text: '同步的作业目录' }), h('dd', { class: 'mono', text: (st.jobs_dirs || []).join('\n') || '—' }),
    st.records_dir ? h('dt', { text: '启动记录目录' }) : null, st.records_dir ? h('dd', { class: 'mono', text: st.records_dir }) : null,
    st.config_path ? h('dt', { text: '配置文件' }) : null, st.config_path ? h('dd', { class: 'mono', text: st.config_path }) : null),
    h('p', { class: 'muted', text: '页面从评测数据库读取：Harbor 作业目录中的成绩、逐次轨迹、判分日志、请求计时（.bench-metrics/）和批次记录都会同步进来。首次满分率只看每道题的首次执行，重跑成绩不回填；基础设施无效项单列。' })));

  const configured = st.configured || { backend: 'sqlite', path: st.default_sqlite || '' };
  let backend = configured.backend === 'postgres' ? 'postgres' : 'sqlite';
  const radio = (value, label) => {
    const input = h('input', { type: 'radio', name: 'backend', value, onchange: () => { backend = value; draw(); } });
    input.checked = backend === value;
    return h('label', {}, input, label);
  };
  const path = h('input', { type: 'text', value: configured.backend === 'sqlite' ? (configured.path || st.default_sqlite || '') : (st.default_sqlite || ''), 'aria-label': 'SQLite 文件路径' });
  const dsn = h('input', { type: 'text', value: configured.dsn || '', placeholder: 'postgresql://bench@db.example:5432/bench', 'aria-label': 'PostgreSQL DSN' });
  const passwordEnv = h('input', { type: 'text', value: configured.password_env || '', placeholder: 'BENCH_PG_PASSWORD', 'aria-label': '密码环境变量' });
  const migrate = h('input', { type: 'checkbox' });
  migrate.checked = true;
  const result = h('div', { class: 'result', role: 'status' });
  const sqliteFields = h('label', { class: 'field' }, h('span', { text: 'SQLite 文件' }), path, h('small', { text: '相对路径以工作台配置目录为基准；不存在时切换时新建。默认：' + (st.default_sqlite || '') }));
  const pgFields = h('div', { class: 'stack' },
    h('label', { class: 'field' }, h('span', { text: 'PostgreSQL DSN' }), dsn, h('small', { text: '不要在 DSN 里写密码。需要先安装 psycopg' + (st.psycopg ? '（已安装）' : '（未安装，可在新建页运行一键配置）') })),
    h('label', { class: 'field' }, h('span', { text: '密码环境变量（可选）' }), passwordEnv, h('small', { text: '执行服务启动时的环境变量名；也可以用 PGPASSWORD 或 ~/.pgpass。' })));
  function draw() { sqliteFields.hidden = backend !== 'sqlite'; pgFields.hidden = backend !== 'postgres'; }
  function target() {
    if (backend === 'sqlite') return { backend: 'sqlite', path: path.value.trim() };
    const value = { backend: 'postgres', dsn: dsn.value.trim() };
    if (passwordEnv.value.trim()) value.password_env = passwordEnv.value.trim();
    return value;
  }
  async function act(action, button) {
    button.disabled = true;
    result.className = 'result';
    result.textContent = action === 'test' ? '正在连接…' : (migrate.checked ? '正在迁移并校验数据，数据量大时需要几分钟…' : '正在切换…');
    try {
      const body = await api('/api/store', { action, store: target(), ...(action === 'apply' ? { migrate: migrate.checked } : {}) });
      result.className = 'result ok';
      if (action === 'test') {
        result.textContent = body.exists ? `连接成功：${body.database.format} ${body.database.location}（schema v${body.database.schema_version}）${body.same ? ' · 就是当前数据库' : ''}\n已有：作业 ${body.counts.jobs} · trial ${body.counts.trials} · 批次 ${body.counts.batches ?? 0}` : `可用：${body.message}`;
      } else if (body.unchanged) {
        result.textContent = '目标就是当前数据库，未作改动。';
      } else {
        const tables = body.migrated ? Object.entries(body.migrated.tables || {}).map(([k, v]) => `${k} ${v.verified}`).join(' · ') : '';
        result.textContent = `已切换到 ${body.database.format} ${body.database.location}，已写入工作台配置并立即生效。${tables ? '\n已迁移并校验：' + tables : ''}`;
        setTimeout(render, 800);
      }
    } catch (error) {
      result.className = 'result bad';
      result.textContent = error.message;
    } finally { button.disabled = false; }
  }
  const testBtn = h('button', { type: 'button', class: 'button', onclick: (e) => act('test', e.currentTarget) }, '测试连接');
  const applyBtn = h('button', { type: 'button', class: 'button primary', onclick: (e) => act('apply', e.currentTarget) }, '保存并切换');
  draw();
  const form = st.can_edit ? h('div', { class: 'settings-form' },
    h('div', { class: 'radio-row' }, radio('sqlite', 'SQLite（单机文件）'), radio('postgres', 'PostgreSQL（团队共享）')),
    sqliteFields, pgFields,
    h('label', { class: 'check' }, migrate, '把当前数据库的数据迁移到新数据库（逐表复制并校验，可重复执行）'),
    h('div', { class: 'header-actions' }, testBtn, applyBtn), result,
    h('p', { class: 'muted', text: '有评测或批次运行时不能切换。切换后新数据写入新数据库；不勾选迁移时，作业目录仍会同步进新库，但只存在于旧库的数据不会出现。命令行等价操作：metacodes bench db migrate --to <目标> --switch' }))
    : h('div', { class: 'empty', text: '当前服务为只读模式（未用 metacodes bench 启动），不能修改数据库。' });
  return h('div', {}, current, panel('配置数据库', '工作台配置中的 store', form));
}

// ------------------------------------------------------------ providers
function probeText(p) {
  if (!p) return h('span', { class: 'na', text: '未探测' });
  const detail = p.ok ? `${when(p.at)} · ${p.latency_ms} ms` : (p.error || '') + (p.reply !== undefined ? `（回复：${JSON.stringify(p.reply)}）` : '');
  return h('span', { class: p.ok ? 'probe ok' : 'probe bad', title: `发送 ${p.expected}` + (p.reply !== undefined ? `，回复 ${JSON.stringify(p.reply)}` : '') },
    p.ok ? '探测通过' : '探测失败', h('small', { text: ' ' + detail }));
}

async function renderProviders() {
  state.live = false;
  navCurrent('providers');
  $('#title').textContent = '模型 Provider';
  crumbs([{ text: '看板', href: '#/' }, { text: '用 URL + API Key 导入评测用的模型' }]);
  let list;
  try { list = await api('/api/providers'); } catch (e) {
    return h('div', { class: 'empty', text: e.message || '当前服务为只读模式（未用 metacodes bench 启动），不能管理 Provider。' });
  }
  const protocols = list.protocols || {};
  const result = h('div', { class: 'result', role: 'status' });
  const show = (ok, text) => { result.className = 'result ' + (ok ? 'ok' : 'bad'); result.textContent = text; };

  async function probe(button, id, model) {
    button.disabled = true;
    show(true, `正在探测 ${id}/${model}：发送一个随机字符串，等模型原样返回…`);
    try {
      const r = await api('/api/providers/probe', { id, model });
      show(r.ok, r.ok ? `探测通过：${id}/${model} 原样返回了 ${r.expected}（${r.latency_ms} ms）` :
        `探测失败：${id}/${model}，${r.error}${r.reply !== undefined ? `\n发送 ${r.expected}，回复 ${JSON.stringify(r.reply)}` : ''}`);
      setTimeout(render, 600);
    } catch (e) { show(false, e.message); button.disabled = false; }
  }
  async function remove(button, id) {
    if (!confirm(`删除 Provider ${id}？已保存的 API Key 一并删除，已有评测结果不受影响。`)) return;
    button.disabled = true;
    try { await api('/api/providers/remove', { id }); render(); } catch (e) { show(false, e.message); button.disabled = false; }
  }

  const rows = (list.providers || []).flatMap((p) => p.models.map((m, i) => h('tr', {},
    i ? h('td', {}) : h('td', {}, h('strong', { text: p.name }), h('div', { class: 'mono muted', text: p.id })),
    i ? h('td', {}) : h('td', {}, h('div', { class: 'mono', text: p.base_url }), h('small', { class: 'muted', text: `${p.protocol_label} · ${p.auth} · Key ${p.key_hint}` })),
    h('td', { class: 'mono', text: m.name }),
    h('td', {}, probeText(m.probe)),
    h('td', {}, h('button', { type: 'button', class: 'button', onclick: (e) => probe(e.currentTarget, p.id, m.name) }, '探测'),
      i ? null : h('button', { type: 'button', class: 'button', onclick: (e) => remove(e.currentTarget, p.id) }, '删除')))));
  const table = rows.length ? h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, h('th', {}, 'Provider'), h('th', {}, '地址'), h('th', {}, '模型'), h('th', {}, '探测'), h('th', {}, ''))),
    h('tbody', {}, rows))) : h('div', { class: 'empty', text: '还没有导入 Provider。' });

  const id = h('input', { type: 'text', required: true, maxlength: 32, pattern: '[a-z0-9][a-z0-9_\\-]{0,31}', placeholder: 'tokenjoy', 'aria-label': 'Provider 标识' });
  const name = h('input', { type: 'text', maxlength: 80, placeholder: '例如：TokenJoy', 'aria-label': '显示名称' });
  const baseUrl = h('input', { type: 'url', required: true, placeholder: 'https://api.example.com/v1', 'aria-label': 'Base URL' });
  const protocol = h('select', { 'aria-label': '协议' }, Object.entries(protocols).map(([value, label]) => h('option', { value }, label)));
  const auth = h('select', { 'aria-label': '认证' }, h('option', { value: '' }, '自动（Anthropic 用 x-api-key，其余 Bearer）'),
    h('option', { value: 'bearer' }, 'Authorization: Bearer'), h('option', { value: 'x-api-key' }, 'x-api-key'));
  const key = h('input', { type: 'password', autocomplete: 'off', placeholder: 'sk-…', 'aria-label': 'API Key' });
  const models = h('textarea', { rows: 3, placeholder: '每行一个，例如 glm-5.3\n留空则读取该地址的 /models', 'aria-label': '模型' });
  const replace = h('input', { type: 'checkbox' });
  const probeAfter = h('input', { type: 'checkbox' });
  probeAfter.checked = true;
  const submit = h('button', { type: 'submit', class: 'button primary' }, '导入');
  const form = h('form', { class: 'settings-form' },
    h('div', { class: 'form-row' },
      h('label', { class: 'field' }, h('span', { text: 'Provider 标识' }), id, h('small', { text: '模型在下拉框里显示为 <标识>/<模型>。小写字母、数字、- 和 _。' })),
      h('label', { class: 'field' }, h('span', { text: '显示名称（可选）' }), name)),
    h('label', { class: 'field' }, h('span', { text: 'Base URL' }), baseUrl, h('small', { text: 'http(s)://主机 或 http(s)://主机/v1；粘贴完整的 /chat/completions 等地址也可以。' })),
    h('div', { class: 'form-row' },
      h('label', { class: 'field' }, h('span', { text: '协议' }), protocol),
      h('label', { class: 'field' }, h('span', { text: '认证' }), auth)),
    h('label', { class: 'field' }, h('span', { text: 'API Key' }), key, h('small', { text: '只保存在工作台机器的私有文件里（0600），页面和评测容器都拿不到；评测请求经凭据代理转发。覆盖已有 Provider 时留空沿用原 Key。' })),
    h('label', { class: 'field' }, h('span', { text: '模型（可选）' }), models),
    h('label', { class: 'check' }, replace, '覆盖同标识的 Provider'),
    h('label', { class: 'check' }, probeAfter, '导入后立即探测第一个模型（真实发送一次请求）'),
    h('div', { class: 'header-actions' }, submit));
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    submit.disabled = true;
    show(true, models.value.trim() ? '正在导入…' : '正在读取模型列表并导入…');
    const request = { id: id.value.trim(), base_url: baseUrl.value.trim(), protocol: protocol.value,
      models: models.value.split(/[\n,]/).map((m) => m.trim()).filter(Boolean), probe: probeAfter.checked };
    if (name.value.trim()) request.name = name.value.trim();
    if (auth.value) request.auth = auth.value;
    if (key.value) request.api_key = key.value;
    if (replace.checked) request.replace = true;
    try {
      const r = await api('/api/providers', request);
      key.value = '';
      const p = r.probe;
      show(!p || p.ok, `已导入 ${r.id}：${r.models.length} 个模型（${r.models.map((m) => m.name).join('、')}）` +
        (p ? (p.ok ? `\n探测通过：${p.model} 原样返回了 ${p.expected}` : `\n探测失败：${p.model}，${p.error}${p.reply !== undefined ? `（回复 ${JSON.stringify(p.reply)}）` : ''}`) : ''));
      setTimeout(render, 1200);
    } catch (e) { show(false, e.message); } finally { submit.disabled = false; }
  });
  return h('div', {},
    panel('已导入的 Provider', `${(list.providers || []).length} 个`, h('div', { class: 'panel-body' },
      h('p', { class: 'muted', text: '这些模型出现在新建批次的模型下拉框里，和 Metask 账号模型并列。探测会真实发送一次请求：让模型原样返回一个随机字符串，返回一致才算通过。导入的 Provider 不支持 WorkBuddy；带 LLM 评委的评测集（GAIA2）在 Metask 认证下不可用（评委会被转发到导入的上游），在 --auth provider 下评委读取执行机器的环境变量，可以运行。' }),
      table, result)),
    panel('导入 Provider', 'URL + API Key', form));
}

// ------------------------------------------------------------ refresh loop
function tick() {
  const label = $('#countdown');
  if (!state.auto || !state.live) { label.textContent = state.live ? '已暂停' : '无运行中'; return; }
  state.countdown -= 1;
  label.textContent = state.countdown + 's';
  if (state.countdown <= 0) { state.countdown = REFRESH_S; render(); }
}
document.addEventListener('DOMContentLoaded', () => {
  $('#refresh').addEventListener('click', () => { state.countdown = REFRESH_S; render(); });
  $('#auto').addEventListener('click', (e) => { state.auto = !state.auto; e.currentTarget.setAttribute('aria-pressed', String(state.auto)); tick(); });
  window.addEventListener('hashchange', () => { state.countdown = REFRESH_S; window.scrollTo(0, 0); render(); });
  render();
  state.timer = setInterval(tick, 1000);
});

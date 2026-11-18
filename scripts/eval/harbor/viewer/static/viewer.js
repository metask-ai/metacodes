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
  jobFilter: 'all', jobSearch: '', sort: { key: 'task', dir: 1 }, selected: new Set() };

// ------------------------------------------------------------ DOM helpers
function h(tag, props, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === null || value === undefined || value === false) continue;
    if (key === 'class') el.className = value;
    else if (key === 'text') el.textContent = value;
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else if (key === 'width') el.style.width = value;
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
function metric(label, value, note, lead) {
  return h('div', { class: 'metric' + (lead ? ' lead' : '') }, h('span', { text: label }), h('strong', { text: value }), note ? h('small', { text: note }) : null);
}
function tps(value) { return value === null || value === undefined ? '未采集' : value.toFixed(1) + ' tok/s'; }
function ttft(value) { return value === null || value === undefined ? '未采集' : (value / 1000).toFixed(2) + 's'; }
function measurementCards(s) {
  return [
    metric('一次性完成率', pct(s.one_shot_pass_rate), `${s.counts.pass} 通过 / ${s.valid || 0} 有效`, true),
    metric('首轮满分率', pct(s.first_pass_rate), `${s.first_passed || 0} 首次满分 / ${s.first_valid || 0} 首次有效 · 无效 ${s.first_invalid || 0}`),
    metric('任务总 Token', compact(s.total_tokens), `输入含缓存 + 输出 · ${s.token_trials || 0}/${s.trials || 0} 次有数据${s.partial_token_trials ? ' · 含部分记录' : ''}`),
    metric('初始 Token（均值）', compact(s.initial_input_tokens_mean), `首个请求完整输入 · ${s.initial_token_trials || 0} 次有数据`),
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
  if (parts[0] === 'run' && parts[1]) return { view: 'run', name: parts[1] };
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
    if (r.view === 'new') node = await renderNewRun();
    else if (r.view === 'run') node = await renderRun(r.name);
    else if (r.view === 'overview') node = await renderOverview();
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

// ------------------------------------------------------------ overview
async function renderOverview() {
  navCurrent('overview');
  $('#title').textContent = 'Bench 看板';
  crumbs([{ text: '所有作业' }]);
  const { jobs, runs = [], summary, storage } = await api('/api/jobs');
  state.live = jobs.some((j) => j.running) || runs.some((r) => ['queued', 'starting', 'running', 'cancelling'].includes(r.status));
  const all = { trials: 0, valid: 0, pass: 0, running: 0, invalid: 0 };
  for (const j of jobs) {
    const s = j.summary;
    all.trials += s.trials; all.valid += s.valid; all.pass += s.counts.pass;
    all.running += s.counts.running; all.invalid += s.counts.invalid;
  }
  const metrics = h('section', { class: 'metrics' }, measurementCards(summary),
    metric('作业', String(jobs.length), jobs.filter((j) => j.running).length + ' 个运行中'),
    metric('trial', String(all.trials), all.running + ' 个运行中'),
    metric('无效', String(all.invalid), '基础设施原因，不计入通过率'));

  const compareBtn = h('button', { class: 'button primary', type: 'button', disabled: state.selected.size < 2 || null,
    onclick: () => { location.hash = '#/compare/' + [...state.selected].map(encodeURIComponent).join(','); } }, `对比所选 (${state.selected.size})`);
  const rows = jobs.map((j) => {
    const s = j.summary;
    const done = s.trials - s.counts.running;
    const box = h('input', { type: 'checkbox', 'aria-label': '选择 ' + j.name, onclick: (e) => e.stopPropagation(),
      onchange: (e) => { e.target.checked ? state.selected.add(j.name) : state.selected.delete(j.name); compareBtn.disabled = state.selected.size < 2; compareBtn.textContent = `对比所选 (${state.selected.size})`; } });
    box.checked = state.selected.has(j.name);
    return h('tr', { class: 'link', onclick: () => { location.hash = '#/job/' + encodeURIComponent(j.name); } },
      h('td', {}, box),
      h('td', {}, h('span', { text: j.name }), h('span', { class: 'sub', text: (j.dataset || '') + (j.running ? ' · 运行中' : '') })),
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
    h('tbody', {}, rows.length ? rows : h('tr', {}, h('td', { colspan: 14, class: 'empty', text: '没有找到 Harbor 作业' })))));
  const launches = runs.length ? panel('工作台发起的评测', `${runs.length} 次`,
    h('div', { class: 'launches' }, runs.map((r) => h('a', { class: 'launch', href: '#/run/' + r.name },
      h('b', { text: r.name }), h('span', { class: 'muted', text: r.model }),
      h('span', { text: RUN_STATUS[r.status] || r.status }))))) : null;
  const storagePanel = storage ? panel('数据保存位置', storage.format,
    h('div', { class: 'panel-body' },
      storage.database ? h('p', {}, '评测数据库：', h('code', { text: storage.database.location })) : null,
      (storage.jobs_dirs || []).map((path) => h('p', {}, '同步的作业目录：', h('code', { text: path }))),
      h('p', { class: 'muted', text: '页面读取评测数据库：Harbor 作业目录中的成绩、逐次轨迹、判分日志和请求计时（.bench-metrics/）都会同步进数据库，可用 metacodes bench db migrate 在 SQLite 与 PostgreSQL 之间迁移。' }),
      h('p', { class: 'muted', text: '历史日志未采集请求时间戳时，TPS / TTFT 显示未采集。首次满分率只看每道题的首次执行，重跑成绩不回填；基础设施无效项单列。' }),
      storage.records_dir ? h('p', { class: 'muted', text: '工作台启动记录：' + storage.records_dir }) : null)) : null;
  return h('div', {}, metrics, launches, panel('作业', `${jobs.length} 个`, table, compareBtn), storagePanel);
}

// ------------------------------------------------------------ run workbench
const RUN_STATUS = { queued: '等待启动', starting: '准备环境', running: '运行中',
  cancelling: '正在停止', cancelled: '已停止', finished: '运行完成', failed: '执行失败', interrupted: '执行中断' };

async function renderNewRun() {
  state.live = false;
  navCurrent('new');
  $('#title').textContent = '新建评测';
  crumbs([{ text: '所有作业', href: '#/' }, { text: '选择任务和模型' }]);
  const c = await api('/api/workbench');
  const form = h('form', { class: 'run-form' });
  const model = h('select', { name: 'model', required: true },
    (c.models || []).map((m) => h('option', { value: m.id, selected: m.id === c.default_model }, m.label)));
  form.append(h('label', { class: 'field' }, h('span', { text: '模型' }), model,
    h('small', { text: c.authentication?.label || '使用执行服务上配置的 Provider 和凭证' }),
    c.account_summary ? h('small', { text: `${c.account_summary.available_groups} / ${c.account_summary.groups} 个模型组可用 · ${c.account_summary.models} 个模型` }) : null,
    c.reasoning_effort ? h('small', { text: '推理强度：' + c.reasoning_effort }) : null));
  const checks = (c.tasks || []).map((name) => h('label', { class: 'task-option' },
    h('input', { type: 'checkbox', value: name, name: 'task' }), h('span', { class: 'mono', text: name })));
  form.append(h('fieldset', {}, h('legend', { text: '试跑任务' }),
    h('div', { class: 'task-options' }, checks), h('small', { class: 'muted', text: '常用题目；每次可选 1–20 道。' })));
  const extra = h('textarea', { name: 'extra', rows: 2, placeholder: '其他 Terminal-Bench 2.1 任务名，逗号或换行分隔' });
  form.append(h('label', { class: 'field' }, h('span', { text: '补充任务（可选）' }), extra));
  const attempts = h('input', { name: 'attempts', type: 'number', inputmode: 'numeric', value: 1, min: 1, max: 5, step: 1, required: true });
  const concurrency = h('input', { name: 'concurrency', type: 'number', inputmode: 'numeric', value: 1, min: 1, max: 3, step: 1, required: true });
  form.append(h('div', { class: 'form-row' }, h('label', { class: 'field' }, h('span', { text: '每题次数' }), attempts),
    h('label', { class: 'field' }, h('span', { text: '并发数' }), concurrency)));
  const feedback = h('div', { role: 'status', class: 'form-feedback' });
  const submit = h('button', { type: 'submit', class: 'button primary', disabled: !c.ready || !c.can_run }, '开始评测');
  form.append(h('p', { class: 'muted', text: '评测会调用所选模型。提交后可在工作台持续查看进度，完成后保留结果链接。' }), feedback, submit);
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const tasks = [...form.querySelectorAll('[name=task]:checked')].map((e) => e.value)
      .concat(extra.value.split(/[,，\s]+/).filter(Boolean));
    submit.disabled = true;
    feedback.textContent = '正在启动…';
    try {
      const record = await api('/api/runs', { model: model.value, tasks: [...new Set(tasks)],
        attempts: Number(attempts.value), concurrency: Number(concurrency.value) });
      location.hash = '#/run/' + record.name;
    } catch (error) {
      feedback.textContent = error.message;
      submit.disabled = false;
    }
  });
  const notes = [...(c.reasons || []), ...(c.warnings || [])];
  if (!c.can_run) notes.push('请使用 metacodes bench 输出的授权链接打开工作台，启用运行操作。');
  const groupRows = (c.account_groups || []).map((g) => h('tr', {},
    h('td', { text: g.name }), h('td', { text: g.configured ? '已有账号 Key' : '尚未配置 Key' })));
  const groupTable = h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, h('th', {}, '模型组'), h('th', {}, '凭证状态'))), h('tbody', {}, groupRows)));
  const groups = groupRows.length ? panel('账号可选模型组', `${groupRows.length} 个`,
    h('div', { class: 'panel-body' },
      h('p', { class: 'muted', text: '模型下拉框合并了已有 Key 的模型目录。其他可选组需要先在 Metask 账号中配置对应 Key，刷新后自动加入。' }),
      groupTable)) : null;
  return h('div', {}, notes.length ? h('div', { class: 'callout' }, notes.map((text) => h('p', { text }))) : null,
    panel('Terminal-Bench 2.1', '独立容器运行 · 完整轨迹 · 自动判分', form), groups);
}

async function renderRun(name) {
  const run = await api('/api/run?name=' + encodeURIComponent(name));
  let results;
  try { results = await renderJob(name); } catch (_) { results = h('div', { class: 'empty', text: '等待 Harbor 创建作业；进度和逐题结果将在这里自动出现。' }); }
  state.live = ['queued', 'starting', 'running', 'cancelling'].includes(run.status);
  navCurrent('overview');
  $('#title').textContent = RUN_STATUS[run.status] || run.status;
  crumbs([{ text: '所有作业', href: '#/' }, { text: name }]);
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
    h('p', { text: `${run.model} · ${run.tasks.length} 道题 × ${run.attempts} 次 · 并发 ${run.concurrency}` }),
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
  crumbs([{ text: '所有作业', href: '#/' }, { text: job.name }]);
  const s = job.summary;
  const causes = Object.entries(s.invalid_causes).map(([k, v]) => `${k} ${v}`).join(' · ');
  const metrics = h('section', { class: 'metrics' }, measurementCards(s),
    metric('平均 reward', s.mean_reward === null ? '—' : s.mean_reward.toFixed(2), '只算有效 trial'),
    metric('完成', `${s.trials - s.counts.running} / ${job.planned}`, job.running ? '运行中' : '已结束 · ' + dur(job.wall_s)),
    metric('无效', String(s.counts.invalid), causes || '无'),
    metric('空回复结束', String(s.empty_final), '以空回复收尾的 trial（harness 信号）'),
    metric('输入 / 输出 Token', `${compact(s.input_tokens)} / ${compact(s.output_tokens)}`, `缓存 ${pct(s.input_tokens ? s.cache_tokens / s.input_tokens : null)}`));

  const identity = h('div', { class: 'panel-body' },
    h('div', { class: 'muted' }, `模型 ${job.model || '—'} · agent ${job.agent || '—'} · 数据集 ${job.dataset || '—'} · 每题 ${job.attempts ?? '—'} 次 · 并发 ${job.concurrency ?? '—'}`),
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
async function renderTrial(jobName, trialName) {
  navCurrent('overview');
  const t = await api(`/api/trial?job=${encodeURIComponent(jobName)}&trial=${encodeURIComponent(trialName)}`);
  const r = t.row;
  state.live = r.status === 'running';
  $('#title').textContent = r.task;
  crumbs([{ text: '所有作业', href: '#/' }, { text: jobName, href: '#/job/' + encodeURIComponent(jobName) }, { text: r.trial }]);
  const metrics = h('section', { class: 'metrics' },
    h('div', { class: 'metric lead' }, h('span', { text: '结局' }), h('strong', {}, badge(r.status)), h('small', { text: r.cause || (r.reward === null ? '' : 'reward ' + r.reward) })),
    metric('测试', r.tests ? `${r.tests.passed}/${r.tests.total}` : '—', '判分脚本的测试用例'),
    metric('轮数 / 工具调用', `${int(r.turns)} / ${int(r.tool_calls)}`, '停止原因 ' + (r.stop_reason || '—')),
    metric('任务总 Token', int(r.total_tokens), `输入 ${int(r.input_tokens)}（含缓存）+ 输出 ${int(r.output_tokens)}${r.tokens_partial ? ' · 部分记录' : ''}`),
    metric('初始 Token', int(r.initial_input_tokens), '首个模型请求的完整输入上下文'),
    metric('TPS（生成）', tps(r.tps), '输出 Token / 首输出至响应结束的生成秒数'),
    metric('TTFT（均值）', ttft(r.ttft_ms), `P50 ${ttft(r.ttft_p50_ms)} · P95 ${ttft(r.ttft_p95_ms)}`),
    metric('估算成本', usd(r.cost_usd), 'metacodes 价目表估算，非账单'),
    metric('用时', dur(r.elapsed_s), PHASES.map(([k, l]) => `${l} ${dur(r.phases[k])}`).join(' · ')));
  const parts = [metrics];
  if (t.exception_message) parts.push(h('div', { class: 'callout', text: `${r.exception}: ${t.exception_message}` }));

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
        h('summary', {}, h('span', { class: 'tool-name', text: c.name }), h('span', { class: 'faint', text: c.arguments.slice(0, 120) })),
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
  return h('div', {}, parts);
}

// ------------------------------------------------------------ compare
async function renderCompare(names) {
  navCurrent('compare');
  $('#title').textContent = '对比';
  crumbs([{ text: '所有作业', href: '#/' }, { text: '对比' }]);
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

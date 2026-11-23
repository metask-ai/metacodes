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
  scope: null, suitePick: null, profileSuite: 'all', taskFilter: 'all', taskSearch: '', boardModel: {}, boardExpanded: {} };

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
    metric('一次性完成率', pct(s.one_shot_pass_rate), `${s.counts.pass} 通过 / ${s.valid || 0} 有效 · 95% 区间 ${ciText(s.pass_rate_ci95)}`, true),
    metric('首轮满分率', pct(s.first_pass_rate), `${s.first_passed || 0} 首次满分 / ${s.first_valid || 0} 首次有效 · 无效 ${s.first_invalid || 0}`),
    metric('任务总 Token', compact(s.total_tokens), `${s.token_trials || 0}/${s.trials || 0} 次有数据${s.partial_token_trials ? ' · 含部分记录' : ''}`),
    metric('初始 Token（均值）', compact(s.initial_input_tokens_mean), `${s.initial_token_trials || 0} 次有数据`, false,
      s.initial_composition_mean ? stackBar(compositionSegments(s.initial_composition_mean), true) : null),
    metric('TPS（生成）', tps(s.tps), `${s.profiled_requests || 0}/${s.requests || 0} 个请求`),
    metric('TTFT（均值）', ttft(s.ttft_ms), `P50 ${ttft(s.ttft_p50_ms)} · P95 ${ttft(s.ttft_p95_ms)} · ${s.ttft_samples_ms?.length || 0} 个请求`),
    metric('估算成本', usd(s.cost_usd), `${s.cost_trials || 0}/${s.trials || 0} 次有价格`),
    metric('至少通过一次', pct(s.solved_rate), `${s.tasks_solved || 0} / ${s.tasks_attempted || 0} 道`),
    metric('每题平均成本', usd(s.cost_per_task), `${s.task_cost_tasks || 0} 道`),
    metric('每次通过成本', usd(s.cost_per_pass)),
    metric('未通过的成本占比', pct(s.non_pass_cost_share), `失败 ${usd(s.cost_by_status?.fail)} · 超时 ${usd(s.cost_by_status?.timeout)}`),
    metric('缓存命中率', pct(s.cache_hit_rate)),
    metric('通过 trial 平均轮数', fixed(s.turns_per_pass), `工具调用 ${fixed(s.tool_calls_per_pass)} 次 · ${s.passed_turn_trials || 0} 个通过 trial 有数据`),
  ];
}
function fixed(x) { return x === null || x === undefined ? '—' : x.toFixed(1); }
function ciText(ci) { return ci ? `${pct(ci[0])}–${pct(ci[1])}` : '—'; }
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
  if (parts[0] === 'profile' && parts[1] && parts[2] === 'task' && parts[3] && parts[4]) return { view: 'task', profile: parts[1], job: parts[3], task: parts[4], trial: parts[5] || null };
  if (parts[0] === 'profile' && parts[1]) return { view: 'profile', profile: parts[1] };
  if (parts[0] === 'job' && parts[1] && parts[2]) return { view: 'trial', job: parts[1], trial: parts[2] };
  if (parts[0] === 'job' && parts[1]) return { view: 'job', job: parts[1] };
  if (parts[0] === 'leaderboard') return { view: 'leaderboard', suite: parts[1] || null };
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
  state.editing = false;
  const r = route();
  try {
    let node;
    if (r.view === 'new') node = await renderNewRun();
    else if (r.view === 'settings') node = await renderSettings();
    else if (r.view === 'providers') node = await renderProviders();
    else if (r.view === 'run') node = await renderRun(r.name);
    else if (r.view === 'overview') node = await renderOverview();
    else if (r.view === 'profile') node = await renderProfile(r.profile);
    else if (r.view === 'task') node = await renderProfileTask(r.profile, r.job, r.task, r.trial);
    else if (r.view === 'job') node = await renderJob(r.job);
    else if (r.view === 'trial') node = await renderTrial(r.job, r.trial);
    else if (r.view === 'leaderboard') node = await renderLeaderboard(r.suite);
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
  if (!c) return null;
  return panel('初始上下文窗口组成', scopeText || '均值', h('div', { class: 'panel-body' },
    stackBar(compositionSegments(c)),
    h('div', { class: 'legend keys' }, PARTS.map(([k, l]) => h('span', { class: 'key' }, h('i', { class: 'c-' + k }), `${l} ${compact(c[k])} · ${pct((c[k] || 0) / Math.max(1, partsTotal(c)))}`)))));
}

// ------------------------------------------------------------ overview
const PROFILE_STATUS = { queued: '排队中', running: '运行中', cancelling: '正在停止', finished: '空闲', cancelled: '已停止' };
const ITEM_STATUS = { pending: '等待', running: '运行中', finished: '完成', failed: '执行失败', cancelled: '已停止', interrupted: '中断', skipped: '跳过' };
const profileActive = (b) => ['queued', 'running', 'cancelling'].includes(b.status);
const profileName = (b) => b.name || b.id;
const profileHref = (b) => '#/profile/' + encodeURIComponent(b.id);
const featuresText = (b) => (b.features || []).join(', ') || '未开启';

// Fills the run form for another run on profile `b` with one model (the
// page's model filter, else the last run's): that model's suites and tasks
// from the task rows (on the profile page) or the queued datasets, or only
// the tasks whose latest attempts did not all pass.
const unpassed = (t) => !t.attempts.length || t.passed < t.attempts.length;
function runModel(b) {
  return b.tasks && state.profileModel && state.profileModel !== 'all' ? state.profileModel : b.items[b.items.length - 1]?.model;
}
function runAgain(b, onlyUnpassed) {
  const last = b.items[b.items.length - 1] || {};
  const model = runModel(b);
  const lastOfModel = [...b.items].reverse().find((i) => i.model === model) || last;
  state.runDraft = { profile: b.id, from: profileName(b), label: b.metacodes?.label, features: b.features || [],
    models: [model], attempts: lastOfModel.attempts, concurrency: lastOfModel.concurrency };
  state.executor = lastOfModel.executor;
  const wanted = new Map();
  const add = (suite, task) => { if (!wanted.has(suite)) wanted.set(suite, []); if (!wanted.get(suite).includes(task)) wanted.get(suite).push(task); };
  if (b.tasks) {
    for (const t of b.tasks.filter((x) => x.model === model)) if (!onlyUnpassed || unpassed(t)) add(t.suite, t.task);
  } else {
    for (const item of b.items.filter((i) => i.model === model)) for (const task of item.tasks || []) add(item.suite, task);
  }
  state.suitePick = new Map([...wanted.keys()].map((id) => [id, null]));
  state.taskWanted = wanted;
  location.hash = '#/new';
}
async function deleteProfile(b, button) {
  if (!confirm(`删除评测配置 ${profileName(b)}？它的所有运行记录、日志和评测结果都会从工作台和数据库删除，不能恢复。`)) return false;
  button.disabled = true;
  try { await api('/api/profile/delete', { id: b.id }); }
  catch (error) { button.disabled = false; setConnection(false, error.message); return false; }
  if (state.scope === b.id) state.scope = null;
  return true;
}
async function stopProfile(b, button) {
  if (!confirm(`停止评测配置 ${profileName(b)} 的队列？正在运行的评测集会被取消，还没开始的评测集不再运行。`)) return;
  button.disabled = true;
  try { await api('/api/profile/cancel', { id: b.id }); state.countdown = 1; }
  catch (error) { button.disabled = false; setConnection(false, error.message); }
}
function profileActions(b, compact) {
  const keep = (handler) => (event) => { event.stopPropagation(); handler(event.currentTarget); };
  return [
    h('button', { type: 'button', class: 'button', title: '在这个评测配置上再运行，题目和参数按上次填好', onclick: keep(() => runAgain(b, false)) }, compact ? '运行' : '再次运行'),
    b.tasks && b.tasks.some((t) => t.model === runModel(b) && t.attempts.length && unpassed(t))
      ? h('button', { type: 'button', class: 'button', title: '只选最新结果没有全部通过的题', onclick: keep(() => runAgain(b, true)) }, '重跑未通过的题') : null,
    profileActive(b)
      ? h('button', { type: 'button', class: 'button', onclick: keep((button) => stopProfile(b, button)) }, compact ? '停止' : '停止队列')
      : h('button', { type: 'button', class: 'button', onclick: keep(async (button) => {
        if (!await deleteProfile(b, button)) return;
        if (route().view === 'overview') render(); else location.hash = '#/';
      }) }, compact ? '删除' : '删除评测配置'),
  ];
}
function progressText(b) {
  return b.progress ? `${b.progress.done} / ${b.progress.planned} trial` : '—';
}

async function renderOverview() {
  navCurrent('overview');
  $('#title').textContent = 'Bench 看板';
  let body = await api('/api/jobs?profile=' + encodeURIComponent(state.scope || 'all'));
  if (!state.scope) {
    state.scope = body.profiles.length ? body.profiles[0].id : 'all';
    if (state.scope !== 'all') body = await api('/api/jobs?profile=' + encodeURIComponent(state.scope));
  }
  const { jobs, runs = [], summary, profiles = [] } = body;
  if (state.scope !== 'all' && !profiles.some((b) => b.id === state.scope)) {
    state.scope = 'all';
    return renderOverview();
  }
  const current = profiles.find((b) => b.id === state.scope);
  crumbs([{ text: current ? '评测配置 ' + profileName(current) : '所有作业' }]);
  state.live = jobs.some((j) => j.running) || profiles.some(profileActive) || runs.some((r) => ['queued', 'starting', 'running', 'cancelling'].includes(r.status));

  const select = h('select', { 'aria-label': '按评测配置查看', onchange: () => { state.scope = select.value; state.selected.clear(); render(); } },
    profiles.map((b) => h('option', { value: b.id, selected: b.id === state.scope }, `${profileName(b)} · ${b.metacodes?.label || '—'} · ${PROFILE_STATUS[b.status] || b.status}`)),
    h('option', { value: 'all', selected: state.scope === 'all' }, `全部作业（${body.job_total}）`));
  const scopeBar = h('div', { class: 'scope' }, h('b', { text: '数据范围' }), select,
    current ? h('span', { class: 'meta', text: `metacodes ${current.metacodes?.label || '—'} · 高级功能 ${featuresText(current)} · ${current.suites.length} 个评测集 · ${PROFILE_STATUS[current.status] || current.status}` }) : null,
    current ? link(profileHref(current), '查看评测配置 →') : null);

  const all = { trials: 0, running: 0, invalid: 0 };
  for (const j of jobs) { all.trials += j.summary.trials; all.running += j.summary.counts.running; all.invalid += j.summary.counts.invalid; }
  const metrics = h('section', { class: 'metrics' }, measurementCards(summary),
    metric('作业', String(jobs.length), jobs.filter((j) => j.running).length + ' 个运行中'),
    metric('trial', String(all.trials), all.running + ' 个运行中'),
    metric('无效', String(all.invalid)));

  const profileRows = profiles.map((b) => h('tr', { class: 'link', onclick: () => { location.hash = profileHref(b); } },
    h('td', {}, h('a', { href: profileHref(b), onclick: (e) => e.stopPropagation(), text: profileName(b) }), h('span', { class: 'sub mono', text: b.name ? b.id : when(b.created_at) })),
    h('td', {}, h('span', { class: 'mono', text: b.metacodes?.label || '—' }), h('span', { class: 'sub mono', text: '高级功能 ' + featuresText(b) })),
    h('td', { text: b.models.join('、') || '—' }),
    h('td', {}, h('span', { text: [...new Map(b.items.map((i) => [i.suite, i.suite_name || i.suite])).values()].join('、') }), h('span', { class: 'sub', text: `${b.items.length} 次运行` })),
    h('td', {}, h('span', { text: PROFILE_STATUS[b.status] || b.status }), h('span', { class: 'sub', text: progressText(b) })),
    h('td', {}, outcomeBar(b.summary.counts, b.summary.trials || 0)),
    h('td', { class: 'num', text: pct(b.summary.first_pass_rate) }),
    h('td', { class: 'num', text: compact(b.summary.total_tokens) }),
    h('td', { class: 'num', text: when(b.last_run_at) }),
    body.can_run ? h('td', {}, h('div', { class: 'row-actions' }, profileActions(b, true))) : null));
  const profileHeads = ['评测配置', 'metacodes 版本', '模型', '评测集', '状态', '结局分布（最新结果）', '首次满分率', '总 Token', '最近运行', ...(body.can_run ? ['操作'] : [])];
  const profilePanel = panel('评测配置', `${profiles.length} 个`, h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, profileHeads.map((t, i) => h('th', { class: i >= 6 && i <= 8 ? 'num' : null, text: t })))),
    h('tbody', {}, profileRows.length ? profileRows : h('tr', {}, h('td', { colspan: profileHeads.length, class: 'empty' }, '还没有评测配置 · ', link('#/new', '发起评测')))))),
  h('a', { class: 'button', href: '#/new', text: '发起评测' }));

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
  const loose = runs.filter((r) => !r.profile && !r.batch);
  const launches = state.scope !== 'all' || !loose.length ? null : panel('早期单独发起的评测', `${loose.length} 次`,
    h('div', { class: 'launches' }, loose.map((r) => h('a', { class: 'launch', href: '#/run/' + r.name },
      h('b', { text: r.name }), h('span', { class: 'muted', text: [r.suite_name, r.model].filter(Boolean).join(' · ') }),
      h('span', { text: RUN_STATUS[r.status] || r.status })))));
  const jobsTitle = current ? '这个评测配置的作业（每次运行的每个评测集一个）' : '作业';
  return h('div', {}, profilePanel, scopeBar, metrics,
    panel(jobsTitle, state.category === 'all' ? `${jobs.length} 个` : `${visible.length} / ${jobs.length} 个`, h('div', {}, filter, table), compareBtn),
    compositionPanel(summary, current ? '本评测配置所有作业均值' : '均值'), launches);
}

// ------------------------------------------------------------ profile
async function renderProfile(id) {
  navCurrent('overview');
  const b = await api('/api/profile?id=' + encodeURIComponent(id));
  state.live = profileActive(b);
  $('#title').textContent = profileName(b);
  crumbs([{ text: '看板', href: '#/' }, { text: '评测配置 ' + b.id }]);
  const s = b.summary;
  const metrics = h('section', { class: 'metrics' }, measurementCards(s),
    metric('队列', progressText(b), PROFILE_STATUS[b.status] || b.status),
    metric('运行', String(b.items.length), b.items.filter((i) => i.status === 'finished').length + ' 个完成'),
    metric('无效', String(s.counts.invalid)));

  const nameInput = h('input', { type: 'text', maxlength: 80, value: b.name || '', placeholder: b.id, 'aria-label': '评测配置名称' });
  const renameFeedback = h('span', { class: 'muted', role: 'status' });
  const closeRename = () => { state.editing = false; renameForm.hidden = true; nameRow.hidden = false; };
  const renameForm = h('form', { class: 'rename', hidden: true },
    nameInput, h('button', { type: 'submit', class: 'button primary' }, '保存'),
    h('button', { type: 'button', class: 'button', onclick: closeRename }, '取消'), renameFeedback);
  renameForm.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeRename(); });
  renameForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    renameFeedback.textContent = '正在保存…';
    try {
      await api('/api/profile/rename', { id: b.id, name: nameInput.value });
      render();
    } catch (error) { renameFeedback.textContent = error.message; }
  });
  const nameRow = h('span', { class: 'rename' }, h('span', { text: b.name || '未命名（显示评测配置编号）' }),
    b.can_run ? h('button', { type: 'button', class: 'button', onclick: () => {
      state.editing = true; nameRow.hidden = true; renameForm.hidden = false; nameInput.focus(); nameInput.select();
    } }, '重命名') : null);
  const m = b.metacodes || {};
  const info = h('div', { class: 'panel-body' }, h('dl', { class: 'kv' },
    h('dt', { text: '名称' }), h('dd', {}, nameRow, renameForm),
    h('dt', { text: '编号' }), h('dd', { class: 'mono', text: b.id }),
    h('dt', { text: 'metacodes 版本' }), h('dd', {}, h('b', { class: 'mono', text: m.label || '—' }), m.release ? h('span', { class: 'muted', text: ' · 发行包 ' + m.release }) : null),
    h('dt', { text: '冻结' }), h('dd', { class: 'mono', text: m.digest ? `内容摘要 ${m.digest}${m.commit ? ' · commit ' + m.commit : ''}` : '—' }),
    h('dt', { text: '二进制 SHA-256' }), h('dd', { class: 'mono', text: m.binary_sha256 || '—' }),
    h('dt', { text: '冻结副本' }), h('dd', { class: 'mono', text: m.bundle || '—' }),
    h('dt', { text: '高级功能' }), h('dd', { class: 'mono', text: featuresText(b) }),
    h('dt', { text: '模型' }), h('dd', { text: b.models.join('、') || '—' }),
    h('dt', { text: '时间' }), h('dd', { text: `创建 ${when(b.created_at)} · 最近运行 ${when(b.last_run_at)}` })));

  const itemRows = [...b.items].reverse().map((item) => {
    const j = item.job; const js = j?.summary;
    return h('tr', { class: j ? 'link' : null, onclick: j ? () => { location.hash = '#/job/' + encodeURIComponent(j.name); } : null },
      h('td', {}, h('span', { text: item.suite_name || item.suite }), h('span', { class: 'sub', text: [item.category_name, `${item.tasks.length} 道题`,
        (b.features || []).length && item.features && !item.features.length ? '不带高级功能（WorkBuddy）' : null].filter(Boolean).join(' · ') })),
      h('td', { text: item.model || '—' }),
      h('td', {}, h('span', { text: ITEM_STATUS[item.status] || item.status }), item.error ? h('span', { class: 'sub flag', text: item.error }) : null),
      h('td', { class: 'num', text: js ? `${js.trials - js.counts.running} / ${j.planned}` : `0 / ${item.tasks.length * (item.attempts || 1)}` }),
      h('td', {}, js ? outcomeBar(js.counts, js.trials) : dash()),
      h('td', { class: 'num', text: js ? pct(js.first_pass_rate) : '—' }),
      h('td', { class: 'num', text: js ? compact(js.total_tokens) : '—' }),
      h('td', { class: 'num', text: j ? dur(j.wall_s) : '—' }),
      h('td', { class: 'num', text: when(item.queued_at) }),
      h('td', { class: 'mono', text: item.run || '—' }));
  });
  const items = panel('运行历史', `${b.items.length} 次`, h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['评测集', '模型', '状态', '完成', '结局分布', '首次满分率', '总 Token', '用时', '排队', '作业'].map((t, i) => h('th', { class: [3, 5, 6, 7, 8].includes(i) ? 'num' : null, text: t })))),
    h('tbody', {}, itemRows))));

  // Per task: each (suite, model, task)'s latest attempts in order.
  const suitesPresent = [...new Map(b.tasks.map((t) => [t.suite, t.suite_name || t.suite]))];
  if (state.profileSuite && !suitesPresent.some(([id]) => id === state.profileSuite)) state.profileSuite = 'all';
  const chips = suitesPresent.length > 1 ? h('div', { class: 'chips', role: 'group', 'aria-label': '按评测集筛选' },
    [['all', '全部评测集'], ...suitesPresent].map(([sid, name]) => h('button', { type: 'button', class: 'chip', 'aria-pressed': String((state.profileSuite || 'all') === sid),
      onclick: () => { state.profileSuite = sid; render(); } }, name))) : null;
  const modelsPresent = [...new Set(b.tasks.map((t) => t.model).filter(Boolean))];
  if (state.profileModel && !modelsPresent.includes(state.profileModel)) state.profileModel = 'all';
  const modelChips = modelsPresent.length > 1 ? h('div', { class: 'chips', role: 'group', 'aria-label': '按模型筛选' },
    [['all', '全部模型'], ...modelsPresent.map((x) => [x, x])].map(([mid, name]) => h('button', { type: 'button', class: 'chip', 'aria-pressed': String((state.profileModel || 'all') === mid),
      onclick: () => { state.profileModel = mid; render(); } }, name))) : null;
  const firstFilter = h('div', { class: 'filters' }, ['all', ...ORDER].map((key) => h('button', {
    type: 'button', class: (state.taskFilter || 'all') === key ? 'on' : null, onclick: () => { state.taskFilter = key; render(); },
  }, key === 'all' ? '全部' : '首次' + STATUS[key])));
  const search = h('input', { type: 'search', placeholder: '搜索任务', value: state.taskSearch || '', 'aria-label': '搜索任务',
    oninput: (e) => { state.taskSearch = e.target.value; drawTasks(); } });
  const tbody = h('tbody', {});
  function drawTasks() {
    const q = (state.taskSearch || '').trim().toLowerCase();
    const shown = b.tasks.filter((t) => (state.profileSuite || 'all') === 'all' || t.suite === state.profileSuite)
      .filter((t) => (state.profileModel || 'all') === 'all' || t.model === state.profileModel)
      .filter((t) => (state.taskFilter || 'all') === 'all' || t.first_status === state.taskFilter)
      .filter((t) => !q || t.task.toLowerCase().includes(q));
    tbody.replaceChildren(...(shown.length ? shown.map((t) => {
      const href = t.job ? `#/profile/${encodeURIComponent(b.id)}/task/${encodeURIComponent(t.job)}/${encodeURIComponent(t.task)}` : null;
      return h('tr', { class: href ? 'link' : null, onclick: href ? () => { location.hash = href; } : null },
        h('td', {}, h('span', { class: 'mono', text: t.task })),
        h('td', { text: t.suite_name || t.suite }),
        h('td', { text: t.model || '—' }),
        h('td', {}, t.attempts.length ? h('span', { class: 'dots' }, t.attempts.map((a) => h('a', { href: href + '/' + encodeURIComponent(a.trial), onclick: (e) => e.stopPropagation(), title: `第 ${a.attempt_number} 次 · ${STATUS[a.status] || a.status}${a.cause ? ' · ' + a.cause : ''}` }, badge(a.status)))) : h('span', { class: 'muted', text: '等待运行' })),
        h('td', { class: 'num', text: t.attempts.length ? `${t.passed} / ${t.valid}` : '—' }),
        h('td', { class: 'num', text: t.history.length ? `覆盖了 ${t.history.length} 次` : '—' }),
        h('td', { class: 'num', text: compact(t.mean_total_tokens) }),
        h('td', { class: 'num', text: compact(t.mean_initial_input_tokens) }),
        h('td', { class: 'num', text: t.mean_turns === null || t.mean_turns === undefined ? '—' : t.mean_turns.toFixed(1) }),
        h('td', { class: 'num', text: t.mean_tool_calls === null || t.mean_tool_calls === undefined ? '—' : t.mean_tool_calls.toFixed(1) }),
        h('td', { class: 'num', text: dur(t.mean_elapsed_s) }));
    }) : [h('tr', {}, h('td', { colspan: 11, class: 'empty', text: '没有符合条件的任务' }))]));
  }
  drawTasks();
  const tasks = panel('逐任务（最新结果）', `${b.tasks.length} 道`, h('div', {}, chips, modelChips,
    h('div', { class: 'panel-body toolbar' }, firstFilter, search),
    h('div', { class: 'table-scroll' }, h('table', {}, h('thead', {}, h('tr', {}, ['任务', '评测集', '模型', '各次结局', '通过 / 有效', '历史', '平均总 Token', '平均初始 Token', '平均轮数', '平均工具调用', '平均用时'].map((t, i) => h('th', { class: i >= 4 ? 'num' : null, text: t })))), tbody))));
  return h('div', {}, metrics, panel('评测配置', PROFILE_STATUS[b.status] || b.status, info, b.can_run ? h('div', { class: 'header-actions' }, profileActions(b, false)) : null), modelsPanel(b), items, tasks, compositionPanel(s, '最新结果均值'));
}

// The latest results of each model side by side, when the profile has several:
// over every task each ran, then, when they ran different tasks, over the tasks
// all of them ran, so a model is not judged on an easier subset.
function modelsPanel(b) {
  if ((b.by_model || []).length < 2) return null;
  const heads = ['模型', '题数', '结局分布', '一次性完成率', '通过 / 有效', '首轮满分率', '无效', '总 Token', '估算成本'];
  const row = (model, tasks, m) => h('tr', { class: 'link', onclick: () => { state.profileModel = model; render(); } },
    h('td', { text: model || '—' }),
    h('td', { class: 'num', text: String(tasks) }),
    h('td', {}, outcomeBar(m.counts, m.trials || 0)),
    h('td', { class: 'num', text: pct(m.one_shot_pass_rate) }),
    h('td', { class: 'num', text: `${m.counts.pass} / ${m.valid || 0}` }),
    h('td', { class: 'num', text: pct(m.first_pass_rate) }),
    h('td', { class: 'num', text: String(m.counts.invalid) }),
    h('td', { class: 'num', text: compact(m.total_tokens) }),
    h('td', { class: 'num', text: usd(m.cost_usd) }));
  const table = (rows) => h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, heads.map((t, i) => h('th', { class: i === 1 || i >= 3 ? 'num' : null, text: t })))),
    h('tbody', {}, rows)));
  const mixed = b.common_tasks !== null && b.common_tasks !== undefined;
  const body = [table(b.by_model.map((x) => row(x.model, x.tasks, x.summary)))];
  if (mixed) {
    body.push(h('div', { class: 'callout' }, h('p', { text: `各模型跑过的题不一样，上表不能直接比。下表只算所有模型都跑过的 ${b.common_tasks} 道题。` })),
      b.common_tasks ? table(b.by_model.map((x) => row(x.model, b.common_tasks, x.common_summary))) : h('div', { class: 'empty', text: '没有所有模型都跑过的题。' }));
  }
  return panel('模型对比', `${b.by_model.length} 个模型 · 各自的最新结果 · 点一行只看这个模型的逐任务结果`, h('div', {}, body));
}

async function renderProfileTask(profileId, jobName, taskName, trialName) {
  navCurrent('overview');
  const b = await api('/api/profile?id=' + encodeURIComponent(profileId));
  const ordered = b.tasks.filter((t) => t.job);
  const index = ordered.findIndex((t) => t.job === jobName && t.task === taskName);
  const group = ordered[index] || await historyGroup(b, jobName, taskName);
  if (!group) throw new Error('评测配置中没有这个任务');
  const chosen = group.attempts.find((a) => a.trial === trialName) || group.attempts[0];
  $('#title').textContent = taskName;
  crumbs([{ text: '看板', href: '#/' }, { text: '评测配置 ' + profileName(b), href: profileHref(b) },
    { text: group.suite_name || group.suite }, { text: taskName }]);
  const taskHref = (t) => `#/profile/${encodeURIComponent(b.id)}/task/${encodeURIComponent(t.job)}/${encodeURIComponent(t.task)}`;
  const prev = index >= 0 ? ordered[index - 1] : null; const next = index >= 0 ? ordered[index + 1] : null;
  const nav = h('div', { class: 'header-actions' },
    h('span', { class: 'muted num', text: index >= 0 ? `${index + 1} / ${ordered.length}` : '历史结果' }),
    prev ? h('a', { class: 'button', href: taskHref(prev), title: prev.task }, '← 上一个任务') : h('button', { class: 'button', type: 'button', disabled: true }, '← 上一个任务'),
    next ? h('a', { class: 'button', href: taskHref(next), title: next.task }, '下一个任务 →') : h('button', { class: 'button', type: 'button', disabled: true }, '下一个任务 →'));
  const history = (group.history || []).length ? h('div', { class: 'panel-body' }, h('small', { class: 'muted' }, '被覆盖的早先运行：',
    ...group.history.map((job) => h('a', { class: 'mono', href: taskHref({ job, task: taskName }), text: ' ' + job + ' ' })))) : null;
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
  const parts = [panel('各次尝试', `${group.attempts.length} 次 · 通过 ${group.passed} / 有效 ${group.valid}${group.model ? ' · ' + group.model : ''}`, h('div', {}, cards, compare, history), nav)];
  if (chosen) {
    const t = await api(`/api/trial?job=${encodeURIComponent(jobName)}&trial=${encodeURIComponent(chosen.trial)}`);
    state.live = t.row.status === 'running' || profileActive(b);
    parts.push(...trialBody(t));
  } else {
    state.live = profileActive(b);
  }
  return h('div', {}, parts);
}

// A task's attempts in a run a later one replaced, read from that job.
async function historyGroup(b, jobName, taskName) {
  const item = b.items.find((i) => i.run === jobName);
  if (!item) return null;
  const job = await api('/api/job?name=' + encodeURIComponent(jobName));
  const attempts = (job.rows || []).filter((r) => r.task === taskName).sort((x, y) => (x.attempt_number || 0) - (y.attempt_number || 0));
  if (!attempts.length) return null;
  return { task: taskName, job: jobName, suite: item.suite, suite_name: item.suite_name, model: item.model, attempts,
    passed: attempts.filter((a) => a.status === 'pass').length, valid: attempts.filter((a) => !['invalid', 'running'].includes(a.status)).length, history: [] };
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

async function renderNewRun() {
  state.live = false;
  navCurrent('new');
  $('#title').textContent = '发起评测';
  crumbs([{ text: '看板', href: '#/' }, { text: '选择 metacodes 版本和高级功能（即评测配置），再选评测集' }]);
  const c = await api('/api/workbench');
  const suites = c.suites || [];
  const byId = new Map(suites.map((s) => [s.id, s]));
  // Selected suites, in the order picked: id -> {tasks, defaults, selected, error, loaded}.
  if (!state.suitePick) state.suitePick = new Map();
  for (const id of [...state.suitePick.keys()]) if (!byId.has(id)) state.suitePick.delete(id);
  if (!state.suitePick.size && byId.has(c.default_suite)) state.suitePick.set(c.default_suite, null);
  const executorsList = c.executors || [];
  if (!executorsList.some((e) => e.name === state.executor)) state.executor = c.default_executor;
  const selectedExecutor = () => executorsList.find((e) => e.name === state.executor) || { reasons: [], ready: true };
  const comboReasons = (s) => ((s.executors || {})[state.executor] || s).reasons || [];
  const comboReady = (s) => !comboReasons(s).length;
  const form = h('form', { class: 'run-form' });
  const draft = state.runDraft || (state.runDraft = {});
  if (!state.taskWanted) state.taskWanted = new Map();

  const executor = h('select', { name: 'executor', onchange: () => {
    state.executor = executor.value;
    for (const [id, entry] of state.suitePick) {
      if (entry) state.taskWanted.set(id, [...entry.selected]);
      state.suitePick.set(id, null);
      loadTasks(id);
    }
    drawNotes(); drawPicker(); drawBoxes(); syncSubmit();
  } }, executorsList.map((e) => h('option', { value: e.name, selected: e.name === state.executor },
    e.label + (e.ready ? '' : ' · 待配置'))));
  const bundles = c.bundles || [];
  const fixed = Boolean(draft.profile);
  const picked = bundles.some((b) => b.id === state.pickBundle) ? state.pickBundle : null;
  const bundle = fixed
    ? h('select', { name: 'bundle', disabled: true }, h('option', { text: `${draft.label || '—'}（评测配置已冻结）` }))
    : h('select', { name: 'bundle', onchange: () => { state.pickBundle = bundle.value; } }, bundles.map((b) => h('option', { value: b.id, selected: picked ? b.id === picked : b.current },
      `${b.label}${b.current ? '（当前配置）' : ''}`)));
  const commitBox = h('div', { class: 'commit-builder', hidden: !state.commitsOpen });
  const commitToggle = h('button', { type: 'button', class: 'button', onclick: () => {
    state.commitsOpen = !state.commitsOpen;
    commitBox.hidden = !state.commitsOpen;
    if (state.commitsOpen && !commitBox.childElementCount) drawCommits();
  } }, '按 commit 编译…');
  const name = h('input', { name: 'name', type: 'text', maxlength: 80, value: draft.name || '', placeholder: '例如：v0.12 · 全部门控',
    oninput: () => { draft.name = name.value; } });
  const picker = h('div', { class: 'suite-picker' });
  const boxes = h('div', { class: 'stack' });
  const models = c.models || [];
  const known = (id) => models.some((m) => m.id === id);
  const modelMissing = (draft.models || []).find((id) => !known(id));
  const chosenModels = new Set((draft.models || []).filter(known));
  if (!chosenModels.size && known(c.default_model)) chosenModels.add(c.default_model);
  const modelChecks = models.map((m) => {
    const check = h('input', { type: 'checkbox', name: 'models', value: m.id, onchange: () => {
      if (check.checked) chosenModels.add(m.id); else chosenModels.delete(m.id);
      draft.models = models.filter((x) => chosenModels.has(x.id)).map((x) => x.id);
      syncSubmit();
    } });
    check.checked = chosenModels.has(m.id);
    return h('label', { class: 'task-option' }, check, h('span', { text: m.label }));
  });
  const model = h('div', { class: 'task-options', role: 'group', 'aria-label': '模型' }, modelChecks);
  const runDefaults = c.defaults || { attempts: 4, concurrency: 10 };
  const attempts = h('input', { name: 'attempts', type: 'number', inputmode: 'numeric', value: draft.attempts ?? runDefaults.attempts, min: 1, max: 5, step: 1, required: true,
    oninput: () => { draft.attempts = attempts.value; } });
  const concurrency = h('input', { name: 'concurrency', type: 'number', inputmode: 'numeric', value: draft.concurrency ?? runDefaults.concurrency, min: 1, max: 16, step: 1, required: true,
    oninput: () => { draft.concurrency = concurrency.value; } });
  const featureBoxes = (c.features || []).map((f) => ({ id: f.id, group: f.group,
    input: h('input', { type: 'checkbox', name: 'features', value: f.id, disabled: fixed,
      checked: (draft.features || c.default_features || []).includes(f.id),
      onchange: () => { draft.features = featureBoxes.filter((x) => x.input.checked).map((x) => x.id); } }), label: f.label }));
  const featureGroup = (group, title) => {
    const boxes = featureBoxes.filter((f) => f.group === group);
    return boxes.length ? h('div', { class: 'stack' }, h('small', { class: 'muted', text: title }),
      ...boxes.map((f) => h('label', { class: 'check' }, f.input, h('span', { text: f.label }), h('small', { class: 'mono muted', text: f.id })))) : null;
  };
  const features = featureBoxes.length ? h('fieldset', {}, h('legend', { text: fixed ? '高级功能（评测配置已固定）' : '高级功能（形式化门控默认开启，Preview 默认关闭）' }),
    featureGroup('formal', 'Lean 形式化门控'), featureGroup('preview', 'Preview 特性')) : '';
  const feedback = h('div', { role: 'status', class: 'form-feedback' });
  const submit = h('button', { type: 'submit', class: 'button primary', disabled: true }, '开始评测');

  function setupReasons() {
    const harbor = [...state.suitePick.keys()].some((id) => (byId.get(id) || {}).runner !== 'workbuddy');
    return [...(c.global_reasons || []), ...(harbor ? (c.harbor_reasons || []) : []),
      ...(harbor ? (selectedExecutor().reasons || []) : [])];
  }
  function syncSubmit() {
    const picked = [...state.suitePick.entries()];
    const total = picked.reduce((acc, [, e]) => acc + (e ? e.selected.size : 0), 0);
    const problems = picked.filter(([id, e]) => !comboReady(byId.get(id)) || !e || !e.selected.size || e.selected.size > byId.get(id).max_tasks);
    submit.disabled = !picked.length || !chosenModels.size || problems.length > 0 || !c.can_run || (!fixed && !bundles.length);
    const modelText = chosenModels.size > 1 ? ` · ${chosenModels.size} 个模型` : '';
    submit.textContent = picked.length ? `开始评测（${picked.length} 个评测集 · ${total} 道题 × ${attempts.value || '?'} 次${modelText}）` : '开始评测';
  }
  function drawPicker() {
    picker.replaceChildren(...(c.categories || []).map((cat) => {
      const members = suites.filter((s) => s.category === cat.id);
      if (!members.length) return null;
      return h('div', { class: members.length > 2 ? 'suite-group wide' : 'suite-group' },
        h('div', { class: 'suite-group-head' }, h('b', { text: cat.name })),
        h('div', { class: 'suite-cards' }, members.map((s) => h('button', {
          type: 'button', class: 'suite-card', 'aria-pressed': String(state.suitePick.has(s.id)), 'data-suite': s.id,
          onclick: () => {
            if (state.suitePick.has(s.id)) state.suitePick.delete(s.id); else { state.suitePick.set(s.id, null); loadTasks(s.id); }
            drawPicker(); drawNotes(); drawBoxes(); syncSubmit();
          },
        }, h('span', { class: 'suite-name', text: s.name }),
        h('span', { class: 'sub', text: (s.task_count === null ? '任务待准备' : s.task_count + ' 题') + ' · ' + (RUNNERS[s.runner] || s.runner) }),
        h('span', { class: 'suite-state ' + (comboReady(s) ? 'ok' : s.available ? 'todo' : 'off'), text: (state.suitePick.has(s.id) ? '已加入 · ' : '') + (comboReady(s) ? '可运行' : s.available ? '待配置' : '尚未接入') })))));
    }).filter(Boolean));
  }
  function suiteBox(s, entry) {
    const shown = new Set(setupReasons());
    const reasons = comboReasons(s).filter((text) => !shown.has(text));
    const remove = h('button', { type: 'button', class: 'button', onclick: () => { state.suitePick.delete(s.id); drawPicker(); drawBoxes(); syncSubmit(); } }, '移出');
    const head = h('div', { class: 'suite-box-head' }, h('span', {}), remove);
    const box = h('fieldset', {}, h('legend', { text: `${s.name} · ${(c.categories || []).find((x) => x.id === s.category)?.name || ''}` }), head,
      reasons.length ? h('div', { class: 'callout' }, reasons.map((text) => h('p', { text }))) : null);
    if (!entry) { box.append(h('div', { class: 'empty', text: '读取任务列表…' })); return box; }
    if (!entry.tasks.length) { box.append(h('div', { class: 'empty', text: entry.error || '该评测集暂无可选任务' })); return box; }
    if (entry.missing) box.append(h('div', { class: 'callout', text: `${draft.from ? '上次运行' : '之前选'}的 ${entry.missing} 道题不在当前执行机器的任务列表里，已略过。` }));
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
      list);
    drawList();
    return box;
  }
  function drawBoxes() {
    boxes.replaceChildren(...(state.suitePick.size ? [...state.suitePick.entries()].map(([id, entry]) => suiteBox(byId.get(id), entry))
      : [h('div', { class: 'empty', text: '选择评测集' })]));
  }
  async function loadTasks(id) {
    const wanted = state.executor;
    // Beside the shared task lists, so a form drawn again keeps counting.
    state.taskTickets = state.taskTickets || new Map();
    const ticket = (state.taskTickets.get(id) || 0) + 1;
    state.taskTickets.set(id, ticket);
    let entry = { tasks: [], defaults: [], selected: new Set(), error: null };
    try {
      const body = await api('/api/suite?id=' + encodeURIComponent(id) + '&executor=' + encodeURIComponent(wanted || ''));
      const tasks = body.tasks || [];
      const kept = state.taskWanted.get(id);
      const selected = kept ? kept.filter((t) => tasks.includes(t)) : body.default_tasks || [];
      entry = { tasks, defaults: body.default_tasks || [], selected: new Set(selected), error: body.error || null,
        missing: kept ? kept.length - selected.length : 0 };
    } catch (e) { entry.error = e.message; }
    // Only the suite's latest request counts: an older one may be for another
    // executor, or for this one before a switch away and back.
    if (state.suitePick.has(id) && state.taskTickets.get(id) === ticket) {
      if (!entry.error) state.taskWanted.delete(id);
      state.suitePick.set(id, entry); drawBoxes(); syncSubmit();
    }
  }
  attempts.addEventListener('input', syncSubmit);

  if (executorsList.length) {
    form.append(h('label', { class: 'field' }, h('span', { text: '执行机器' }), executor));
  }
  if (draft.from) {
    const notes = [`在评测配置「${draft.from}」上运行`];
    if (modelMissing) notes.push(`上次的模型 ${modelMissing} 当前不可用，请重新选择。`);
    form.append(h('div', { class: 'callout' }, notes.map((text) => h('p', { text })),
      h('button', { type: 'button', class: 'button', onclick: () => {
        state.runDraft = null; state.taskWanted = null; state.suitePick = null; state.pickBundle = null; render();
      } }, '改为新的评测配置')));
  }
  form.append(
    h('div', { class: 'form-row' },
      h('div', { class: 'field' }, h('label', { class: 'field' }, h('span', { text: 'metacodes 版本' }), bundle),
        fixed || bundles.length ? null : h('small', { text: '还没有可用的 Linux 发行包，请先运行一键配置。' }),
        c.can_run && !fixed ? h('div', {}, commitToggle) : null),
      fixed ? null : h('label', { class: 'field' }, h('span', { text: '评测配置名称（可选）' }), name)),
    fixed ? null : commitBox,
    features,
    h('div', { class: 'field' }, h('span', { text: '模型（可多选，每个评测集按每个模型各跑一次）' }), model,
      h('small', { text: c.authentication?.label || '使用执行服务上配置的 Provider 和凭证' }),
      h('small', {}, c.providers?.models ? `另有 ${c.providers.count} 个导入的 Provider · ${c.providers.models} 个模型 · ` : '',
        link('#/providers', '用 URL + API Key 导入 Provider')),
      c.account_summary ? h('small', { text: `${c.account_summary.available_groups} / ${c.account_summary.groups} 个模型组可用 · ${c.account_summary.models} 个模型` }) : null,
      c.reasoning_effort ? h('small', { text: '推理强度：' + c.reasoning_effort }) : null),
    h('fieldset', {}, h('legend', { text: '评测集（可多选）' }), picker), boxes,
    h('div', { class: 'form-row' }, h('label', { class: 'field' }, h('span', { text: '每题次数' }), attempts),
      h('label', { class: 'field' }, h('span', { text: '并发数' }), concurrency)),
    h('div', { class: 'form-submit' }, submit, feedback));
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    submit.disabled = true;
    feedback.textContent = fixed ? '正在排队…' : '正在冻结 metacodes 版本并排队…';
    try {
      const picked = models.filter((m) => chosenModels.has(m.id)).map((m) => m.id);
      const request = { ...(picked.length > 1 ? { models: picked } : { model: picked[0] }), attempts: Number(attempts.value), concurrency: Number(concurrency.value),
        items: [...state.suitePick.entries()].map(([id, entry]) => ({ suite: id, tasks: entry.tasks.filter((t) => entry.selected.has(t)) })) };
      if (fixed) request.profile = draft.profile;
      else {
        if (bundle.value) request.bundle = bundle.value;
        if (name.value.trim()) request.name = name.value.trim();
        request.features = featureBoxes.filter((f) => f.input.checked).map((f) => f.id);
      }
      if (executorsList.length) request.executor = executor.value;
      const record = await api('/api/profiles/run', request);
      state.suitePick = null;
      state.runDraft = null;
      state.taskWanted = null;
      state.scope = record.id;
      location.hash = profileHref(record);
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
    if (!suites.length) notes.push(...(c.reasons || []));
    if (!c.can_run) notes.push('只读模式，不能发起评测');
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
            ' 并输入代码 ', h('b', { class: 'mono', text: login.user_code || '' })) : h('p', { class: 'muted', text: '正在获取设备码…' }))));
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
  // Any commit of the source repository, picked by its time, built on the
  // selected executor's node and then offered as a version like any other.
  const until = h('input', { type: 'date', value: state.commitUntil || '', 'aria-label': '截止日期' });
  const branch = h('input', { type: 'text', value: state.commitRef || 'main', maxlength: 200, 'aria-label': '分支' });
  const refInput = h('input', { type: 'text', maxlength: 200, placeholder: '提交编号、分支或 tag', 'aria-label': '直接编译的 git 版本' });
  const commitList = h('div', { class: 'table-scroll commit-list' });
  const buildState = h('div', {});
  async function drawCommits() {
    state.commitUntil = until.value; state.commitRef = branch.value.trim() || 'main';
    commitList.replaceChildren(h('div', { class: 'empty', text: '读取提交历史…' }));
    let body;
    try {
      body = await api('/api/commits?ref=' + encodeURIComponent(state.commitRef) + (until.value ? '&until=' + encodeURIComponent(until.value) : ''));
    } catch (error) { commitList.replaceChildren(h('div', { class: 'callout', text: error.message })); return; }
    if (!body.commits.length) { commitList.replaceChildren(h('div', { class: 'empty', text: '这个时间之前没有提交' })); return; }
    commitList.replaceChildren(h('table', {}, h('thead', {}, h('tr', {}, h('th', { text: '提交时间' }), h('th', { text: '提交' }),
      h('th', { text: '说明' }), h('th', { text: '作者' }), h('th', {}))),
    h('tbody', {}, body.commits.map((x) => h('tr', {},
      h('td', { class: 'num', text: new Date(x.committed_at).toLocaleString('zh-CN', { hour12: false }) }),
      h('td', { class: 'mono', text: x.commit.slice(0, 10) }), h('td', { text: x.subject }), h('td', { text: x.author }),
      h('td', {}, x.bundle
        ? h('button', { type: 'button', class: 'button', onclick: () => { state.pickBundle = x.bundle; render(); } }, '已编译 · 选用')
        : h('button', { type: 'button', class: 'button', onclick: () => startBuild(x.commit) }, '编译')))))));
  }
  async function startBuild(ref) {
    try {
      await api('/api/build', { ref, executor: state.executor });
      await drawBuild();
    } catch (error) { buildState.replaceChildren(h('div', { class: 'callout', text: error.message })); }
  }
  async function drawBuild() {
    let latest = null;
    try { latest = (await api('/api/build')).build; } catch (_) { return; }
    if (!latest) { buildState.replaceChildren(); return; }
    const running = latest.status === 'running';
    const title = { running: '编译中', done: '已完成', failed: '失败', cancelled: '已取消', interrupted: '已中断' }[latest.status] || latest.status;
    const cancel = running ? h('button', { type: 'button', class: 'button', onclick: async () => {
      try { await api('/api/build/cancel', {}); } catch (error) { buildState.append(h('div', { class: 'callout', text: error.message })); }
    } }, '取消编译') : null;
    buildState.replaceChildren(h('div', { class: 'setup-step' },
      h('p', {}, h('b', { text: `${title} · ${latest.ref}` }), h('span', { class: 'muted', text: ` · 在 ${latest.executor} 上编译` }),
        latest.error ? h('span', { text: ' · ' + latest.error }) : null, ' ', cancel,
        latest.status === 'done' && latest.bundle ? h('button', { type: 'button', class: 'button', onclick: () => { state.pickBundle = latest.bundle; render(); } }, '选用这个版本') : null),
      (latest.log || []).length ? h('pre', { class: 'muted', text: latest.log.join('\n') }) : null));
    if (running && route().view === 'new' && commitBox.isConnected) setTimeout(drawBuild, 2000);
    else if (state.buildWatch === latest.id && latest.status === 'done') { state.buildWatch = null; state.pickBundle = latest.bundle; setTimeout(render, 300); }
    if (running) state.buildWatch = latest.id;
  }
  commitBox.append(
    h('div', { class: 'task-tools' }, h('span', { text: '分支' }), branch, h('span', { text: '截止到' }), until,
      h('button', { type: 'button', class: 'button', onclick: drawCommits }, '查询'),
      refInput, h('button', { type: 'button', class: 'button', onclick: () => { if (refInput.value.trim()) startBuild(refInput.value.trim()); } }, '编译这个版本')),
    buildState, commitList);
  if (c.can_run && state.commitsOpen) drawCommits();
  if (c.can_run) drawBuild();

  drawPicker();
  drawNotes();
  drawBoxes();
  for (const [id, entry] of state.suitePick) if (!entry) loadTasks(id);
  drawSetup();
  syncSubmit();
  const groupRows = (c.account_groups || []).map((g) => h('tr', {},
    h('td', { text: g.name }), h('td', { text: g.configured ? '已有账号 Key' : '尚未配置 Key' })));
  const groupTable = h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, h('th', {}, '模型组'), h('th', {}, '凭证状态'))), h('tbody', {}, groupRows)));
  const groups = groupRows.length ? panel('账号可选模型组', `${groupRows.length} 个`,
    h('div', { class: 'panel-body' },
      groupTable)) : null;
  return h('div', {}, callout, setupBox,
    panel('发起评测', null, form), groups);
}

async function renderRun(name) {
  const run = await api('/api/run?name=' + encodeURIComponent(name));
  let results;
  try { results = await renderJob(name); } catch (_) { results = h('div', { class: 'empty', text: '等待 Harbor 创建作业' }); }
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
    run.error ? h('p', { class: 'muted', text: run.error }) : null,
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
  crumbs([{ text: '看板', href: '#/' }, job.profile ? { text: '评测配置 ' + job.profile, href: '#/profile/' + encodeURIComponent(job.profile) } : null, { text: job.name }].filter(Boolean));
  const s = job.summary;
  const causes = Object.entries(s.invalid_causes).map(([k, v]) => `${k} ${v}`).join(' · ');
  const metrics = h('section', { class: 'metrics' }, measurementCards(s),
    metric('平均 reward', s.mean_reward === null ? '—' : s.mean_reward.toFixed(2)),
    metric('完成', `${s.trials - s.counts.running} / ${job.planned}`, job.running ? '运行中' : '已结束 · ' + dur(job.wall_s)),
    metric('无效', String(s.counts.invalid), causes || '无'),
    metric('空回复结束', String(s.empty_final)),
    metric('输入 / 输出 Token', `${compact(s.input_tokens)} / ${compact(s.output_tokens)}`, `缓存 ${pct(s.input_tokens ? s.cache_tokens / s.input_tokens : null)}`));

  const identity = h('div', { class: 'panel-body' },
    h('div', { class: 'muted' }, `${job.suite_name ? '评测集 ' + job.suite_name + '（' + job.category_name + '） · ' : ''}${job.metacodes?.label ? 'metacodes ' + job.metacodes.label + (job.metacodes.frozen ? '（评测配置冻结）' : '') + ' · ' : ''}模型 ${job.model || '—'} · agent ${job.agent || '—'} · 数据集 ${job.dataset || '—'} · 每题 ${job.attempts ?? '—'} 次 · 并发 ${job.concurrency ?? '—'}${job.judge ? ' · ' + judgeText(job.judge) : ''}`),
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

  const keys = h('div', { class: 'panel-body' }, PHASES.map(([k, l]) => h('span', { class: 'key' }, h('i', { class: 'p-' + k }), l)));
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
  if (!reqs.length) return panel('Token 分布', null, h('div', { class: 'empty', text: '没有逐请求数据' }));
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
      context, withParts ? keys(PARTS.map(([k, l]) => ['c-' + k, l])) : keys([['t-cached', '缓存命中'], ['t-input', '未缓存输入']]),
      withParts ? h('div', {}, h('p', { class: 'muted', text: '缓存命中 / 未缓存输入' }), columns(cache, true)) : null,
      h('p', { class: 'muted', text: '输出 Token' }), outputs,
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
    h('p', { class: 'muted', text: `agent ${dur(agent)}` }),
    stackBar(segs.map(([c, v, l]) => [c, v || 0, l])),
    keys(segs.map(([c, v, l]) => [c, `${l} ${dur(v)}${agent ? ' · ' + pct((v || 0) / agent) : ''}`])))
    : null;
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
    metric('测试', r.tests ? `${r.tests.passed}/${r.tests.total}` : '—'),
    metric('轮数 / 工具调用', `${int(r.turns)} / ${int(r.tool_calls)}`, '停止原因 ' + (r.stop_reason || '—')),
    metric('任务总 Token', int(r.total_tokens), `输入 ${int(r.input_tokens)}（含缓存）+ 输出 ${int(r.output_tokens)}${r.tokens_partial ? ' · 部分记录' : ''}`),
    metric('初始 Token', int(r.initial_input_tokens), null, false,
      r.initial_composition ? stackBar(compositionSegments(r.initial_composition), true) : null),
    metric('TPS（生成）', tps(r.tps)),
    metric('TTFT（均值）', ttft(r.ttft_ms), `P50 ${ttft(r.ttft_p50_ms)} · P95 ${ttft(r.ttft_p95_ms)}`),
    metric('估算成本', usd(r.cost_usd)),
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
  parts.push(panel('轨迹', `${t.steps.length} 步`, h('div', { class: 'panel-body timeline' }, steps.length ? steps : h('div', { class: 'empty', text: '还没有轨迹' }))));
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
    return panel('对比', null, h('div', { class: 'empty', text: '在看板勾选两个以上的作业' }));
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
    metric('共同首次有效题', String(common.length), null, true),
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
  return h('div', {}, metrics, costPassPanel(jobs, common), panel('逐题对比', null, table));
}
function commonCostPass(job, tasks) {
  if (!tasks.length) return null;
  let cost = 0; let passed = 0;
  for (const task of tasks) {
    const priced = job.rows.filter((r) => r.task === task && ['pass', 'partial', 'fail', 'timeout'].includes(r.status) && r.cost_usd !== null && r.cost_usd !== undefined);
    if (!priced.length) return null;
    cost += priced.reduce((sum, r) => sum + r.cost_usd, 0) / priced.length;
    passed += priced.filter((r) => r.status === 'pass').length / priced.length;
  }
  return { cost: cost / tasks.length, pass: passed / tasks.length };
}
function dominated(a, b) {
  return b.cost <= a.cost && b.pass >= a.pass && (b.cost < a.cost || b.pass > a.pass);
}
function costPassPanel(jobs, common) {
  const points = jobs.map((j) => commonCostPass(j, common));
  const rows = jobs.map((j, i) => {
    const s = j.summary; const point = points[i];
    const frontier = point && !points.some((other) => other && dominated(point, other));
    return h('tr', {},
      h('td', {}, h('span', { text: j.model || j.name }), h('span', { class: 'sub', text: j.name })),
      h('td', { class: 'num', text: pct(s.pass_rate) }, h('span', { class: 'sub', text: ciText(s.pass_rate_ci95) })),
      h('td', { class: 'num', text: `${s.tasks_solved || 0} / ${s.tasks_attempted || 0}` }),
      h('td', { class: 'num', text: usd(s.cost_per_task) }),
      h('td', { class: 'num', text: usd(s.cost_per_pass) }),
      h('td', { class: 'num', text: pct(s.non_pass_cost_share) }),
      h('td', { class: 'num', text: pct(s.cache_hit_rate) }),
      h('td', { class: 'num', text: fixed(s.turns_per_pass) }),
      h('td', { class: 'num', text: point ? pct(point.pass) : '—' }, h('span', { class: 'sub', text: point ? usd(point.cost) + ' / 题' : '' })),
      h('td', { text: frontier ? '是' : point ? '' : '—' }));
  });
  const heads = ['作业', '通过率（95% 区间）', '至少通过一次', '每题平均成本', '每次通过成本', '未通过成本占比', '缓存命中率', '通过平均轮数', '共同题通过率 / 成本', '成本-通过率前沿'];
  return panel('成本与通过率', `${common.length} 道共同题`,
    h('div', { class: 'table-scroll' }, h('table', {},
      h('thead', {}, h('tr', {}, heads.map((t, i) => h('th', { class: i === 0 || i === heads.length - 1 ? null : 'num', text: t })))),
      h('tbody', {}, rows))));
}

// ------------------------------------------------------------ public leaderboards
function score(x) { return x === null || x === undefined ? '—' : x.toFixed(1) + '%'; }
function modelKey(m) { return String(m || '').toLowerCase().replace(/^.*\//, '').replace(/[^a-z0-9]/g, ''); }
function boardModels(board) {
  return board.model_filter ? [...new Set(board.entries.map((e) => e.model))] : [];
}
function boardRows(board, model) {
  const pooled = model === board.default_model;
  const published = board.entries.filter((e) => !board.model_filter || e.model === model)
    .map((e, i) => ({ ...e, id: 'p' + i, ours: null }));
  const ours = board.jobs.filter((j) => j.ranked && (!board.model_filter || pooled || modelKey(j.model) === modelKey(model)))
    .map((j) => ({ id: 'o-' + j.name, ours: j, harness: 'metacodes', model: j.model, score: j.score * 100,
      stderr: null, cost_per_task_usd: j.cost_per_task, date: (j.started_at || '').slice(0, 10) || null }));
  const rows = [...published, ...ours].sort((x, y) => y.score - x.score || Boolean(y.ours) - Boolean(x.ours));
  for (const r of rows) r.rank = 1 + published.filter((o) => o !== r && o.score > r.score).length;
  return { rows, published: published.length };
}
function svg(tag, attrs, ...children) {
  const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [key, value] of Object.entries(attrs)) if (value !== null && value !== undefined) el.setAttribute(key, String(value));
  for (const child of children) if (child) el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return el;
}
const rowName = (r) => (r.ours ? `metacodes · ${r.model || r.ours.name}` : r.harness);
const beats = (a, b) => a.cost_per_task_usd <= b.cost_per_task_usd && a.score >= b.score && (a.cost_per_task_usd < b.cost_per_task_usd || a.score > b.score);
function arrangeLabels(plot) {
  const box = plot.getBoundingClientRect();
  if (!box.width) return;
  const labels = [...plot.querySelectorAll('.scatter-label')];
  const dots = [...plot.querySelectorAll('.scatter-point .dot')].map((m) => [m.closest('.scatter-point'), m.getBoundingClientRect()]);
  const placed = [];
  const overlaps = (a, b) => a.left < b.right + 4 && a.right > b.left - 4 && a.top < b.bottom + 2 && a.bottom > b.top - 2;
  const tries = [0, -14, 14, -28, 28].flatMap((dy) => [['right', dy], ['left', dy]]);
  labels.sort((x, y) => Number(y.closest('.scatter-point').dataset.ours) - Number(x.closest('.scatter-point').dataset.ours));
  for (const label of labels) {
    const own = label.closest('.scatter-point');
    label.hidden = false;
    const fits = tries.some(([side, dy]) => {
      label.dataset.side = side;
      label.style.setProperty('--dy', dy + 'px');
      const r = label.getBoundingClientRect();
      return r.left >= box.left && r.right <= box.right && r.top >= box.top && r.bottom <= box.bottom
        && !placed.some((o) => overlaps(r, o)) && !dots.some(([p, m]) => p !== own && overlaps(r, m));
    });
    if (fits) placed.push(label.getBoundingClientRect());
    else label.hidden = true;
  }
}
function costScatter(rows, focus) {
  const points = rows.filter((r) => r.cost_per_task_usd > 0);
  if (points.length < 2 || !points.some((r) => !r.ours)) return null;
  const costs = points.map((r) => Math.log(r.cost_per_task_usd)); const scores = points.map((r) => r.score);
  const range = (v) => { const lo = Math.min(...v); const hi = Math.max(...v); const pad = (hi - lo || 1) * 0.08; return [lo - pad, hi + pad]; };
  const [x0, x1] = range(costs); const [y0, y1] = range(scores);
  const px = (r) => (Math.log(r.cost_per_task_usd) - x0) / (x1 - x0) * 100;
  const py = (r) => (r.score - y0) / (y1 - y0) * 100;
  const frontier = points.filter((r) => !points.some((o) => o !== r && beats(o, r))).sort((p, q) => p.cost_per_task_usd - q.cost_per_task_usd);
  const leaders = points.filter((r) => !r.ours).sort((p, q) => q.score - p.score).slice(0, 3);
  const named = points.filter((r) => frontier.includes(r) || leaders.includes(r));
  const repeated = new Set(named.filter((r, i) => named.findIndex((o) => rowName(o) === rowName(r)) !== i).map(rowName));
  const label = (r) => (r.ours ? rowName(r) : repeated.has(r.harness) ? `${r.harness} · ${r.model}` : r.harness);
  const layer = svg('svg', { class: 'scatter-layer', viewBox: '0 0 100 100', preserveAspectRatio: 'none', 'aria-hidden': 'true' },
    svg('polyline', { class: 'frontier', points: frontier.map((r) => `${px(r)},${100 - py(r)}`).join(' ') }));
  const ticks = [0, 1, 2].map((i) => 0.12 + i * 0.38);
  const grid = [
    ...ticks.map((t) => h('div', { class: 'grid-y', style: `bottom:${t * 100}%` }, h('span', { text: (y0 + (y1 - y0) * t).toFixed(0) + '%' }))),
    ...ticks.map((t) => { const v = Math.exp(x0 + (x1 - x0) * t); return h('div', { class: 'grid-x', style: `left:${t * 100}%` }, h('span', { text: '$' + v.toFixed(v < 1 ? 2 : 1) })); }),
  ];
  const tip = h('div', { class: 'scatter-tip', hidden: true });
  const dots = new Map(points.map((r) => {
    const kind = r.ours ? 'ours' : frontier.includes(r) ? 'frontier' : 'other';
    return [r, h('button', { type: 'button', class: 'scatter-point', 'data-kind': kind, 'data-ours': r.ours ? '1' : '0',
      style: `left:${px(r)}%;bottom:${py(r)}%`,
      'aria-label': `${rowName(r)} · ${r.model || ''} · ${score(r.score)} · ${usd(r.cost_per_task_usd)}`,
      onmouseenter: () => focus.set(r), onmouseleave: () => focus.set(null), onfocus: () => focus.set(r), onblur: () => focus.set(null),
      onclick: r.ours ? () => { location.hash = '#/job/' + encodeURIComponent(r.ours.name); } : null },
    h('i', { class: 'dot' }), r.ours || named.includes(r) ? h('span', { class: 'scatter-label', text: label(r) }) : null)];
  }));
  const plot = h('div', { class: 'scatter-plot' }, ...grid, layer, ...dots.values(), tip);
  focus.on((active) => {
    const a = dots.has(active) ? active : null;
    plot.toggleAttribute('data-active', Boolean(a));
    for (const [r, dot] of dots) {
      dot.toggleAttribute('data-current', r === a);
      dot.toggleAttribute('data-killed', Boolean(a && r !== a && beats(a, r)));
    }
    tip.hidden = !a;
    if (!a) return;
    tip.replaceChildren(h('b', { text: a.ours ? 'metacodes（我们）' : a.harness }), h('span', { text: a.model || '—' }),
      h('span', { class: 'num', text: `${score(a.score)} · ${usd(a.cost_per_task_usd)}` }));
    tip.style.left = px(a) + '%';
    tip.style.bottom = py(a) + '%';
    tip.dataset.side = px(a) > 60 ? 'left' : 'right';
  });
  new ResizeObserver(() => arrangeLabels(plot)).observe(plot);
  return h('div', { class: 'scatter-box' }, h('div', { class: 'scatter-frame' }, h('div', { class: 'axis-y', text: '分数' }), plot,
    h('div', { class: 'axis-x', text: '每题成本' })));
}
function focusHub() {
  const listeners = [];
  return { on: (fn) => listeners.push(fn), set: (row) => listeners.forEach((fn) => fn(row)) };
}
function leaderCards(rows, published) {
  const pub = rows.filter((r) => !r.ours);
  const priced = pub.filter((r) => r.cost_per_task_usd > 0);
  const best = pub[0];
  const cheapest = priced.length ? [...priced].sort((a, b) => a.cost_per_task_usd - b.cost_per_task_usd || b.score - a.score)[0] : null;
  const ours = rows.find((r) => r.ours);
  return h('section', { class: 'metrics leaders' },
    best ? metric('最高分', score(best.score), `${best.harness} · ${best.model || '—'}`) : null,
    cheapest ? metric('最低成本', usd(cheapest.cost_per_task_usd), `${cheapest.harness} · ${score(cheapest.score)}`) : null,
    metric('我们的名次', ours ? `${ours.rank} / ${published + 1}` : '—', ours ? `${score(ours.score)} · ${ours.model || ''}` : null, true));
}
const BOARD_TOP = 10;
function boardPanel(board) {
  const key = board.suites.join(',') + '|' + board.title;
  const models = boardModels(board);
  const model = models.includes(state.boardModel[key]) ? state.boardModel[key] : (board.default_model || models[0] || null);
  const { rows, published } = boardRows(board, model);
  const focus = focusHub();
  const src = board.source;
  const redraw = (e) => e.target.closest('.panel').replaceWith(boardPanel(board));
  const picker = models.length ? h('select', { class: 'board-model', 'aria-label': '模型', onchange: (e) => { state.boardModel[key] = e.target.value; redraw(e); } },
    models.map((m) => h('option', { value: m, selected: m === model, text: m === board.default_model ? '全部模型' : m }))) : null;
  const sourceLink = h('a', { class: 'board-link', href: src.url, target: '_blank', rel: 'noopener noreferrer', title: `${src.name} · ${src.retrieved}`, text: '来源 ↗' });
  const expanded = Boolean(state.boardExpanded[key]);
  const shown = expanded ? rows : rows.filter((r, i) => i < BOARD_TOP || r.ours);
  const top = Math.max(...rows.map((r) => r.score), 1);
  const rowNodes = new Map(shown.map((r) => [r, h('tr', { class: r.ours ? 'ours link' : null, title: r.ours ? r.ours.name : null,
    onmouseenter: () => focus.set(r), onmouseleave: () => focus.set(null),
    onclick: r.ours ? () => { location.hash = '#/job/' + encodeURIComponent(r.ours.name); } : null },
  h('td', { class: 'num rank', text: String(r.rank) }),
  h('td', { text: r.ours ? 'metacodes' : r.harness }),
  h('td', { class: 'muted', text: r.model || '—' }),
  h('td', {}, h('div', { class: 'score-cell' }, h('span', { class: 'score-bar' }, h('span', { style: `width:${Math.max(r.score / top * 100, 1)}%` })),
    h('span', { class: 'num', text: score(r.score) }))),
  h('td', { class: 'num muted', text: usd(r.cost_per_task_usd) }))]));
  focus.on((active) => { for (const [r, tr] of rowNodes) tr.classList.toggle('active', r === active); });
  const more = rows.length > shown.length || expanded ? h('button', { type: 'button', class: 'board-more',
    onclick: (e) => { state.boardExpanded[key] = !expanded; redraw(e); } }, expanded ? '收起' : `全部 ${rows.length} 条`) : null;
  const table = h('div', { class: 'table-scroll' }, h('table', { class: 'board' },
    h('thead', {}, h('tr', {}, ['#', 'Harness', '模型', '分数', '每题成本'].map((t, i) => h('th', { class: [0, 4].includes(i) ? 'num' : null, text: t })))),
    h('tbody', {}, [...rowNodes.values()])), more);
  return panel(board.title, null, h('div', { class: 'panel-body' }, leaderCards(rows, published), costScatter(rows, focus), table),
    h('div', { class: 'board-actions' }, picker, sourceLink));
}
async function renderLeaderboard(suiteId) {
  state.live = false;
  navCurrent('leaderboard');
  $('#title').textContent = '公开榜单';
  const d = await api('/api/leaderboard' + (suiteId ? '?suite=' + encodeURIComponent(suiteId) : ''));
  crumbs([{ text: '看板', href: '#/' }, { text: '公开榜单' }]);
  const suitePicker = h('label', { class: 'scope' }, '评测集',
    h('select', { onchange: (e) => { location.hash = '#/leaderboard/' + encodeURIComponent(e.target.value); } },
      d.suites.map((s) => h('option', { value: s.suite, selected: s.suite === d.suite, text: s.suite_name }))));
  const partial = d.unranked;
  const rest = partial.length ? panel('未参与排名的作业', null, h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['作业', '模型', '题数', '分数'].map((t, i) => h('th', { class: i > 1 ? 'num' : null, text: t })))),
    h('tbody', {}, partial.map((j) => h('tr', { class: 'link', onclick: () => { location.hash = '#/job/' + encodeURIComponent(j.name); } },
      h('td', { text: j.name }), h('td', { text: j.model || '—' }),
      h('td', { class: 'num', text: `${j.tasks} / ${d.task_count}` }), h('td', { class: 'num', text: pct(j.score, 1) }))))))) : null;
  return h('div', {}, h('div', { class: 'board-bar' }, suitePicker), d.boards.map((b) => boardPanel(b)), rest);
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
    h('dt', { text: '内容' }), h('dd', { text: `评测配置 ${counts.profiles ?? 0} · 作业 ${counts.jobs ?? 0} · trial ${counts.trials ?? 0} · 请求 ${counts.requests ?? 0} · 文件 ${counts.files ?? 0} · 启动记录 ${counts.runs ?? 0}` }),
    h('dt', { text: '最近导入' }), h('dd', { text: st.last_ingested_at ? when(st.last_ingested_at) : '—' }),
    h('dt', { text: '待重算投影' }), h('dd', { text: String(st.stale_projections) }),
    h('dt', { text: '同步的作业目录' }), h('dd', { class: 'mono', text: (st.jobs_dirs || []).join('\n') || '—' }),
    st.records_dir ? h('dt', { text: '启动记录目录' }) : null, st.records_dir ? h('dd', { class: 'mono', text: st.records_dir }) : null,
    st.config_path ? h('dt', { text: '配置文件' }) : null, st.config_path ? h('dd', { class: 'mono', text: st.config_path }) : null),
));

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
  const sqliteFields = h('label', { class: 'field' }, h('span', { text: 'SQLite 文件' }), path);
  const pgFields = h('div', { class: 'stack' },
    h('label', { class: 'field' }, h('span', { text: 'PostgreSQL DSN' }), dsn, st.psycopg ? null : h('small', { text: '未安装 psycopg，可在新建页运行一键配置' })),
    h('label', { class: 'field' }, h('span', { text: '密码环境变量（可选）' }), passwordEnv));
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
        result.textContent = body.exists ? `连接成功：${body.database.format} ${body.database.location}（schema v${body.database.schema_version}）${body.same ? ' · 就是当前数据库' : ''}\n已有：作业 ${body.counts.jobs} · trial ${body.counts.trials} · 评测配置 ${body.counts.profiles ?? 0}` : `可用：${body.message}`;
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
    h('div', { class: 'radio-row' }, radio('sqlite', 'SQLite'), radio('postgres', 'PostgreSQL')),
    sqliteFields, pgFields,
    h('label', { class: 'check' }, migrate, '迁移当前数据'),
    h('div', { class: 'header-actions' }, testBtn, applyBtn), result)
    : h('div', { class: 'empty', text: '只读模式' });
  return h('div', {}, current, panel('配置数据库', null, form));
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
    return h('div', { class: 'empty', text: e.message || '只读模式' });
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
    h('tbody', {}, rows))) : h('div', { class: 'empty', text: '还没有导入 Provider' });

  const id = h('input', { type: 'text', required: true, maxlength: 32, pattern: '[a-z0-9][a-z0-9_\\-]{0,31}', placeholder: 'my-gateway', 'aria-label': 'Provider 标识' });
  const name = h('input', { type: 'text', maxlength: 80, placeholder: '例如：My Gateway', 'aria-label': '显示名称' });
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
      h('label', { class: 'field' }, h('span', { text: 'Provider 标识' }), id),
      h('label', { class: 'field' }, h('span', { text: '显示名称（可选）' }), name)),
    h('label', { class: 'field' }, h('span', { text: 'Base URL' }), baseUrl),
    h('div', { class: 'form-row' },
      h('label', { class: 'field' }, h('span', { text: '协议' }), protocol),
      h('label', { class: 'field' }, h('span', { text: '认证' }), auth)),
    h('label', { class: 'field' }, h('span', { text: 'API Key' }), key),
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
      table, result)),
    panel('导入 Provider', null, form));
}

// ------------------------------------------------------------ refresh loop
function tick() {
  const label = $('#countdown');
  if (state.editing) { label.textContent = '编辑中'; return; }
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

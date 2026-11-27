'use strict';
// Harbor bench viewer. Every value from the API reaches the page through
// textContent or CSSOM properties, never as markup.

const STATUS = {
  pass: '通过', partial: '部分通过', fail: '失败', timeout: 'agent 超时',
  invalid: '无效', running: '运行中',
};
const ORDER = ['pass', 'partial', 'fail', 'timeout', 'invalid', 'running'];
const PHASES = [['environment', '环境'], ['setup', '安装'], ['agent', 'agent'], ['verifier', '判分']];
const PREPARE_PARTS = [['prepare_s', '预准备', 'l-prepare'], ['ready_wait_s', '就绪等待', 'l-ready'], ['unprepared_wait_s', '准备失败后等待', 'l-unprepared'], ['prepare_running_s', '开始后准备', 'l-running']];
const PREPARE_RESULTS = { present: '命中', pulled: '拉取', built: '构建', failed: '失败' };
function timeParts(r) {
  const own = r.lifecycle ? PREPARE_PARTS.map(([k, l, cls]) => [cls, r.lifecycle[k], l]) : [];
  return own.concat(PHASES.map(([k, l]) => ['p-' + k, r.phases[k], l]));
}
function timeTotal(r) { return timeParts(r).reduce((acc, [, v]) => acc + (v || 0), 0); }
function timeTitle(r) {
  const queue = r.lifecycle ? `排队 ${dur(r.lifecycle.queue_s)}（不计入） · ` : '';
  return queue + timeParts(r).filter(([, v]) => v !== null && v !== undefined).map(([, v, l]) => `${l} ${dur(v)}`).join(' · ');
}
const REFRESH_S = 10;

const PROFILE_COLORS = ['#6a9dd9', '#71b69e', '#d8af65', '#a99be0', '#eb7c8e', '#5cb8c8', '#c76f5e'];
const profileColor = (index) => PROFILE_COLORS[index % PROFILE_COLORS.length];

const state = { auto: true, countdown: REFRESH_S, timer: null, busy: false, overviewDirty: false, live: false,

  jobFilter: 'all', jobSearch: '', suite: null, comparisons: new Map(), sort: { key: 'task', dir: 1 }, selected: new Set(),
  suitePick: null, profileSuite: 'all', profileModel: 'all', taskFilter: 'all', taskSearch: '', taskSort: 'default',
  profileId: null, profileExpanded: false, selectedTaskKey: null, drawerClosed: false,
  overviewFilter: 'all', overviewSearch: '', overviewSort: 'recent',
  boardModel: {}, boardExpanded: {}, boardSelected: {}, boardPareto: {},
  compareBaseline: null, compareFilter: 'all', compareSearch: '' };

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
    metric('TTFT（均值）', ttft(s.ttft_ms), `P50 ${ttft(s.ttft_p50_ms)} · P95 ${ttft(s.ttft_p95_ms)} · ${s.ttft_count ?? s.ttft_samples_ms?.length ?? 0} 个请求`),
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
  if (parts[0] === 'settings') return { view: 'settings', tab: parts[1] || 'database' };
  if (parts[0] === 'providers') return { view: 'settings', tab: 'providers' };
  if (parts[0] === 'monitor') return { view: 'monitor', executor: parts[1] || null };
  if (parts[0] === 'run' && parts[1]) return { view: 'run', name: parts[1] };
  if (parts[0] === 'profile' && parts[1] && parts[2] === 'task' && parts[3] && parts[4]) return { view: 'task', profile: parts[1], job: parts[3], task: parts[4], trial: parts[5] || null };
  if (parts[0] === 'profile' && parts[2] === 'compare' && parts[3]) return { view: 'compare', profile: parts[1], jobs: parts[3].split(',') };
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

function localView(build) {
  const root = h('div', {});
  function redraw() {
    const prev = new Map([...(root.querySelectorAll ? root.querySelectorAll('details[data-key]') : [])].map((d) => [d.dataset.key, d.open]));
    state.editing = false;
    root.replaceChildren(...[build(redraw)].flat(Infinity).filter(Boolean));
    for (const d of (root.querySelectorAll ? root.querySelectorAll('details[data-key]') : [])) {
      if (prev.has(d.dataset.key)) d.open = prev.get(d.dataset.key);
    }
  }
  redraw();
  return root;
}

async function render() {
  if (state.busy) return;
  state.busy = true;
  state.editing = false;
  if (location.hash === '#/new') history.replaceState(null, '', '#/');
  const hash = location.hash;
  const r = route();
  try {
    $('#create-run').hidden = true;
    let node;
    if (r.view === 'settings') node = await renderSettings(r.tab);
    else if (r.view === 'monitor') node = await renderMonitor(r.executor);
    else if (r.view === 'run') node = await renderRun(r.name);
    else if (r.view === 'overview') node = await renderOverview();
    else if (r.view === 'profile') node = await renderProfile(r.profile);
    else if (r.view === 'task') node = await renderProfileTask(r.profile, r.job, r.task, r.trial);
    else if (r.view === 'job') node = await renderJob(r.job);
    else if (r.view === 'trial') node = await renderTrial(r.job, r.trial);
    else if (r.view === 'leaderboard') node = await renderLeaderboard(r.suite);
    else node = await renderCompare(r.jobs, r.profile);
    // Keep open <details> and scroll position across a live refresh.
    const open = new Set([...document.querySelectorAll('#app details[open]')].map((d) => d.dataset.key));
    const oldChart = $('.trace-chart');
    const newChart = node.querySelector('.trace-chart');
    const sameTrace = oldChart && newChart && oldChart.dataset.scope === newChart.dataset.scope;
    const scrollLeft = sameTrace ? oldChart.parentElement.scrollLeft : 0;
    const focused = document.activeElement;
    const focusKey = sameTrace && oldChart.contains(focused) ? focused.dataset.key : null;
    const focusScroller = sameTrace && oldChart.parentElement === focused;
    $('#app').replaceChildren(node);
    if (sameTrace) {
      newChart.parentElement.scrollLeft = scrollLeft;
      const target = focusScroller ? newChart.parentElement : focusKey && newChart.querySelector(`[data-key="${CSS.escape(focusKey)}"]`);
      if (target) target.focus({ preventScroll: true });
    }
    for (const d of document.querySelectorAll('#app details')) if (open.has(d.dataset.key)) d.open = true;
    setConnection(true);
    $('#updated').textContent = '更新于 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false });
  } catch (e) {
    setConnection(false, '读取失败：' + e.message + '（保留上一次的数据）');
  } finally {
    state.busy = false;
    if (hash !== location.hash || (state.overviewDirty && r.view === 'overview')) render();
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
const ITEM_STATUS = { pending: '等待', running: '运行中', finished: '完成', failed: '执行失败', cancelled: '已停止', interrupted: '中断', skipped: '已取消' };
const profileActive = (b) => ['queued', 'running', 'cancelling'].includes(b.status);
const profileName = (b) => b.name || b.default_name || b.id;
const profileHref = (b) => '#/profile/' + encodeURIComponent(b.id);
const featuresText = (b) => (b.features || []).join(', ') || '未开启';
const skippedFeatures = (b, item) => item.features ? (b.features || []).filter((name) => !item.features.includes(name)) : [];

// Fills the run form for another run on profile `b` with one model (the
// page's model filter, else the last run's): that model's suites and tasks
// from the task rows (on the profile page) or the queued datasets, or only
// the tasks whose latest attempts include an invalid one.
const hasInvalid = (t) => t.attempts.some((a) => a.status === 'invalid');
function runModel(b) {
  return b.tasks && state.profileModel && state.profileModel !== 'all' ? state.profileModel : b.items[b.items.length - 1]?.model;
}
function runAgain(b, onlyInvalid) {
  const last = b.items[b.items.length - 1] || {};
  const model = runModel(b);
  const lastOfModel = [...b.items].reverse().find((i) => i.model === model) || last;
  state.runDraft = { profile: b.id, from: profileName(b), label: b.metacodes?.label, features: b.features || [],
    models: [model], attempts: lastOfModel.attempts, concurrency: b.concurrency };
  state.executor = lastOfModel.executor;
  const wanted = new Map();
  const add = (suite, task) => { if (!wanted.has(suite)) wanted.set(suite, []); if (!wanted.get(suite).includes(task)) wanted.get(suite).push(task); };
  if (b.tasks) {
    for (const t of b.tasks.filter((x) => x.model === model)) if (!onlyInvalid || hasInvalid(t)) add(t.suite, t.task);
  } else {
    for (const item of b.items.filter((i) => i.model === model)) for (const task of item.tasks || []) add(item.suite, task);
  }
  state.suitePick = new Map([...wanted.keys()].map((id) => [id, null]));
  state.taskWanted = wanted;
  openRunDialog();
}
async function deleteProfile(b, button) {
  if (!confirm(`删除 Profile ${profileName(b)}？工作台会删除运行记录、本机评测结果和汇总。远程 worker 会保留作业详情。`)) return false;
  button.disabled = true;
  try { await api('/api/profile/delete', { id: b.id }); }
  catch (error) { button.disabled = false; setConnection(false, error.message); return false; }
  state.selected.delete(b.id);
  return true;
}
function deleteProfileButton(b) {
  return h('button', { type: 'button', class: 'button', onclick: async (event) => {
    event.stopPropagation();
    if (!await deleteProfile(b, event.currentTarget)) return;
    const current = route();
    if (current.view === 'overview') {
      state.overviewDirty = true;
      render();
    } else if (current.view === 'profile' && current.profile === b.id) {
      location.hash = '#/';
    }
  } }, '删除 Profile');
}
async function deleteJob(j, button) {
  const impact = j.result_owner ? `工作台会删除运行记录和汇总，作业详情保留在 ${j.result_owner}。` : '工作台会删除运行记录、日志和评测结果，不能恢复。';
  if (!confirm(`删除评测结果 ${j.name}？${impact}`)) return;
  button.disabled = true;
  try { await api('/api/job/delete', { name: j.name }); }
  catch (error) { button.disabled = false; setConnection(false, error.message); return; }
  render();
}
async function stopProfile(b, button) {
  if (!confirm(`停止Profile ${profileName(b)} 的队列？正在运行的评测集会被取消，还没开始的评测集不再运行。`)) return;
  button.disabled = true;
  try { await api('/api/profile/cancel', { id: b.id }); state.countdown = 1; }
  catch (error) { button.disabled = false; setConnection(false, error.message); }
}
const ITEM_ACTIONS = {
  cancel: { label: '取消', ask: '取消这个评测集？它不再运行，队列里的其他评测集照常运行。' },
  stop: { label: '停止', ask: '停止这个评测集？已经跑完的题保留结果，队列接着运行下一个评测集。' },
  resume: { label: '继续', ask: null },
  run: { label: '运行', ask: null },
};
function itemActions(b, index) {
  const item = b.items[index];
  const names = item.status === 'pending' ? ['cancel'] : item.status === 'running' ? ['stop']
    : ['cancelled', 'interrupted', 'failed'].includes(item.status) && item.run ? ['resume', 'run'] : ['run'];
  return names.map((name) => h('button', { type: 'button', class: 'button',
    title: { resume: '只运行还没跑完的题', run: '把这个评测集的题全部再运行一次' }[name] || null,
    onclick: async (event) => {
      event.stopPropagation();
      const button = event.currentTarget;
      if (ITEM_ACTIONS[name].ask && !confirm(ITEM_ACTIONS[name].ask)) return;
      button.disabled = true;
      try { await api('/api/profile/item', { id: b.id, index: item.index ?? index, action: name }); await render(); }
      catch (error) { button.disabled = false; setConnection(false, error.message); }
    } }, ITEM_ACTIONS[name].label));
}
function profileActions(b) {
  const keep = (handler) => (event) => { event.stopPropagation(); handler(event.currentTarget); };
  return [
    b.tasks && b.tasks.some((t) => t.model === runModel(b) && hasInvalid(t))
      ? h('button', { type: 'button', class: 'button', title: '只选最新结果里有无效尝试的题（网络波动、环境故障等导致）', onclick: keep(() => runAgain(b, true)) }, '重跑无效的题') : null,
    profileActive(b)
      ? h('button', { type: 'button', class: 'button', onclick: keep((button) => stopProfile(b, button)) }, '停止队列')
      : deleteProfileButton(b),
  ];
}
function progressText(b) {
  return b.progress ? `${b.progress.done} / ${b.progress.planned} trial` : '—';
}

function groupedItems(b) {
  const groups = new Map();
  b.items.forEach((item, index) => {
    if (!groups.has(item.submission)) groups.set(item.submission, []);
    groups.get(item.submission).push({ item, index });
  });
  return [...groups].map(([id, entries], index) => ({ id, entries, label: '作业 ' + (index + 1) })).reverse();
}

function comparisonPicker(profiles, crossProfile) {
  const bySuite = new Map();
  for (const profile of profiles) {
    for (const group of groupedItems(profile)) {
      for (const { item } of group.entries) {
        if (!item.job) continue;
        if (!bySuite.has(item.suite)) bySuite.set(item.suite, []);
        bySuite.get(item.suite).push({ run: item.job.name, suite: item.suite_name || item.suite,
          owner: crossProfile ? profile.id : group.id,
          label: [crossProfile ? profileName(profile) : null, group.label, item.model, item.tasks?.length ? `${item.tasks.length} 题` : null, item.run].filter(Boolean).join(' · ') });
      }
    }
  }
  const choices = [...bySuite].filter(([, entries]) => new Set(entries.map((e) => e.owner)).size > 1);
  if (!choices.length) return h('p', { class: 'muted', text: '需要两个' + (crossProfile ? ' Profile' : '作业') + '都有同一评测集的结果。' });
  const key = profiles.map((p) => p.id).join(',');
  const picked = state.comparisons.get(key) || {};
  const suite = h('select', { 'aria-label': '对比评测集' }, choices.map(([id, entries]) =>
    h('option', { value: id, selected: id === picked.suite }, entries[0].suite)));
  const left = h('select', { 'aria-label': '第一份结果' });
  const right = h('select', { 'aria-label': '第二份结果' });
  const compare = h('a', { class: 'button', text: '逐题对比' });
  const options = (entries, selected) => entries.map((e) => h('option', { value: e.run, selected: e.run === selected }, e.label));
  function selectPair() {
    const entries = bySuite.get(suite.value);
    const first = entries.find((e) => e.run === left.value) || entries[0];
    right.replaceChildren(...options(entries.filter((e) => e.owner !== first.owner), picked.right));
    updateLink();
  }
  function updateLink() {
    Object.assign(picked, { suite: suite.value, left: left.value, right: right.value });
    state.comparisons.set(key, picked);
    const prefix = crossProfile ? '#/compare/' : profileHref(profiles[0]) + '/compare/';
    compare.href = prefix + [left.value, right.value].map(encodeURIComponent).join(',');
  }
  function selectSuite() {
    left.replaceChildren(...options(bySuite.get(suite.value), picked.left));
    selectPair();
  }
  suite.onchange = selectSuite;
  left.onchange = selectPair;
  right.onchange = updateLink;
  selectSuite();
  return h('div', { class: 'compare-picker' },
    h('label', { class: 'field' }, '评测集', suite), h('label', { class: 'field' }, '第一份结果', left),
    h('label', { class: 'field' }, '第二份结果', right), compare);
}

function profileSuiteEntries(chosen) {
  const bySuite = new Map();
  for (const p of chosen) {
    for (const group of groupedItems(p)) {
      for (const { item } of group.entries) {
        if (!item.job) continue;
        if (!bySuite.has(item.suite)) bySuite.set(item.suite, { suiteName: item.suite_name || item.suite, byProfile: new Map() });
        const bucket = bySuite.get(item.suite).byProfile;
        if (!bucket.has(p.id)) bucket.set(p.id, []);
        const tasksCount = item.tasks?.length || item.job.planned || 0;
        bucket.get(p.id).push({
          run: item.job.name,
          model: item.model || '',
          tasks: tasksCount,
          startedAt: item.job.started_at || item.started_at || '',
          label: [group.label, item.model || '—', tasksCount ? `${tasksCount} 题` : null, item.job.name].filter(Boolean).join(' · '),
        });
      }
    }
  }
  return [...bySuite.entries()].filter(([, v]) => chosen.every((p) => (v.byProfile.get(p.id) || []).length > 0));
}

function bestJobEntry(entries, model) {
  const pool = model !== null ? entries.filter((e) => e.model === model) : entries;
  return [...pool].sort((a, b) => b.tasks - a.tasks || String(b.startedAt).localeCompare(String(a.startedAt)))[0];
}

function pickDefaultProfileJobs(chosen, byProfile, saved) {
  const sets = chosen.map((p) => new Set(byProfile.get(p.id).map((e) => e.model)));
  const sharedModels = [...sets[0]].filter((m) => sets.every((s) => s.has(m)));
  let preferredModel = null;
  if (sharedModels.length) {
    preferredModel = sharedModels.sort((a, b) => {
      const score = (m) => chosen.reduce((sum, p) => sum + (bestJobEntry(byProfile.get(p.id), m)?.tasks || 0), 0);
      return score(b) - score(a);
    })[0];
  }
  const result = {};
  for (const p of chosen) {
    const entries = byProfile.get(p.id);
    const kept = saved?.[p.id];
    if (kept && entries.some((e) => e.run === kept)) result[p.id] = kept;
    else result[p.id] = bestJobEntry(entries, preferredModel).run;
  }
  return result;
}

function multiProfileCompareDock(chosen, onChange = render) {
  const shared = profileSuiteEntries(chosen);
  const key = chosen.map((p) => p.id).join(',');
  const picked = state.comparisons.get(key) || {};
  const chips = chosen.map((p, i) => h('span', { class: 'mono', style: 'font-size:12px' },
    h('span', { style: `color:${profileColor(i)};margin-right:4px`, text: '★' }), profileName(p)));
  const clearBtn = h('button', { type: 'button', class: 'button sm', onclick: () => { state.selected.clear(); onChange(); } }, '清空');
  if (!shared.length) {
    return h('section', { class: 'compare-dock' },
      h('div', { class: 'compare-dock-top' },
        h('div', { class: 'compare-dock-left' }, h('span', { class: 'tag acc', text: `已勾选 ${chosen.length} 个 Profile` }), ...chips,
          h('span', { class: 'muted', text: '暂无所有已选 Profile 共有的评测集结果' })),
        h('div', { class: 'compare-dock-right' }, clearBtn)));
  }
  const bySuite = new Map(shared);
  const currentSuite = bySuite.has(picked.suite) ? picked.suite : shared[0][0];
  const suiteSelect = h('select', { 'aria-label': '共同评测集' }, shared.map(([sid, v]) =>
    h('option', { value: sid, selected: sid === currentSuite, text: '共同评测集：' + v.suiteName })));
  const go = h('a', { class: 'button primary sm', text: `打开 ${chosen.length} 版本对比台 →` });
  const picksBox = h('div', { class: 'compare-dock-picks' });
  const selects = new Map();

  function syncHref() {
    const sid = suiteSelect.value;
    const saved = picked.jobsBySuite?.[sid] || {};
    for (const [pid, sel] of selects) saved[pid] = sel.value;
    picked.suite = sid;
    picked.jobsBySuite = { ...(picked.jobsBySuite || {}), [sid]: saved };
    state.comparisons.set(key, picked);
    const jobs = chosen.map((p) => saved[p.id]).filter(Boolean);
    go.href = '#/compare/' + jobs.map(encodeURIComponent).join(',');
  }

  function drawPicks() {
    const sid = suiteSelect.value;
    const { byProfile } = bySuite.get(sid);
    const defaults = pickDefaultProfileJobs(chosen, byProfile, picked.jobsBySuite?.[sid]);
    selects.clear();
    picksBox.replaceChildren(...chosen.map((p, i) => {
      const entries = byProfile.get(p.id);
      const sel = h('select', { 'aria-label': `${profileName(p)} 参与对比的作业`, onchange: syncHref },
        entries.map((e) => h('option', { value: e.run, selected: e.run === defaults[p.id], text: e.label })));
      selects.set(p.id, sel);
      return h('label', { class: 'compare-dock-pick' },
        h('span', {}, h('b', { style: `color:${profileColor(i)}`, text: '★' }), h('span', { class: 'mono', text: profileName(p) })),
        sel);
    }));
    syncHref();
  }

  suiteSelect.onchange = drawPicks;
  drawPicks();
  return h('section', { class: 'compare-dock' },
    h('div', { class: 'compare-dock-top' },
      h('div', { class: 'compare-dock-left' }, h('span', { class: 'tag acc', text: `已勾选 ${chosen.length} 个 Profile` }), ...chips),
      h('div', { class: 'compare-dock-right' }, suiteSelect, go, clearBtn)),
    picksBox);
}

async function renderOverview() {
  state.overviewDirty = false;
  navCurrent('overview');
  $('#title').textContent = 'Profiles';
  crumbs([]);
  const { profiles, jobs, runs, can_run: canRun } = await api('/api/jobs');
  state.live = profiles.some(profileActive) || jobs.some((j) => j.running) || runs.some((r) => ['queued', 'starting', 'running', 'cancelling'].includes(r.status));
  $('#create-run').hidden = !canRun;
  const knownIds = new Set(profiles.map((p) => p.id));
  for (const id of [...state.selected]) if (!knownIds.has(id)) state.selected.delete(id);
  const allModels = [...new Set(profiles.flatMap((p) => p.models || []).filter(Boolean))];
  const runningCount = profiles.filter(profileActive).length;
  if (state.overviewFilter !== 'all' && state.overviewFilter !== 'running' && !allModels.includes(state.overviewFilter)) {
    state.overviewFilter = 'all';
  }
  const filterButtons = [
    ['all', '全部 Profile', profiles.length],
    ...(runningCount ? [['running', '运行中', runningCount]] : []),
    ...(allModels.length > 1 ? allModels.map((m) => [m, m, profiles.filter((p) => (p.models || []).includes(m)).length]) : []),
  ];
  const table = (heads, rows) => h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, heads.map((head) => h('th', { text: head })))), h('tbody', {}, rows)));

  const owned = new Set(profiles.flatMap((p) => p.items.map((i) => i.run)));
  const localRuns = new Set(runs.map((r) => r.name));
  const loose = jobs.filter((j) => !owned.has(j.name));
  const receipts = runs.filter((r) => !owned.has(r.name) && !jobs.some((j) => j.name === r.name));
  const legacyCount = loose.length + receipts.length;
  const legacy = legacyCount ? h('details', { class: 'panel legacy-panel', open: true, 'data-key': 'overview-legacy' },
    h('summary', {}, '独立评测记录', h('span', { class: 'muted', text: `${legacyCount} 条历史评测（未归属 Profile）` })),
    table(['评测', '模型', '评测集', ''], [
      ...loose.map((j) => h('tr', {}, h('td', {}, link((localRuns.has(j.name) ? '#/run/' : '#/job/') + encodeURIComponent(j.name), j.name)),
        h('td', { text: j.model }), h('td', { text: j.suite_name || j.dataset }), h('td', {}, canRun && !j.running ?
          h('button', { class: 'button sm', onclick: (e) => deleteJob(j, e.currentTarget) }, '删除') : null))),
      ...receipts.map((r) => h('tr', {}, h('td', {}, link('#/run/' + encodeURIComponent(r.name), r.name)),
        h('td', { text: r.model }), h('td', { text: r.suite_name }), h('td', { text: RUN_STATUS[r.status] || r.status }))),
    ])) : null;

  return localView((redraw) => {
    const chosen = profiles.filter((p) => state.selected.has(p.id));
    const colorOf = new Map(chosen.map((p, i) => [p.id, profileColor(i)]));
    const filterChips = h('div', { class: 'chips', role: 'group', 'aria-label': '筛选 Profile' },
      filterButtons.map(([key, label, count]) => h('button', { type: 'button', class: 'chip', 'aria-pressed': String(state.overviewFilter === key),
        onclick: () => { state.overviewFilter = key; redraw(); } }, label, ' ', h('span', { class: 'mono faint', text: String(count) }))));
    const search = h('input', { type: 'search', placeholder: '搜索 Profile / 版本 / 模型', value: state.overviewSearch, 'aria-label': '搜索 Profile',
      onfocus: () => { state.editing = true; }, onblur: () => { state.editing = false; },
      oninput: (e) => { state.overviewSearch = e.target.value; drawCards(); } });
    const sortSelect = h('select', { 'aria-label': '排序方式', onchange: (e) => { state.overviewSort = e.target.value; drawCards(); } },
      [['recent', '排序：最近运行'], ['rate', '排序：首轮满分率'], ['cost', '排序：每题成本']].map(([val, label]) =>
        h('option', { value: val, selected: state.overviewSort === val, text: label })));
    const indexBar = profiles.length ? h('div', { class: 'index-bar' }, filterChips, h('div', { class: 'index-controls' }, search, sortSelect)) : null;
    const dock = chosen.length >= 2 ? multiProfileCompareDock(chosen, redraw) : null;
    const grid = h('section', { class: 'card-grid' });
    function drawCards() {
      const q = (state.overviewSearch || '').trim().toLowerCase();
      const visible = profiles.filter((p) => {
        if (state.overviewFilter === 'running' && !profileActive(p)) return false;
        if (state.overviewFilter !== 'all' && state.overviewFilter !== 'running' && !(p.models || []).includes(state.overviewFilter)) return false;
        if (!q) return true;
        const hay = [profileName(p), p.metacodes?.label || '', (p.models || []).join(' '), (p.features || []).join(' ')].join(' ').toLowerCase();
        return hay.includes(q);
      }).sort((a, b) => {
        if (state.overviewSort === 'rate') return (b.summary.first_pass_rate ?? -1) - (a.summary.first_pass_rate ?? -1);
        if (state.overviewSort === 'cost') return (a.summary.cost_per_task ?? Infinity) - (b.summary.cost_per_task ?? Infinity);
        return String(b.last_run_at || b.created_at || '').localeCompare(String(a.last_run_at || a.created_at || ''));
      });
      if (!visible.length) {
        grid.replaceChildren(h('div', { class: 'panel', style: 'grid-column:1/-1' }, h('div', { class: 'empty' },
          profiles.length ? '没有符合条件的 Profile。' : '还没有 Profile。',
          !profiles.length && canRun ? h('button', { class: 'button', onclick: openRunDialog, style: 'margin-left:10px' }, '创建首个作业') : null)));
        return;
      }
      grid.replaceChildren(...visible.map((p) => {
        const checked = state.selected.has(p.id);
        const col = colorOf.get(p.id);
        const active = profileActive(p);
        const s = p.summary;
        const box = h('input', { type: 'checkbox', checked, 'aria-label': '对比 ' + profileName(p),
          onclick: (e) => e.stopPropagation(),
          onchange: (e) => { if (e.target.checked) state.selected.add(p.id); else state.selected.delete(p.id); redraw(); } });
        if (col) box.style.accentColor = col;
        const rateGood = (s.first_pass_rate ?? 0) >= 0.65;
        const featList = p.features || [];
        return h('article', { class: 'pcard' + (checked ? ' selected' : ''), style: col ? `border-top:2px solid ${col}` : null,
          onclick: () => { location.hash = profileHref(p); } },
          h('div', { class: 'pcard-head' },
            h('div', { style: 'min-width:0' },
              h('div', { class: 'pcard-title' }, col ? h('span', { style: `color:${col}`, text: '★' }) : null, h('a', { href: profileHref(p), text: profileName(p) })),
              h('div', { class: 'muted', style: 'font-size:11.5px;margin-top:3px', text: (p.models || []).join(' · ') || '—' })),
            h('div', { style: 'display:flex;align-items:center;gap:8px;flex:none' },
              h('span', { class: active ? 'tag acc' : 'tag' }, active ? h('i', { class: 'live-dot' }) : null, PROFILE_STATUS[p.status] || p.status),
              h('label', { class: 'pcard-check', onclick: (e) => e.stopPropagation() }, box))),
          h('div', { class: 'pcard-tags' },
            h('span', { class: 'tag mono', text: p.metacodes?.label || '—' }),
            ...(featList.length
              ? featList.map((feat) => h('span', { class: 'tag mono', text: feat }))
              : [h('span', { class: 'tag mono', text: '默认功能' })])),
          h('div', {},
            h('div', { class: 'pcard-rate' },
              h('div', {}, h('strong', { class: rateGood ? 'good' : null, text: pct(s.first_pass_rate) }), ' ', h('span', { class: 'muted', style: 'font-size:11.5px', text: '首轮满分' })),
              h('span', { class: 'mono muted', style: 'font-size:11.5px', text: `${int(s.first_passed)} / ${int(s.first_valid)} 首次有效` })),
            h('div', { style: 'margin-top:8px' }, outcomeBar(s.counts, s.trials))),
          h('div', { class: 'pcard-stats' },
            h('div', {}, h('span', { text: '每题成本' }), h('b', { text: usd(s.cost_per_task) })),
            h('div', {}, h('span', { text: '初始 Token' }), h('b', { text: compact(s.initial_input_tokens_mean) })),
            h('div', {}, h('span', { text: '作业数' }), h('b', { text: groupedItems(p).length + ' 作业' }))),
          h('div', { class: 'pcard-foot' },
            h('span', { class: active ? 'acc mono' : null, text: active ? progressText(p) : '最近：' + when(p.last_run_at) }),
            h('span', { class: 'acc', text: '进入详情 →' }),
            canRun && !active ? deleteProfileButton(p) : null));
      }));
    }
    drawCards();
    return [indexBar, dock, grid, legacy];
  });
}

// ------------------------------------------------------------ profile
function taskKey(t) { return `${t.suite}\0${t.model || ''}\0${t.task}`; }
function attemptStrip(t, href) {
  if (!t.attempts.length) return h('span', { class: 'muted', text: '等待运行' });
  return h('span', { class: 'attempt-strip' }, t.attempts.map((a) => {
    const title = `第 ${a.attempt_number} 次 · ${STATUS[a.status] || a.status}${a.cause ? ' · ' + a.cause : ''}`;
    const sq = h('i', { class: 'attempt-sq s-' + a.status, title });
    return href ? h('a', { href: href + '/' + encodeURIComponent(a.trial), onclick: (e) => e.stopPropagation(), title, 'aria-label': title }, sq) : sq;
  }));
}

async function renderProfile(id) {
  navCurrent('overview');
  const b = await api('/api/profile?id=' + encodeURIComponent(id));
  if (state.profileId !== b.id) {
    state.profileId = b.id;
    state.selectedTaskKey = null;
    state.drawerClosed = false;
  }
  state.live = profileActive(b);
  $('#title').textContent = profileName(b);
  crumbs([{ text: 'Profiles', href: '#/' }, { text: 'MetaCodes ' + (b.metacodes?.label || '—') + (b.features?.length ? ' · ' + b.features.join(', ') : '') }]);
  const s = b.summary;

  const suitesPresent = [...new Map(b.tasks.map((t) => [t.suite, t.suite_name || t.suite]))];
  const modelsPresent = [...new Set(b.tasks.map((t) => t.model).filter(Boolean))];
  const groups = groupedItems(b);
  const runningItem = b.items.find((i) => i.status === 'running');
  const latestGroup = groups[0];
  const pendingItems = b.items.filter((i) => i.status === 'pending').length;
  const activeProg = runningItem ? (() => {
    const js = runningItem.job?.summary;
    const planned = runningItem.job?.planned || (runningItem.tasks || []).length * (runningItem.attempts || 1);
    const done = js ? js.trials - js.counts.running : 0;
    const width = planned ? Math.min(100, 100 * done / planned) : 0;
    return h('span', { class: 'prog-pill' },
      h('strong', { text: runningItem.suite_name || runningItem.suite }),
      h('span', { class: 'mono', text: `${done} / ${planned}` }),
      h('span', { class: 'prog-bar' }, h('span', { width: width + '%' })),
      js ? h('span', { class: 'pos mono', text: pct(js.first_pass_rate) }) : null);
  })() : null;
  const suiteCounts = new Map();
  for (const t of b.tasks) suiteCounts.set(t.suite, (suiteCounts.get(t.suite) || 0) + 1);

  return localView((redraw) => {
    if (state.profileSuite && !suitesPresent.some(([sid]) => sid === state.profileSuite)) state.profileSuite = 'all';
    if (state.profileModel && !modelsPresent.includes(state.profileModel)) state.profileModel = 'all';

    const scopedTasks = b.tasks
      .filter((t) => (state.profileSuite || 'all') === 'all' || t.suite === state.profileSuite)
      .filter((t) => (state.profileModel || 'all') === 'all' || t.model === state.profileModel);
    const scopedCounts = Object.fromEntries(ORDER.map((k) => [k, 0]));
    for (const t of scopedTasks) if (t.first_status && t.first_status in scopedCounts) scopedCounts[t.first_status] += 1;
    const scopeLabel = [
      state.profileSuite === 'all' ? '全部评测集' : (suitesPresent.find(([sid]) => sid === state.profileSuite)?.[1] || state.profileSuite),
      state.profileModel === 'all' ? null : state.profileModel,
    ].filter(Boolean).join(' · ');

    const statusPills = h('div', { class: 'stat-pills', role: 'group', 'aria-label': '按首次结局筛选' },
      h('button', { type: 'button', class: 'stat-pill' + ((state.taskFilter || 'all') === 'all' ? ' on' : ''),
        onclick: () => { state.taskFilter = 'all'; redraw(); } }, '全部 ', h('b', { text: String(scopedTasks.length) })),
      ...ORDER.filter((k) => scopedCounts[k] > 0 || state.taskFilter === k).map((k) =>
        h('button', { type: 'button', class: 'stat-pill' + (state.taskFilter === k ? ' on' : ''),
          onclick: () => { state.taskFilter = state.taskFilter === k ? 'all' : k; redraw(); } },
          h('i', { class: 'dot s-' + k }), STATUS[k] + ' ', h('b', { text: String(scopedCounts[k]) }))));

    const banner = h('section', { class: 'profile-banner', 'aria-label': '各题最新结果' },
      h('div', { class: 'profile-banner-left' },
        metric('一次性完成率', pct(s.one_shot_pass_rate), int(s.counts.pass) + ' 通过 / ' + int(s.valid) + ' 有效', true),
        metric('首轮满分率', pct(s.first_pass_rate), int(s.first_passed) + ' / ' + int(s.first_valid) + ' 首次有效'),
        metric('至少通过一次', pct(s.solved_rate), int(s.tasks_solved) + ' / ' + int(s.tasks_attempted) + ' 道')),
      h('div', { class: 'profile-banner-right' },
        h('div', {},
          h('div', { style: 'display:flex;justify-content:space-between;gap:10px;font-size:11.5px;margin-bottom:6px;flex-wrap:wrap' },
            h('span', { class: 'muted', text: `首次结局分布（${scopeLabel} · 点击状态筛选下方任务）` }),
            h('span', { class: 'mono muted', text: `${scopedTasks.length} 道题` })),
          outcomeBar(scopedCounts, scopedTasks.length, true),
          statusPills),
        h('div', { class: 'profile-banner-meta' },
          h('div', {}, h('span', { text: '每题平均成本' }), h('strong', { text: usd(s.cost_per_task) })),
          h('div', {}, h('span', { text: '每次通过成本' }), h('strong', { text: usd(s.cost_per_pass) })),
          h('div', {}, h('span', { text: '初始 Token 均值' }), h('strong', { text: compact(s.initial_input_tokens_mean) })),
          h('div', {}, h('span', { text: '缓存命中率' }), h('strong', { text: pct(s.cache_hit_rate) })))));

    const jobsStrip = h('section', { class: 'jobs-strip' },
      h('div', { class: 'jobs-strip-left' },
        h('span', { class: profileActive(b) ? 'tag acc' : 'tag' },
          profileActive(b) ? h('i', { class: 'live-dot' }) : null,
          latestGroup ? `${latestGroup.label} · ${PROFILE_STATUS[b.status] || b.status}` : `${groups.length} 个作业`),
        activeProg,
        h('span', { class: 'muted', style: 'font-size:12px', text: [
          pendingItems ? `队列剩余 ${pendingItems} 项` : `共 ${groups.length} 个作业`,
          `并发 ${b.concurrency}`,
          `自动重跑：${b.auto_rerun_invalid ? '开' : '关'}`,
        ].join(' · ') })),
      h('div', { class: 'row-actions', style: 'flex-wrap:wrap' },
        b.can_run && b.tasks.some((t) => t.model === runModel(b) && hasInvalid(t))
          ? h('button', { type: 'button', class: 'button sm', onclick: () => runAgain(b, true) }, '重跑无效的题') : null,
        b.can_run ? h('button', { type: 'button', class: 'button primary sm', onclick: () => runAgain(b, false) }, '创建作业') : null,
        h('button', { type: 'button', class: 'button sm', 'aria-expanded': String(state.profileExpanded),
          onclick: () => { state.profileExpanded = !state.profileExpanded; redraw(); } },
          state.profileExpanded ? '收起作业 / 设置 / 诊断 ▴' : `展开作业 (${groups.length}) / 设置 / 诊断 ▾`)));

    const buildExpanded = () => {
      const nameInput = h('input', { type: 'text', maxlength: 80, value: b.name || '', placeholder: b.default_name || b.id, 'aria-label': 'Profile名称' });
      const renameFeedback = h('span', { class: 'muted', role: 'status' });
      const closeRename = () => { state.editing = false; renameForm.hidden = true; nameRow.hidden = false; };
      const renameForm = h('form', { class: 'rename', hidden: true },
        nameInput, h('button', { type: 'submit', class: 'button primary' }, '保存'),
        h('button', { type: 'button', class: 'button', onclick: closeRename }, '取消'), renameFeedback);
      renameForm.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeRename(); });
      renameForm.addEventListener('submit', async (event) => {
        event.preventDefault();
        renameFeedback.textContent = '正在保存…';
        try { await api('/api/profile/rename', { id: b.id, name: nameInput.value }); render(); }
        catch (error) { renameFeedback.textContent = error.message; }
      });
      const nameRow = h('span', { class: 'rename' }, h('span', { text: b.name || '未命名（按版本和高级功能命名）' }),
        b.can_run ? h('button', { type: 'button', class: 'button sm', onclick: () => {
          state.editing = true; nameRow.hidden = true; renameForm.hidden = false; nameInput.focus(); nameInput.select();
        } }, '重命名') : null);
      const m = b.metacodes || {};
      const infoPanel = panel('Profile 设置与冻结信息', `并发 ${b.concurrency}`, h('div', { class: 'panel-body' },
        h('dl', { class: 'kv' },
          h('dt', { text: '名称' }), h('dd', {}, nameRow, renameForm),
          h('dt', { text: '并发数' }), h('dd', {}, concurrencyControl(b, redraw)),
          h('dt', { text: '自动重跑' }), h('dd', {}, autoRerunControl(b)),
          h('dt', { text: '编号' }), h('dd', { class: 'mono', text: b.id }),
          h('dt', { text: 'metacodes 版本' }), h('dd', {}, h('b', { class: 'mono', text: m.label || '—' }), m.release ? h('span', { class: 'muted', text: ' · 发行包 ' + m.release }) : null),
          h('dt', { text: '冻结' }), h('dd', { class: 'mono', text: m.digest ? `内容摘要 ${m.digest}${m.commit ? ' · commit ' + m.commit : ''}` : '—' }),
          h('dt', { text: '二进制 SHA-256' }), h('dd', { class: 'mono', text: m.binary_sha256 || '—' }),
          h('dt', { text: '冻结副本' }), h('dd', { class: 'mono', text: m.bundle || '—' }),
          h('dt', { text: '高级功能' }), h('dd', { class: 'mono', text: featuresText(b) }),
          h('dt', { text: '模型' }), h('dd', { text: (b.models || []).join('、') || '—' }),
          h('dt', { text: '时间' }), h('dd', { text: `创建 ${when(b.created_at)} · 最近运行 ${when(b.last_run_at)}` })),
        b.can_run ? h('div', { class: 'row-actions', style: 'margin-top:14px;padding-top:12px;border-top:1px solid var(--rule)' }, profileActions(b)) : null));

      const diagBody = h('div', { class: 'panel-body', style: 'display:flex;flex-direction:column;gap:14px' },
        s.initial_composition_mean ? h('div', {},
          stackBar(compositionSegments(s.initial_composition_mean)),
          h('div', { class: 'legend keys' }, PARTS.map(([k, l]) => h('span', { class: 'key' }, h('i', { class: 'c-' + k }),
            `${l} ${compact(s.initial_composition_mean[k])} · ${pct((s.initial_composition_mean[k] || 0) / Math.max(1, partsTotal(s.initial_composition_mean)))}`)))) : null,
        h('div', { class: 'kv-grid' },
          h('div', { class: 'kv-box' }, h('span', { text: '生成 TPS' }), h('strong', { text: tps(s.tps) })),
          h('div', { class: 'kv-box' }, h('span', { text: 'TTFT 均值 / P95' }), h('strong', { text: `${ttft(s.ttft_ms)} / ${ttft(s.ttft_p95_ms)}` })),
          h('div', { class: 'kv-box' }, h('span', { text: '未通过成本占比' }), h('strong', { text: pct(s.non_pass_cost_share) }))),
        h('details', { class: 'call', 'data-key': 'profile-metrics' }, h('summary', { text: '展开全部 15 项指标' }),
          h('div', { class: 'metrics', style: 'padding:12px 14px;margin-bottom:0;border-bottom:0' }, measurementCards(s),
            metric('队列', progressText(b), PROFILE_STATUS[b.status] || b.status),
            metric('无效', int(s.counts.invalid)), s.budget_exhausted ? metric('预算用完', int(s.budget_exhausted)) : null)));
      const diagPanel = panel('完整诊断与初始上下文组成', `初始均值 ${compact(s.initial_input_tokens_mean)}`, diagBody);

      const itemRow = (item, index) => {
        const j = item.job; const js = j?.summary;
        const href = item.local_run ? '#/run/' + encodeURIComponent(item.run) : j ? '#/job/' + encodeURIComponent(j.name) : null;
        return h('tr', { class: href ? 'link' : null, onclick: href ? () => { location.hash = href; } : null },
          h('td', {}, href ? link(href, item.suite_name || item.suite) : h('span', { text: item.suite_name || item.suite }), h('span', { class: 'sub', text: [item.category_name, `${(item.tasks || []).length} 道题`,
            item.concurrency ? `并发 ${item.concurrency}` : null,
            item.auto_rerun ? `自动重跑无效的题 第 ${item.auto_rerun} 轮` : null,
            skippedFeatures(b, item).length ? `本次未开启 ${skippedFeatures(b, item).join(', ')}` : null].filter(Boolean).join(' · ') })),
          h('td', { text: item.model || '—' }),
          h('td', {}, h('span', { text: item.status === 'running' && item.cancel_requested ? '正在停止' : ITEM_STATUS[item.status] || item.status }), item.error ? h('span', { class: 'sub flag', text: item.error }) : null,
            item.auto_rerun_error ? h('span', { class: 'sub flag', text: item.auto_rerun_error }) : null),
          h('td', { class: 'num', text: js ? `${js.trials - js.counts.running} / ${j.planned}` : `0 / ${(item.tasks || []).length * (item.attempts || 1)}` }),
          h('td', {}, js ? outcomeBar(js.counts, js.trials) : dash()),
          h('td', { class: 'num', text: js ? pct(js.first_pass_rate) : '—' }),
          h('td', { class: 'num', text: js ? compact(js.total_tokens) : '—' }),
          h('td', { class: 'num', text: j ? dur(j.wall_s) : '—' }),
          b.can_run ? h('td', { class: 'pinned' }, h('div', { class: 'row-actions' }, itemActions(b, index), j && !j.running && item.status !== 'running' ? h('button', { class: 'button', onclick: (e) => { e.stopPropagation(); deleteJob(j, e.currentTarget); } }, '删除结果') : null)) : null);
      };
      const itemHeads = ['评测集', '模型', '状态', '完成', '结局分布', '首次满分率', '总 Token', '用时', ...(b.can_run ? ['操作'] : [])];
      const itemTable = (rows, empty) => h('div', { class: 'table-scroll' }, h('table', {},
        h('thead', {}, h('tr', {}, itemHeads.map((t, i) => h('th', { class: [3, 5, 6, 7].includes(i) ? 'num' : i === 8 ? 'pinned' : null, text: t })))),
        h('tbody', {}, rows.length ? rows : h('tr', {}, h('td', { colspan: itemHeads.length, class: 'empty', text: empty })))));
      const submissions = panel('作业队列', groups.length + ' 个', h('div', {}, groups.map((group) => {
        const active = group.entries.some(({ item }) => ['pending', 'running'].includes(item.status));
        const controlFor = (action, label, question) => h('button', { type: 'button', class: 'button', onclick: async (event) => {
          if (question && !confirm(question)) return;
          const control = event.currentTarget;
          control.disabled = true;
          try { await api('/api/profile/submission', { id: b.id, submission: group.id, action }); await render(); }
          catch (error) { control.disabled = false; setConnection(false, error.message); }
        } }, label);
        const controls = b.can_run ? h('div', { class: 'row-actions' }, active
          ? controlFor('cancel', '取消作业', '取消' + group.label + '里的所有等待中和运行中评测？')
          : [controlFor('run', '重新运行作业'), controlFor('delete', '删除作业', '从 Profile 删除' + group.label + '及其全部评测记录？已有运行结果将保留。')]) : null;
        const first = group.entries[0].item;
        return h('article', { class: 'submission' }, h('div', { class: 'panel-heading' },
          h('h3', {}, group.label, h('small', { class: 'muted', text: [when(first.queued_at), first.executor, group.entries.length + ' 项评测'].filter(Boolean).join(' · ') })),
          controls), itemTable(group.entries.map(({ item, index }) => itemRow(item, index)), ''));
      })));
      return h('div', { class: 'profile-expanded' },
        submissions,
        panel('作业对比', '同一评测集', h('div', { class: 'panel-body' }, comparisonPicker([b], false))),
        modelsPanel(b, redraw),
        h('div', { class: 'sec-grid' }, infoPanel, diagPanel));
    };
    const expandedArea = state.profileExpanded ? buildExpanded() : null;

    const chips = suitesPresent.length > 1 ? h('div', { class: 'chips', role: 'group', 'aria-label': '按评测集筛选' },
      [['all', '全部', b.tasks.length], ...suitesPresent.map(([sid, name]) => [sid, name, suiteCounts.get(sid) || 0])].map(([sid, name, cnt]) =>
        h('button', { type: 'button', class: 'chip', 'aria-pressed': String((state.profileSuite || 'all') === sid),
          onclick: () => { state.profileSuite = sid; redraw(); } }, name, ' ', h('span', { class: 'mono faint', text: String(cnt) })))) : null;
    const modelChips = modelsPresent.length > 1 ? h('div', { class: 'chips', role: 'group', 'aria-label': '按模型筛选' },
      [['all', '全部模型'], ...modelsPresent.map((x) => [x, x])].map(([mid, name]) => h('button', { type: 'button', class: 'chip', 'aria-pressed': String((state.profileModel || 'all') === mid),
        onclick: () => { state.profileModel = mid; redraw(); } }, name))) : null;
    const search = h('input', { type: 'search', placeholder: '搜索任务', value: state.taskSearch || '', 'aria-label': '搜索任务',
      onfocus: () => { state.editing = true; }, onblur: () => { state.editing = false; },
      oninput: (e) => { state.taskSearch = e.target.value; drawWorkspace(); } });
    const sortSelect = h('select', { class: 'task-sort', 'aria-label': '任务排序', onchange: (e) => { state.taskSort = e.target.value; drawWorkspace(); } },
      [['default', '默认顺序'], ['rate-asc', '通过率升序'], ['tokens-desc', '总 Token 降序'], ['time-desc', '用时降序']].map(([v, label]) =>
        h('option', { value: v, selected: state.taskSort === v, text: label })));

    const showSuiteCol = suitesPresent.length > 1 && (state.profileSuite || 'all') === 'all';
    const showModelCol = modelsPresent.length > 1 && (state.profileModel || 'all') === 'all';
    const taskHeads = ['任务', ...(showSuiteCol ? ['评测集'] : []), ...(showModelCol ? ['模型'] : []), '各次结局', '通过 / 有效', '总 Token', '轮数', '用时'];
    const numStart = 2 + (showSuiteCol ? 1 : 0) + (showModelCol ? 1 : 0);
    const tbody = h('tbody', {});
    const drawer = h('aside', { class: 'task-drawer', 'aria-label': '任务详情抽屉' });
    const workspace = h('div', { class: 'task-workspace' });

    function drawWorkspace() {
      const q = (state.taskSearch || '').trim().toLowerCase();
      const shown = scopedTasks
        .filter((t) => (state.taskFilter || 'all') === 'all' || t.first_status === state.taskFilter)
        .filter((t) => !q || t.task.toLowerCase().includes(q));
      const ordered = [...shown];
      if (state.taskSort === 'rate-asc') ordered.sort((a, c) => (a.valid ? a.passed / a.valid : -1) - (c.valid ? c.passed / c.valid : -1) || a.task.localeCompare(c.task));
      else if (state.taskSort === 'tokens-desc') ordered.sort((a, c) => (c.mean_total_tokens ?? -1) - (a.mean_total_tokens ?? -1));
      else if (state.taskSort === 'time-desc') ordered.sort((a, c) => (c.mean_elapsed_s ?? -1) - (a.mean_elapsed_s ?? -1));

      let selIndex = ordered.findIndex((t) => taskKey(t) === state.selectedTaskKey);
      if (selIndex < 0 && ordered.length && !state.drawerClosed) {
        selIndex = 0;
        state.selectedTaskKey = taskKey(ordered[0]);
      }
      const sel = !state.drawerClosed && selIndex >= 0 ? ordered[selIndex] : null;
      workspace.classList.toggle('full', !sel);
      drawer.hidden = !sel;

      tbody.replaceChildren(...(ordered.length ? ordered.map((t) => {
        const k = taskKey(t);
        const isSel = sel && taskKey(sel) === k;
        const href = t.job ? `#/profile/${encodeURIComponent(b.id)}/task/${encodeURIComponent(t.job)}/${encodeURIComponent(t.task)}` : null;
        return h('tr', { class: 'link' + (isSel ? ' selected' : ''), onclick: () => {
          state.selectedTaskKey = k;
          state.drawerClosed = false;
          drawWorkspace();
        } },
          h('td', {}, h('span', { class: 'task-name-cell' }, h('i', { class: 'dot round s-' + (t.first_status || 'running') }), h('span', { class: 'mono', text: t.task }))),
          showSuiteCol ? h('td', { text: t.suite_name || t.suite }) : null,
          showModelCol ? h('td', { text: t.model || '—' }) : null,
          h('td', {}, attemptStrip(t, href)),
          h('td', { class: 'num', text: t.attempts.length ? `${t.passed} / ${t.valid}` : '—' }),
          h('td', { class: 'num', text: compact(t.mean_total_tokens) }),
          h('td', { class: 'num', text: t.mean_turns === null || t.mean_turns === undefined ? '—' : t.mean_turns.toFixed(1) }),
          h('td', { class: 'num', text: dur(t.mean_elapsed_s) }));
      }) : [h('tr', {}, h('td', { colspan: taskHeads.length, class: 'empty', text: '没有符合条件的任务' }))]));

      if (!sel) return;
      const href = sel.job ? `#/profile/${encodeURIComponent(b.id)}/task/${encodeURIComponent(sel.job)}/${encodeURIComponent(sel.task)}` : null;
      const prev = selIndex > 0 ? ordered[selIndex - 1] : null;
      const next = selIndex < ordered.length - 1 ? ordered[selIndex + 1] : null;
      const attemptsList = sel.attempts.length ? h('div', { class: 'att-list' }, sel.attempts.map((a) => {
        const trialHref = href ? href + '/' + encodeURIComponent(a.trial) : null;
        const testText = a.tests ? `${a.tests.passed}/${a.tests.total} 测试` : (a.reward !== null && a.reward !== undefined ? `reward ${a.reward}` : '');
        const card = h(trialHref ? 'a' : 'div', { class: 'att-card', href: trialHref },
          h('div', { style: 'display:flex;align-items:center;gap:9px' },
            h('span', { class: 'mono muted', text: '#' + a.attempt_number }),
            badge(a.status, a.cause),
            testText ? h('span', { class: 'mono muted', style: 'font-size:11.5px', text: testText }) : null),
          h('div', { style: 'display:flex;align-items:center;gap:10px' },
            h('span', { class: 'mono', style: 'font-size:11.5px', text: `${compact(a.total_tokens)} · ${dur(a.elapsed_s)}` }),
            trialHref ? h('span', { class: 'acc', style: 'font-size:11.5px', text: '轨迹 ↗' }) : null));
        return card;
      })) : h('div', { class: 'muted', text: '等待运行' });
      const historyNote = sel.history?.length ? h('span', { class: 'muted', style: 'font-size:11.5px' }, `历史覆盖 ${sel.history.length} 次 `,
        ...sel.history.map((job) => h('a', { class: 'acc mono', style: 'margin-left:4px', href: `#/profile/${encodeURIComponent(b.id)}/task/${encodeURIComponent(job)}/${encodeURIComponent(sel.task)}`, text: job.slice(-8) }))) : null;
      drawer.replaceChildren(
        h('div', { class: 'drawer-head' },
          h('div', { style: 'min-width:0' },
            h('div', { class: 'muted', style: 'font-size:11.5px', text: [sel.suite_name || sel.suite, sel.model || '—', `${selIndex + 1} / ${ordered.length}`].join(' · ') }),
            h('div', { class: 'drawer-title', text: sel.task })),
          h('div', { style: 'display:flex;gap:5px;flex:none' },
            h('button', { type: 'button', class: 'button sm', disabled: !prev, 'aria-label': '上一题',
              onclick: () => { if (prev) { state.selectedTaskKey = taskKey(prev); drawWorkspace(); } } }, '←'),
            h('button', { type: 'button', class: 'button sm', disabled: !next, 'aria-label': '下一题',
              onclick: () => { if (next) { state.selectedTaskKey = taskKey(next); drawWorkspace(); } } }, '→'),
            h('button', { type: 'button', class: 'button sm', 'aria-label': '关闭详情抽屉',
              onclick: () => { state.drawerClosed = true; drawWorkspace(); } }, '×'))),
        h('div', { class: 'drawer-body' },
          h('div', { class: 'kv-grid' },
            h('div', { class: 'kv-box' }, h('span', { text: '通过 / 有效' }), h('strong', { class: sel.valid && !sel.passed ? 'neg' : sel.valid && sel.passed === sel.valid ? 'pos' : null, text: sel.attempts.length ? `${sel.passed} / ${sel.valid}` : '—' })),
            h('div', { class: 'kv-box' }, h('span', { text: '平均总 Token' }), h('strong', { text: compact(sel.mean_total_tokens) })),
            h('div', { class: 'kv-box' }, h('span', { text: '平均初始 Token' }), h('strong', { text: compact(sel.mean_initial_input_tokens) })),
            h('div', { class: 'kv-box' }, h('span', { text: '平均轮数' }), h('strong', { text: sel.mean_turns === null || sel.mean_turns === undefined ? '—' : sel.mean_turns.toFixed(1) })),
            h('div', { class: 'kv-box' }, h('span', { text: '平均工具调用' }), h('strong', { text: sel.mean_tool_calls === null || sel.mean_tool_calls === undefined ? '—' : sel.mean_tool_calls.toFixed(1) })),
            h('div', { class: 'kv-box' }, h('span', { text: '平均用时' }), h('strong', { text: dur(sel.mean_elapsed_s) }))),
          h('div', {},
            h('div', { style: 'display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;gap:8px;flex-wrap:wrap' },
              h('strong', { style: 'font-size:12.5px', text: `${sel.attempts.length} 次尝试记录` }),
              historyNote),
            attemptsList),
          href ? h('div', { class: 'drawer-actions' }, h('a', { class: 'button accent sm', href, text: '打开完整任务页（轨迹 / 测试 / 上下文）↗' })) : null));
    }

    const tasksPanel = panel('逐任务（最新结果）', `${scopedTasks.length} 道` + (!showSuiteCol && !showModelCol ? ' · 已隐去重复评测集/模型列' : ''),
      h('div', {}, chips, modelChips,
        h('div', { class: 'panel-body toolbar', style: 'justify-content:space-between' }, search, sortSelect),
        h('div', { class: 'table-scroll' }, h('table', { class: 'task-table' },
          h('thead', {}, h('tr', {}, taskHeads.map((t, i) => h('th', { class: i >= numStart ? 'num' : null, text: t })))), tbody))));
    workspace.append(tasksPanel, drawer);
    drawWorkspace();

    return [banner, jobsStrip, expandedArea, workspace];
  });
}

// The profile's concurrency, the only place it is set: every dataset
// queued on the profile runs at it (capped by its suite's limit).
function concurrencyControl(b, onChange = render) {
  if (!b.can_run) return h('span', { class: 'mono', text: String(b.concurrency ?? '—') });
  const input = h('input', { type: 'number', inputmode: 'numeric', min: 1, step: 1, required: true, value: b.concurrency ?? '',
    'aria-label': '并发数', onfocus: () => { state.editing = true; },
    onblur: () => { if (input.value === String(b.concurrency ?? '')) state.editing = false; } });
  const result = state.concurrencyResult;
  const warning = result?.id === b.id && result.concurrency === b.concurrency &&
    b.items.some((item) => item.run === result.run && item.status === 'running') && result.warning;
  const hint = profileActive(b)
    ? '排队中的评测集启动时使用新值。正在运行的 WorkBuddy 保持原并发，其他评测集会立即调整，已开始的 trial 会继续跑完。'
    : '之后在这个 Profile 上运行的评测集都按这个并发运行';
  const feedback = h('span', { class: 'muted', role: 'status', text: warning || hint });
  const form = h('form', { class: 'rename' }, input, h('button', { type: 'submit', class: 'button primary' }, '应用'), feedback);
  form.addEventListener('keydown', (event) => { if (event.key === 'Escape') { state.editing = false; onChange(); } });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    feedback.textContent = '正在应用…';
    try {
      state.concurrencyResult = await api('/api/profile/concurrency', { id: b.id, concurrency: Number(input.value) });
      state.editing = false;
      render();
    } catch (error) { feedback.textContent = error.message; }
  });
  return form;
}

function autoRerunControl(b) {
  const text = '评测集跑完后，自动把有无效尝试的题再排队运行，每个评测集最多重跑 2 轮';
  const input = h('input', { type: 'checkbox', checked: !!b.auto_rerun_invalid, disabled: !b.can_run, 'aria-label': '自动重跑无效的题' });
  const feedback = h('span', { class: 'muted', role: 'status', text });
  input.addEventListener('change', async () => {
    input.disabled = true;
    feedback.textContent = '正在保存…';
    try {
      await api('/api/profile/auto-rerun', { id: b.id, enabled: input.checked });
      render();
    } catch (error) { input.checked = !input.checked; input.disabled = false; feedback.textContent = error.message; }
  });
  return h('label', { class: 'check' }, input, h('span', { text: '自动重跑无效的题' }), feedback);
}

// The latest results of each model side by side, when the profile has several:
// over every task each ran, then, when they ran different tasks, over the tasks
// all of them ran, so a model is not judged on an easier subset.
function modelsPanel(b, onChange = render) {
  if ((b.by_model || []).length < 2) return null;
  const heads = ['模型', '题数', '结局分布', '一次性完成率', '通过 / 有效', '首轮满分率', '无效', '预算用完', '总 Token', '估算成本'];
  const row = (model, tasks, m) => h('tr', { class: 'link', onclick: () => { state.profileModel = model; onChange(); } },
    h('td', { text: model || '—' }),
    h('td', { class: 'num', text: String(tasks) }),
    h('td', {}, outcomeBar(m.counts, m.trials || 0)),
    h('td', { class: 'num', text: pct(m.one_shot_pass_rate) }),
    h('td', { class: 'num', text: `${m.counts.pass} / ${m.valid || 0}` }),
    h('td', { class: 'num', text: pct(m.first_pass_rate) }),
    h('td', { class: 'num', text: String(m.counts.invalid) }),
    h('td', { class: 'num', text: String(m.budget_exhausted || 0) }),
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
  if (!group) throw new Error('Profile中没有这个任务');
  const chosen = group.attempts.find((a) => a.trial === trialName) || group.attempts[0];
  $('#title').textContent = taskName;
  crumbs([{ text: 'Profiles', href: '#/' }, { text: 'Profile ' + profileName(b), href: profileHref(b) },
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
  failed: '失败', skipped: '已取消' };
const SETUP_RESULT = { running: '进行中', ready: '已就绪', planned: '预演完成', needs_user: '还有需要你操作的步骤',
  failed: '有步骤失败', interrupted: '已中断' };
const RUN_STATUS = { queued: '等待启动', starting: '准备环境', running: '运行中',
  cancelling: '正在停止', cancelled: '已停止', finished: '运行完成', failed: '执行失败', interrupted: '执行中断' };

const RUNNERS = { 'harbor-registry': 'Harbor 注册表', 'harbor-local': '本地生成数据集', workbuddy: 'WorkBuddy' };
// The LLM judge that scores a suite/run: model id and how it is reached.
const judgeText = (j) => '评委 ' + j.model + (j.via === 'metask' ? '（Metask 网关）' : j.via === 'host_env' ? '（执行机器环境变量）' : '');

function openRunDialog() {
  if (document.querySelector('.run-dialog[open]')) return;
  const dialog = h('dialog', { class: 'run-dialog', 'aria-label': '创建作业' });
  const content = h('div', { text: '读取中…' });
  const close = h('button', { class: 'button', onclick: () => dialog.close() }, '关闭');
  dialog.append(close, content);
  dialog.oncancel = (event) => { if (dialog.ariaBusy === 'true') event.preventDefault(); };
  document.body.append(dialog);
  dialog.addEventListener('close', () => {
    dialog.remove();
    if (!dialog.returnValue) clearRunDraft();
  }, { once: true });
  dialog.showModal();
  async function refreshForm() {
    if (!dialog.open || close.disabled) return;
    try {
      const config = await api('/api/workbench');
      if (dialog.open && !close.disabled) content.replaceChildren(runForm(config, refreshForm, dialog, close));
    } catch (error) {
      content.textContent = error.message;
    }
  }
  refreshForm();
}

function clearRunDraft() {
  state.runDraft = null;
  state.taskWanted = null;
  state.suitePick = null;
  state.pickBundle = null;
}

function runForm(c, refreshForm, dialog, close) {
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
    ? h('select', { name: 'bundle', disabled: true }, h('option', { text: `${draft.label || '—'}（Profile已冻结）` }))
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
  const concurrencyNote = fixed ? `并发数 ${draft.concurrency ?? '—'}，在Profile页面修改`
    : `并发数按Profile设置（新配置默认 ${runDefaults.concurrency}），开始评测后可在Profile页面修改`;
  const attempts = h('input', { name: 'attempts', type: 'number', inputmode: 'numeric', value: draft.attempts ?? runDefaults.attempts, min: 1, max: 5, step: 1, required: true,
    oninput: () => { draft.attempts = attempts.value; } });
  const featureBoxes = (c.features || []).map((f) => ({ id: f.id, group: f.group,
    input: h('input', { type: 'checkbox', name: 'features', value: f.id, disabled: fixed,
      checked: (draft.features || c.default_features || []).includes(f.id),
      onchange: (event) => {
        const teamwork = f.id === 'teamwork';
        if (event.target.checked) for (const x of featureBoxes) if (x.id !== f.id && (teamwork || x.id === 'teamwork')) x.input.checked = false;
        draft.features = featureBoxes.filter((x) => x.input.checked).map((x) => x.id);
      } }), label: f.label }));
  const featureGroup = (group, title) => {
    const boxes = featureBoxes.filter((f) => f.group === group);
    return boxes.length ? h('div', { class: 'stack' }, h('small', { class: 'muted', text: title }),
      ...boxes.map((f) => h('label', { class: 'check' }, f.input, h('span', { text: f.label }), h('small', { class: 'mono muted', text: f.id })))) : null;
  };
  const features = featureBoxes.length ? h('fieldset', {}, h('legend', { text: fixed ? '高级功能（Profile已固定）' : '高级功能（形式化门控默认开启，Preview 默认关闭）' }),
    featureGroup('formal', 'Lean 形式化门控'), featureGroup('preview', 'Preview 特性')) : '';
  const feedback = h('div', { role: 'status', class: 'form-feedback' });
  const submit = h('button', { type: 'submit', class: 'button primary', disabled: true }, '创建作业');
  const blocked = h('small', { class: 'muted', role: 'status' });

  function setupReasons() {
    const harbor = [...state.suitePick.keys()].some((id) => (byId.get(id) || {}).runner !== 'workbuddy');
    return [...(c.global_reasons || []), ...(harbor ? (c.harbor_reasons || []) : []),
      ...(harbor ? (selectedExecutor().reasons || []) : [])];
  }
  function syncSubmit() {
    const picked = [...state.suitePick.entries()];
    const total = picked.reduce((acc, [, e]) => acc + (e ? e.selected.size : 0), 0);
    const reasons = [];
    if (!picked.length) reasons.push('请选择评测集');
    if (!chosenModels.size) reasons.push('请至少选择一个模型');
    for (const [id, e] of picked) {
      const s = byId.get(id);
      if (!comboReady(s)) reasons.push(`${s.name} 在当前执行机器上待配置`);
      else if (!e) reasons.push(`${s.name} 正在读取任务列表`);
      else if (e.error && !e.tasks.length) reasons.push(`${s.name} 读取任务失败：${e.error}`);
      else if (!e.selected.size) reasons.push(`${s.name} 还没有选择任务`);
      else if (e.selected.size > s.max_tasks) reasons.push(`${s.name} 已选 ${e.selected.size} 题，超过上限 ${s.max_tasks}`);
    }
    if (!c.can_run) reasons.push('只读模式，不能发起评测');
    if (!fixed && !bundles.length) reasons.push('还没有可用的 metacodes 版本');
    submit.disabled = close.disabled || reasons.length > 0;
    blocked.textContent = reasons.length ? '无法开始：' + reasons.join('；') : '';
    const modelText = chosenModels.size > 1 ? ` · ${chosenModels.size} 个模型` : '';
    submit.textContent = picked.length ? `创建作业（${picked.length} 个评测集 · ${total} 道题 × ${attempts.value || '?'} 次${modelText}）` : '创建作业';
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
        s.description ? h('span', { class: 'suite-desc', text: s.description }) : null,
        h('span', { class: 'sub', text: (s.task_count === null ? '任务待准备' : s.task_count + ' 题') + ' · ' + (RUNNERS[s.runner] || s.runner) }),
        h('span', { class: 'suite-state ' + (comboReady(s) ? 'ok' : s.available ? 'todo' : 'off'), text: (state.suitePick.has(s.id) ? '已加入 · ' : '') + (comboReady(s) ? '可运行' : s.available ? '待配置' : '尚未接入') })))));
    }).filter(Boolean));
  }
  function suiteBox(s, entry) {
    const shown = new Set(setupReasons());
    const reasons = comboReasons(s).filter((text) => !shown.has(text));
    const remove = h('button', { type: 'button', class: 'button', onclick: () => { state.suitePick.delete(s.id); drawPicker(); drawBoxes(); syncSubmit(); } }, '移出');
    const head = h('div', { class: 'suite-box-head' }, h('span', { class: 'muted', text: s.description || '' }), remove);
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
    if (dialog.open && state.suitePick?.has(id) && state.taskTickets.get(id) === ticket) {
      if (!entry.error) state.taskWanted.delete(id);
      state.suitePick.set(id, entry); drawBoxes(); syncSubmit();
    }
  }
  attempts.addEventListener('input', syncSubmit);

  if (executorsList.length) {
    form.append(h('label', { class: 'field' }, h('span', { text: '执行机器' }), executor));
  }
  if (draft.from) {
    const notes = [`在Profile「${draft.from}」上运行`];
    if (modelMissing) notes.push(`上次的模型 ${modelMissing} 当前不可用，请重新选择。`);
    form.append(h('div', { class: 'callout' }, notes.map((text) => h('p', { text })),
      h('button', { type: 'button', class: 'button', onclick: () => {
        clearRunDraft(); refreshForm();
      } }, '改为新的Profile')));
  }
  form.append(
    h('div', { class: 'form-row' },
      h('div', { class: 'field' }, h('label', { class: 'field' }, h('span', { text: 'metacodes 版本' }), bundle),
        fixed || bundles.length ? null : h('small', { text: '还没有可用的 Linux 发行包，请先运行一键配置。' }),
        c.can_run && !fixed ? h('div', {}, commitToggle) : null),
      fixed ? null : h('label', { class: 'field' }, h('span', { text: 'Profile名称（可选）' }), name)),
    fixed ? null : commitBox,
    features,
    h('div', { class: 'field' }, h('span', { text: '模型（可多选，每个评测集按每个模型各跑一次）' }), model,
      h('small', { text: c.authentication?.label || '使用执行服务上配置的 Provider 和凭证' }),
      h('small', {}, c.providers?.models ? `另有 ${c.providers.count} 个导入的 Provider · ${c.providers.models} 个模型 · ` : '',
        link('#/settings/providers', '配置模型 Provider')),
      c.account_summary ? h('small', { text: `${c.account_summary.available_groups} / ${c.account_summary.groups} 个模型组可用 · ${c.account_summary.models} 个模型` }) : null,
      c.reasoning_effort ? h('small', { text: '推理强度：' + c.reasoning_effort }) : null),
    h('fieldset', {}, h('legend', { text: '评测集（可多选）' }), picker), boxes,
    h('div', { class: 'form-row' }, h('div', { class: 'field' }, h('label', { class: 'field' }, h('span', { text: '每题次数' }), attempts),
      h('small', { text: concurrencyNote }))),
    h('div', { class: 'form-submit' }, submit, blocked, feedback));
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (close.disabled) return;
    close.disabled = true;
    dialog.ariaBusy = 'true';
    form.inert = true;
    submit.disabled = true;
    feedback.textContent = fixed ? '正在排队…' : '正在冻结 metacodes 版本并排队…';
    try {
      const picked = models.filter((m) => chosenModels.has(m.id)).map((m) => m.id);
      const request = { ...(picked.length > 1 ? { models: picked } : { model: picked[0] }), attempts: Number(attempts.value),
        items: [...state.suitePick.entries()].map(([id, entry]) => ({ suite: id, tasks: entry.tasks.filter((t) => entry.selected.has(t)) })) };
      if (fixed) request.profile = draft.profile;
      else {
        if (bundle.value) request.bundle = bundle.value;
        if (name.value.trim()) request.name = name.value.trim();
        request.features = featureBoxes.filter((f) => f.input.checked).map((f) => f.id);
      }
      if (executorsList.length) request.executor = executor.value;
      const record = await api('/api/profiles/run', request);
      dialog.close();
      if (location.hash === profileHref(record)) render();
      else location.hash = profileHref(record);
    } catch (error) {
      close.disabled = false;
      dialog.ariaBusy = 'false';
      form.inert = false;
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
      actions.push(link('#/settings/login', '前往系统配置登录 Metask'));
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
  async function drawSetup() {
    if (!c.can_run) return;
    let latest = null;
    try { latest = (await api('/api/setup')).setup; } catch (_) { return; }
    const parts = [];
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
    const active = latest && latest.status === 'running';
    if (active && dialog.open) { state.setupWatch = true; setTimeout(drawSetup, 2000); }
    else if (state.setupWatch && !active) { state.setupWatch = false; setTimeout(refreshForm, 500); }
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
        ? h('button', { type: 'button', class: 'button', onclick: () => { state.pickBundle = x.bundle; refreshForm(); } }, '已编译 · 选用')
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
        latest.status === 'done' && latest.bundle ? h('button', { type: 'button', class: 'button', onclick: () => { state.pickBundle = latest.bundle; refreshForm(); } }, '选用这个版本') : null),
      (latest.log || []).length ? h('pre', { class: 'muted', text: latest.log.join('\n') }) : null));
    if (running && dialog.open && commitBox.isConnected) setTimeout(drawBuild, 2000);
    else if (state.buildWatch === latest.id && latest.status === 'done') { state.buildWatch = null; state.pickBundle = latest.bundle; setTimeout(refreshForm, 300); }
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
    panel('作业配置', null, form), groups);
}

async function renderRun(name) {
  const endpoint = '/api/run?name=' + encodeURIComponent(name);
  const run = await api(endpoint);
  let results;
  if (run.result_owner) {
    const view = run.worker_summary?.view;
    results = view ? panel('评测结果', run.result_owner, h('div', { class: 'panel-body' },
      outcomeBar(view.summary.counts, view.summary.trials, true), legend(view.summary.counts),
      link('#/job/' + encodeURIComponent(name), '查看评测详情'))) : null;
  } else {
    try { results = await renderJob(name); } catch (_) { results = h('div', { class: 'empty', text: '等待 Harbor 创建评测记录' }); }
  }
  state.live = ['queued', 'starting', 'running', 'cancelling'].includes(run.status);
  navCurrent('overview');
  $('#title').textContent = RUN_STATUS[run.status] || run.status;
  crumbs([{ text: 'Profiles', href: '#/' }, { text: name }]);
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
  const logText = h('pre', { text: run.log || '正在准备执行环境…' });
  const log = h('details', { class: 'panel', 'data-key': 'runlog', ontoggle: async (event) => {
    if (!event.currentTarget.open || !run.result_owner) return;
    try {
      const detail = await api(endpoint + '&log=1');
      logText.textContent = [detail.log, detail.log_error].filter(Boolean).join('\n') || '暂无执行日志';
    } catch (error) { logText.textContent = [run.log, error.message].filter(Boolean).join('\n'); }
  } }, h('summary', { text: '执行日志' }), logText);
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

function resultLocation(value) {
  if (!value.result_owner) return null;
  const source = value.detail_source === 'database' ? '共用数据库' : 'worker 节点';
  return h('div', { class: 'muted', text: `作业所在节点 · ${value.result_owner}　详情来源 · ${source}` });
}

async function renderJob(name) {
  navCurrent('overview');
  const job = await api('/api/job?name=' + encodeURIComponent(name));
  state.live = job.running;
  $('#title').textContent = job.name;
  crumbs([{ text: 'Profiles', href: '#/' }, job.profile ? { text: 'Profile ' + job.profile, href: '#/profile/' + encodeURIComponent(job.profile) } : null, { text: job.name }].filter(Boolean));
  const s = job.summary;
  const causes = Object.entries(s.invalid_causes).map(([k, v]) => `${k} ${v}`).join(' · ');
  const metrics = h('section', { class: 'metrics' }, measurementCards(s),
    metric('平均 reward', s.mean_reward === null ? '—' : s.mean_reward.toFixed(2)),
    metric('完成', `${s.trials - s.counts.running} / ${job.planned}`, job.running ? '运行中' : '已结束 · ' + dur(job.wall_s)),
    metric('无效', String(s.counts.invalid), causes || '无'),
    metric('空回复结束', String(s.empty_final)),
    metric('输入 / 输出 Token', `${compact(s.input_tokens)} / ${compact(s.output_tokens)}`, `缓存 ${pct(s.input_tokens ? s.cache_tokens / s.input_tokens : null)}`));

  const identity = h('div', { class: 'panel-body' },
    resultLocation(job),
    h('div', { class: 'muted' }, `${job.suite_name ? '评测集 ' + job.suite_name + '（' + job.category_name + '） · ' : ''}${job.metacodes?.label ? 'metacodes ' + job.metacodes.label + (job.metacodes.frozen ? '（Profile冻结）' : '') + ' · ' : ''}模型 ${job.model || '—'} · agent ${job.agent || '—'} · 数据集 ${job.dataset || '—'} · 每题 ${job.attempts ?? '—'} 次 · 并发 ${job.concurrency ?? '—'}${job.judge ? ' · ' + judgeText(job.judge) : ''}`),
    outcomeBar(s.counts, s.trials, true), legend(s.counts));

  const timed = job.rows.some((r) => r.lifecycle) ? PREPARE_PARTS.map(([, l, cls]) => [cls, l]) : [];
  const keys = h('div', { class: 'panel-body' }, timed.concat(PHASES.map(([k, l]) => ['p-' + k, l])).map(([cls, l]) => h('span', { class: 'key' }, h('i', { class: cls }), l)));
  const table = localView((redraw) => {
    const filters = h('div', { class: 'filters' }, ['all', ...ORDER].map((key) => h('button', {
      type: 'button', class: state.jobFilter === key ? 'on' : null,
      onclick: () => { state.jobFilter = key; redraw(); },
    }, key === 'all' ? `全部 ${s.trials}` : `${STATUS[key]} ${s.counts[key]}`)));
    const search = h('input', { type: 'search', placeholder: '搜索任务', value: state.jobSearch, 'aria-label': '搜索任务',
      oninput: (e) => { state.jobSearch = e.target.value; drawRows(); } });
    const tbody = h('tbody', {});
    const head = h('tr', {}, COLUMNS.map(([key, label]) => {
      const th = h('th', { class: 'sortable' + (key === 'task' || key === 'status' || key === 'stop_reason' || key === 'phases' ? '' : ' num'), text: label,
        onclick: () => { state.sort = { key, dir: state.sort.key === key ? -state.sort.dir : 1 }; redraw(); } });
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
      const maxTime = Math.max(1, ...job.rows.map(timeTotal));
      tbody.replaceChildren(...(rows.length ? rows.map((r) => {
        const bar = h('div', { class: 'phase-bar', title: timeTitle(r) },
          timeParts(r).map(([cls, v]) => v ? h('span', { class: cls, width: (100 * v / maxTime) + '%' }) : null));
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
    return [h('div', { class: 'panel-body toolbar' }, filters, search),
      h('div', { class: 'table-scroll' }, h('table', {}, h('thead', {}, head), tbody)), keys];
  });
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

function prepareCase(life) {
  if (!life.prepare || life.prepare.status === 'skipped') return '没有预准备：' + (life.prepare && life.prepare.error ? life.prepare.error : '这道题的环境由 Harbor 在开始后自己准备');
  const failed = life.prepare.status === 'failed';
  const handover = '环境交给 Harbor 在开始后重新拉取或构建';
  if (life.unprepared_wait_s !== null && life.unprepared_wait_s !== undefined) return `提前准备失败，之后等待 ${dur(life.unprepared_wait_s)} 才排到；${handover}`;
  if (life.ready_wait_s !== null) return `准备好后等待 ${dur(life.ready_wait_s)} 才排到，排到后直接运行`;
  const outcome = failed ? `；准备失败，${handover}` : '';
  if (life.prepare_s !== null) return `排到时仍在准备：预准备 ${dur(life.prepare_s)}，开始后又准备了 ${dur(life.prepare_running_s)}${outcome}`;
  return `排到时还没开始准备，开始后准备了 ${dur(life.prepare_running_s)}${outcome}`;
}
function prepareItems(prepare) {
  if (!prepare || !prepare.items.length) return null;
  return h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['准备动作', '镜像', '结果', '用时'].map((x, i) => h('th', { class: i === 3 ? 'num' : null, text: x })))),
    h('tbody', {}, prepare.items.map((x) => h('tr', {},
      h('td', { text: x.kind === 'build' ? '构建' : '拉取' }),
      h('td', {}, h('span', { class: 'mono', text: x.image }), x.error ? h('span', { class: 'sub flag', text: x.error }) : null),
      h('td', { class: x.status === 'failed' ? 'flag' : null, text: (PREPARE_RESULTS[x.status] || x.status) + (x.shared ? '（与同镜像的题共用）' : '')
        + (x.attempts > 1 ? (x.status === 'failed' ? ` · 试了 ${x.attempts} 次` : ` · 第 ${x.attempts} 次成功`) : '') }),
      h('td', { class: 'num', text: dur(x.seconds) }))))));
}
function timeRest(r) { return r.lifecycle && r.lifecycle.total_s !== null ? Math.max(0, r.lifecycle.total_s - timeTotal(r)) : null; }
function lifecycleBlock(r) {
  const life = r.lifecycle;
  if (!life) return null;
  const segments = timeParts(r).concat([['t-other', timeRest(r), '其他（创建与收尾）']]);
  const total = segments.reduce((acc, [, v]) => acc + (v || 0), 0);
  const bar = h('div', { class: 'stack-bar', role: 'img', 'aria-label': timeTitle(r) },
    total > 0 ? segments.map(([cls, v, l]) => v ? h('span', { class: cls, width: (100 * v / total) + '%', title: `${l} ${dur(v)}（${pct(v / total)}）` }) : null) : null);
  return h('div', {},
    h('p', { class: 'muted', text: `从开始准备到结束 ${dur(life.total_s)} · 此前排队 ${dur(life.queue_s)}（不计入）` }),
    bar,
    h('p', { class: 'muted', text: prepareCase(life) }),
    prepareItems(life.prepare));
}
function timePanel(t) {
  const r = t.row;
  const split = t.time_split || {};
  const rows = (r.lifecycle ? [['l-queue', r.lifecycle.queue_s, '排队（不计入）']] : []).concat(timeParts(r),
    r.lifecycle ? [['t-other', timeRest(r), '其他（创建与收尾）']] : []);
  const phaseTotal = timeTotal(r) + (timeRest(r) || 0);
  const phases = h('div', { class: 'split' }, rows.map(([cls, v, l]) => h('div', { class: 'split-row' }, h('span', { text: l }),
    h('div', { class: 'stack-bar' }, cls === 'l-queue' ? null : h('span', { class: cls, width: (phaseTotal ? 100 * (v || 0) / phaseTotal : 0) + '%' })),
    h('span', { class: 'num muted', text: dur(v) }))));
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
    panel('耗时', r.lifecycle ? `总用时 ${dur(r.lifecycle.total_s)}（从开始准备算起）` : `总用时 ${dur(r.elapsed_s)}`,
      h('div', { class: 'panel-body split' }, lifecycleBlock(r), phases, agentBlock)),
    panel('工具耗时', `${timing.reduce((a, x) => a + x.calls, 0)} 次`, tools));
}

function tracePanel(steps, trial) {
  if (!steps.length) return panel('轨迹', null, h('div', { class: 'empty', text: '还没有轨迹' }));
  const scope = JSON.stringify([location.hash, trial]);
  const previous = $('.trace-chart');
  const activeKey = previous?.dataset.scope === scope ? previous.querySelector('[aria-pressed=true]')?.dataset.key : null;
  const chart = h('div', { class: 'trace-chart', 'data-scope': scope });
  const detail = h('div', { class: 'trace-detail' });
  let selected;
  let column = 1;
  function span(label, kind, row, start, width, title, content) {
    const button = h('button', { type: 'button', class: 'trace-span ' + kind, text: label, title, 'data-key': row + '-' + start,
      'aria-pressed': 'false', onclick: () => {
        if (selected) selected.setAttribute('aria-pressed', 'false');
        selected = button;
        selected.setAttribute('aria-pressed', 'true');
        detail.replaceChildren(h('strong', { text: title }), ...content());
      } });
    button.style.gridRow = row;
    button.style.gridColumn = start + ' / span ' + width;
    chart.append(button);
    if (!selected || button.dataset.key === activeKey) button.click();
  }
  function resultNodes(observations) {
    return observations.flatMap(o => [h('b', { text: o.is_error ? '结果（错误）' : '结果' }), h('pre', { text: o.content })]);
  }
  for (const s of steps) {
    const width = Math.max(1, s.tool_calls.length);
    const label = s.source === 'user' ? '任务' : s.source === 'agent' ? 'Agent' : s.source;
    const title = '#' + s.id + ' · ' + label;
    const ids = new Set(s.tool_calls.map(call => call.id));
    const unmatched = s.observations.filter(o => !ids.has(o.call));
    span(title, 'step-span', 1, column, width, title, () => [
      h('div', { class: 'msg-text', text: s.message }),
      ...(s.reasoning ? [h('details', { class: 'reason' }, h('summary', { text: '思考过程' }), h('pre', { text: s.reasoning }))] : []),
      ...resultNodes(unmatched)]);
    s.tool_calls.forEach((call, i) => {
      const results = s.observations.filter(o => o.call === call.id);
      const error = results.some(o => o.is_error);
      const duration = call.elapsed_ms == null ? '' : ' · ' + msf(call.elapsed_ms);
      const name = call.name + duration + (error ? ' · 错误' : '');
      span(name, error ? 'error-span' : 'tool-span', 2, column + i, 1, title + ' / ' + name, () => [
        h('b', { text: '参数' }), h('pre', { text: call.arguments }), ...resultNodes(results)]);
    });
    column += width;
  }
  return panel('轨迹', steps.length + ' 步 · 按操作顺序排列', h('div', { class: 'panel-body' },
    h('div', { class: 'trace-layout' }, h('div', { class: 'trace-labels' }, h('span', { text: '步骤' }),
      h('span', { text: '工具' })), h('div', { class: 'trace-scroll', tabindex: '0' }, chart)), detail));
}

function usagePanel(title, counts, empty) {
  if (!counts) return panel(title, null, h('div', { class: 'empty', text: '暂无统计数据' }));
  const total = counts.reduce((sum, [, n]) => sum + n, 0);
  const max = counts.reduce((largest, [, n]) => Math.max(largest, n), 1);
  return panel(title, total + ' 次', counts.length ? h('div', { class: 'panel-body usage-bars' }, counts.map(([name, n]) =>
    h('div', { class: 'usage-row' }, h('span', { class: 'tool-name', text: name ?? '名称未知' }),
      h('div', { class: 'bar' }, h('span', { width: (100 * n / max) + '%' })), h('span', { class: 'num', text: n }))))
    : h('div', { class: 'empty', text: empty }));
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
    metric('用时', dur(r.lifecycle ? r.lifecycle.total_s : r.elapsed_s), timeTitle(r)));
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
  parts.push(panel('判分测试', t.tests ? `${t.tests.passed}/${t.tests.total} 通过` : null, tests));
  parts.push(h('div', { class: 'grid-2' }, usagePanel('工具使用', t.tools, '没有工具调用'),
    usagePanel('Skill 使用', t.skills, '没有 Skill 调用')));
  parts.push(tracePanel(t.steps, r.trial));
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
  crumbs([{ text: 'Profiles', href: '#/' }, { text: jobName, href: '#/job/' + encodeURIComponent(jobName) }, { text: r.trial }]);
  return h('div', {}, resultLocation(t), trialBody(t));
}

// ------------------------------------------------------------ compare
const VALID_STATUSES = ['pass', 'partial', 'fail', 'timeout'];
function jobTitle(j) { return j.profile_name || j.model || j.name; }
function jobSub(j) {
  return [j.profile_version ? 'v' + j.profile_version : null, j.profile_features?.length ? j.profile_features.join(', ') : null,
    j.profile_name ? j.model : null, j.name].filter(Boolean).join(' · ');
}
function deltaPct(curr, base) {
  if (curr === null || curr === undefined || base === null || base === undefined) return '';
  const d = (curr - base) * 100;
  return (d > 0 ? '+' : '') + d.toFixed(1) + '%';
}
function deltaRel(curr, base) {
  if (curr === null || curr === undefined || base === null || base === undefined || base <= 0) return null;
  const d = (curr - base) / base * 100;
  return { value: d, text: (d > 0 ? '+' : '') + Math.round(d) + '%' };
}
function compareCsv(jobs, tasks, byJob) {
  const esc = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const head = ['task', ...jobs.flatMap((j) => [`${jobTitle(j)} status`, `${jobTitle(j)} tokens`, `${jobTitle(j)} elapsed_s`])];
  const lines = [head.map(esc).join(',')];
  for (const task of tasks) {
    lines.push([task, ...byJob.flatMap((m) => {
      const r = m.get(task);
      return r ? [r.status, r.total_tokens ?? '', r.elapsed_s ?? ''] : ['', '', ''];
    })].map(esc).join(','));
  }
  return lines.join('\n') + '\n';
}

async function renderCompare(names, profileId) {
  navCurrent('overview');
  $('#title').textContent = '多版本对比台';
  const uniqueNames = [...new Set(names.filter(Boolean))];
  crumbs([{ text: 'Profiles', href: '#/' }, ...(profileId ? [{ text: 'Profile 作业', href: profileHref({ id: profileId }) }] : []), { text: '多版本对比' }]);
  if (uniqueNames.length < 2) {
    state.live = false;
    return panel('对比', null, h('div', { class: 'empty', text: '从首页或榜单勾选 2 个以上 Profile，或从 Profile 详情进入作业对比。' }));
  }
  const loaded = await Promise.all(uniqueNames.map((n) => api('/api/job?name=' + encodeURIComponent(n))));
  state.live = loaded.some((j) => j.running);
  const prefix = profileId ? profileHref({ id: profileId }) + '/compare/' : '#/compare/';
  return localView((redraw) => {
    const baseName = uniqueNames.includes(state.compareBaseline) ? state.compareBaseline : uniqueNames[0];
    state.compareBaseline = baseName;
    const jobs = [loaded.find((j) => j.name === baseName), ...loaded.filter((j) => j.name !== baseName)];
    const colors = jobs.map((_, i) => profileColor(i));
    const byJob = jobs.map((j) => {
      const m = new Map();
      for (const r of j.rows) if (r.first_attempt) m.set(r.task, r);
      return m;
    });
    const tasks = [...new Set(jobs.flatMap((j) => j.rows.map((r) => r.task)))].sort();
    const common = tasks.filter((t) => byJob.every((m) => m.has(t) && VALID_STATUSES.includes(m.get(t).status)));
    const suiteName = [...new Set(jobs.map((j) => j.suite_name || j.dataset).filter(Boolean))].join(' / ');

    const chips = jobs.map((j, i) => {
      const isBase = i === 0;
      const removeBtn = jobs.length > 2 ? h('button', { type: 'button', title: '移出对比', 'aria-label': '移出 ' + jobTitle(j),
        onclick: () => {
          const rest = jobs.filter((x) => x.name !== j.name).map((x) => x.name);
          location.hash = prefix + rest.map(encodeURIComponent).join(',');
        } }, '×') : null;
      const pinBtn = !isBase ? h('button', { type: 'button', title: '设为基准',
        onclick: () => { state.compareBaseline = j.name; redraw(); } }, '设为基准') : null;
      return h('span', { class: 'ver-chip', style: `border-color:${colors[i]}88` },
        h('span', { style: `color:${colors[i]}`, text: '★' }),
        h('strong', { class: 'mono', text: jobTitle(j) }),
        isBase ? h('span', { class: 'tag warn', text: '基准' }) : pinBtn,
        removeBtn);
    });
    const exportBtn = h('button', { type: 'button', class: 'button sm', onclick: () => {
      const blob = new Blob([compareCsv(jobs, tasks, byJob)], { type: 'text/csv;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = h('a', { href: url, download: 'bench-compare.csv' });
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } }, '导出对比 CSV');
    const modelsAcrossJobs = new Set(jobs.map((j) => j.model).filter(Boolean));
    const ctrlBar = h('div', { class: 'cmp-ctrl' },
      h('div', { class: 'cmp-chips' }, h('span', { class: 'muted', style: 'font-size:12px', text: '对比对象：' }), ...chips),
      h('div', { style: 'display:flex;gap:8px;align-items:center;flex-wrap:wrap' },
        modelsAcrossJobs.size > 1 ? h('span', { class: 'tag warn', text: `含 ${modelsAcrossJobs.size} 个不同模型` }) : null,
        suiteName ? h('span', { class: 'tag', text: '评测集：' + suiteName }) : null, exportBtn));

    const points = jobs.map((j) => commonCostPass(j, common));
    const commonRates = jobs.map((_, i) => common.length ? common.filter((t) => byJob[i].get(t).status === 'pass').length / common.length : null);
    const baseRate = commonRates[0];
    const baseCommonCost = points[0]?.cost;
    const summaryRows = jobs.map((j, i) => {
      const s = j.summary;
      const isBase = i === 0;
      const point = points[i];
      const frontier = point && !points.some((other) => other && dominated(point, other));
      let wins = 0; let losses = 0;
      if (!isBase) {
        for (const t of common) {
          const bPass = byJob[0].get(t).status === 'pass';
          const cPass = byJob[i].get(t).status === 'pass';
          if (!bPass && cPass) wins += 1;
          else if (bPass && !cPass) losses += 1;
        }
      }
      const rDelta = !isBase ? deltaPct(commonRates[i], baseRate) : '';
      const cDelta = !isBase ? deltaRel(point?.cost, baseCommonCost) : null;
      const meanTok = s.token_trials ? s.total_tokens / s.token_trials : null;
      const roleTag = isBase ? h('span', { class: 'tag warn', style: 'margin-right:6px', text: '基准' })
        : h('button', { type: 'button', class: 'tag acc', style: 'margin-right:6px;cursor:pointer', title: '点击设为基准',
          onclick: () => { state.compareBaseline = j.name; redraw(); } }, i === jobs.length - 1 ? '候选' : `版本 ${i + 1}`);
      return h('tr', { class: !isBase && i === jobs.length - 1 ? 'ours' : null },
        h('td', {}, roleTag, h('strong', { class: 'mono', text: jobTitle(j) }), h('span', { class: 'sub mono', text: jobSub(j) })),
        h('td', { class: 'num mono' + (rDelta.startsWith('+') ? ' pos' : rDelta.startsWith('-') ? ' neg' : '') },
          pct(commonRates[i], 1), rDelta ? ` (${rDelta})` : ''),
        h('td', { class: 'num mono' }, isBase ? h('span', { class: 'faint', text: '基准' })
          : common.length ? h('span', {}, h('span', { class: 'pos', text: '+' + wins }), ' / ', h('span', { class: 'neg', text: '-' + losses })) : dash()),
        h('td', { class: 'num mono' + (cDelta ? (cDelta.value < 0 ? ' pos' : cDelta.value > 0 ? ' neg' : '') : '') },
          point ? usd(point.cost) : dash(), cDelta ? ` (${cDelta.text})` : '',
          point ? h('span', { class: 'sub mono', text: `均通过 ${pct(point.pass, 1)}` }) : null),
        h('td', {}, frontier ? h('span', { class: 'tag pos', text: '★ 前沿' }) : point ? '' : dash()),
        h('td', { class: 'num mono' }, usd(s.cost_per_task),
          h('span', { class: 'sub mono', text: `通过 ${usd(s.cost_per_pass)}` })),
        h('td', { class: 'num mono', text: `${s.tasks_solved || 0} / ${s.tasks_attempted || 0}` }),
        h('td', { class: 'num mono', text: compact(meanTok) }),
        h('td', { class: 'num mono', text: pct(s.cache_hit_rate) }));
    });
    const summaryHeads = ['Profile 版本', '共同题首次满分', '较基准胜负', '共同题成本 / 均通过', '前沿', '全量每题 / 通过成本', '至少通过一次', '平均总 Token', '缓存命中'];
    const summaryPanel = panel('多版本总览矩阵', `共同首次有效 ${common.length} / ${tasks.length} 题 · 成本变化与前沿均按共同题计算 · 点击版本标签可切换基准`,
      h('div', { class: 'table-scroll' }, h('table', {},
        h('thead', {}, h('tr', {}, summaryHeads.map((t, i) => h('th', { class: i > 0 && i !== 4 ? 'num' : null, text: t })))),
        h('tbody', {}, summaryRows))));

    const candIdx = jobs.length - 1;
    const classified = tasks.map((task) => {
      const rows = byJob.map((m) => m.get(task) || null);
      const b = rows[0]; const c = rows[candIdx];
      const bValid = b && VALID_STATUSES.includes(b.status);
      const cValid = c && VALID_STATUSES.includes(c.status);
      const statuses = rows.map((r) => r?.status).filter(Boolean);
      const changed = new Set(statuses).size > 1 || rows.some((r) => !r);
      let kind = 'same_fail';
      if (!bValid || !cValid) kind = c && c.status === 'pass' && b && b.status === 'invalid' ? 'fixed_invalid' : 'invalid';
      else if (b.status !== 'pass' && c.status === 'pass') kind = 'gain';
      else if (b.status === 'pass' && c.status !== 'pass') kind = 'regress';
      else if (b.status === 'pass' && c.status === 'pass') kind = 'same_pass';
      const tokDelta = deltaRel(c?.total_tokens, b?.total_tokens);
      return { task, rows, kind, changed, tokDelta };
    });
    const flowCounts = {
      gain: classified.filter((x) => x.kind === 'gain').length,
      same_pass: classified.filter((x) => x.kind === 'same_pass').length,
      regress: classified.filter((x) => x.kind === 'regress').length,
      same_fail: classified.filter((x) => x.kind === 'same_fail').length,
      invalid: classified.filter((x) => x.kind === 'invalid' || x.kind === 'fixed_invalid').length,
    };
    const flowBar = tasks.length ? h('section', { class: 'flow-strip' },
      h('div', { class: 'flow-head' },
        h('strong', { text: `${tasks.length} 道题演进分布（${jobTitle(jobs[candIdx])} vs ${jobTitle(jobs[0])}）` }),
        h('span', { class: 'mono' },
          h('span', { class: 'pos', text: `突破通过 ${flowCounts.gain}` }), ' · ',
          h('span', { class: 'muted', text: `持续通过 ${flowCounts.same_pass}` }), ' · ',
          h('span', { class: 'neg', text: `退步 ${flowCounts.regress}` }), ' · ',
          h('span', { class: 'faint', text: `持续失败 ${flowCounts.same_fail}` }), ' · ',
          h('span', { class: 'warn', text: `无效/单侧 ${flowCounts.invalid}` }))),
      h('div', { class: 'outcome-bar big' },
        flowCounts.gain ? h('span', { class: 'seg s-pass', width: (100 * flowCounts.gain / tasks.length) + '%' }) : null,
        flowCounts.same_pass ? h('span', { class: 'seg', style: `width:${100 * flowCounts.same_pass / tasks.length}%;background:#3a5c52` }) : null,
        flowCounts.regress ? h('span', { class: 'seg s-fail', width: (100 * flowCounts.regress / tasks.length) + '%' }) : null,
        flowCounts.same_fail ? h('span', { class: 'seg', style: `width:${100 * flowCounts.same_fail / tasks.length}%;background:#393840` }) : null,
        flowCounts.invalid ? h('span', { class: 'seg s-invalid', width: (100 * flowCounts.invalid / tasks.length) + '%' }) : null)) : null;

    const filterMeta = [
      ['all', '全部', classified.length],
      ['diff', '仅看变化', classified.filter((x) => x.changed).length],
      ['gain', '突破通过', flowCounts.gain],
      ['regress', '退步', flowCounts.regress],
      ['fail', '持续失败', flowCounts.same_fail],
      ['invalid', '无效/单侧', flowCounts.invalid],
    ];
    const filterChips = h('div', { class: 'chips', style: 'padding:0' }, filterMeta.map(([key, label, cnt]) =>
      h('button', { type: 'button', class: 'chip', 'aria-pressed': String(state.compareFilter === key),
        onclick: () => { state.compareFilter = key; redraw(); } }, label, ' ', h('span', { class: 'mono faint', text: String(cnt) }))));
    const search = h('input', { type: 'search', placeholder: '搜索任务', value: state.compareSearch, 'aria-label': '搜索对比任务',
      onfocus: () => { state.editing = true; }, onblur: () => { state.editing = false; },
      oninput: (e) => { state.compareSearch = e.target.value; drawMatrix(); } });
    const tbody = h('tbody', {});

    const TREND_INFO = {
      gain: ['gain', '↗ 突破通过'],
      regress: ['regress', '↘ 出现退步'],
      same_pass: ['same', '→ 持续通过'],
      same_fail: ['same', '→ 持续失败'],
      fixed_invalid: ['warn', '↺ 修复无效'],
      invalid: ['warn', '无效 / 单侧'],
    };

    function drawMatrix() {
      const q = (state.compareSearch || '').trim().toLowerCase();
      const visible = classified.filter((x) => {
        if (state.compareFilter === 'diff' && !x.changed) return false;
        if (state.compareFilter === 'gain' && x.kind !== 'gain') return false;
        if (state.compareFilter === 'regress' && x.kind !== 'regress') return false;
        if (state.compareFilter === 'fail' && x.kind !== 'same_fail') return false;
        if (state.compareFilter === 'invalid' && x.kind !== 'invalid' && x.kind !== 'fixed_invalid') return false;
        return !q || x.task.toLowerCase().includes(q);
      });
      tbody.replaceChildren(...(visible.length ? visible.map((x) => {
        const [cls, label] = TREND_INFO[x.kind];
        const rowCls = x.kind === 'gain' ? 'gain' : x.kind === 'regress' ? 'regress' : x.changed ? 'diff' : null;
        return h('tr', { class: rowCls },
          h('td', { class: 'mono', text: x.task }),
          ...x.rows.map((r, i) => {
            if (!r) return h('td', {}, dash());
            const info = [r.tests ? `${r.tests.passed}/${r.tests.total}` : null, compact(r.total_tokens), dur(r.elapsed_s)].filter(Boolean).join(' · ');
            return h('td', {}, h('div', { class: 'cmp3-cell' },
              h('a', { href: `#/job/${encodeURIComponent(jobs[i].name)}/${encodeURIComponent(r.trial)}` }, badge(r.status, r.cause)),
              h('span', { class: 'cmp3-sub', text: info })));
          }),
          h('td', {}, h('span', { class: 'trend-badge ' + cls, text: label })),
          h('td', { class: 'num mono' + (x.tokDelta ? (x.tokDelta.value < 0 ? ' pos' : x.tokDelta.value > 0 ? ' neg' : '') : ' faint'),
            text: x.tokDelta ? x.tokDelta.text : '—' }));
      }) : [h('tr', {}, h('td', { colspan: jobs.length + 3, class: 'empty', text: '没有符合条件的对比任务' }))]));
    }
    drawMatrix();

    const matrixTable = h('div', { class: 'table-scroll' }, h('table', { class: 'matrix' },
      h('thead', {}, h('tr', {},
        h('th', { text: '任务' }),
        ...jobs.map((j, i) => h('th', {},
          h('span', { style: `color:${colors[i]};margin-right:5px`, text: '★' }),
          h('span', { text: jobTitle(j) }),
          h('span', { class: 'sub mono', text: [j.profile_version ? `v${j.profile_version}` : null, modelsAcrossJobs.size > 1 ? j.model : null, i === 0 ? '基准' : i === candIdx ? '候选' : `版本 ${i + 1}`].filter(Boolean).join(' · ') }))),
        h('th', { text: '演进趋势' }),
        h('th', { class: 'num' }, 'Token 变化', h('span', { class: 'sub', text: '候选 vs 基准' })))),
      tbody));
    const matrixPanel = panel(`${jobs.length} 版本逐题演进矩阵`, '点击任意单元格直达 Trial 轨迹与判分详情',
      h('div', {}, h('div', { class: 'panel-body toolbar', style: 'justify-content:space-between' }, filterChips, search), matrixTable));
    return [ctrlBar, summaryPanel, flowBar, matrixPanel];
  });
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

// ------------------------------------------------------------ public leaderboards
function score(x) { return x === null || x === undefined ? '—' : x.toFixed(1) + '%'; }
function modelKey(m) { return String(m || '').toLowerCase().replace(/^.*\//, '').replace(/[^a-z0-9]/g, ''); }
function boardModels(board) {
  return board.model_filter ? [...new Set(board.entries.map((e) => e.model))] : [];
}
function ourEntryLabel(j) { return j.profile_name || `metacodes · ${j.model || j.name}`; }
function ourEntryHref(j) { return j.profile ? profileHref({ id: j.profile }) : '#/job/' + encodeURIComponent(j.name); }
function boardRows(board, model) {
  const pooled = model === board.default_model;
  const published = board.entries.filter((e) => !board.model_filter || e.model === model)
    .map((e, i) => ({ ...e, id: 'p' + i, ours: null }));
  const ours = board.jobs.filter((j) => j.ranked && (!board.model_filter || pooled || modelKey(j.model) === modelKey(model)))
    .map((j) => ({ id: 'o-' + j.name, ours: j, harness: ourEntryLabel(j), model: j.model, score: j.score * 100,
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
const rowName = (r) => (r.ours ? ourEntryLabel(r.ours) : r.harness);
const beats = (a, b) => a.cost_per_task_usd <= b.cost_per_task_usd && a.score >= b.score && (a.cost_per_task_usd < b.cost_per_task_usd || a.score > b.score);
const PALETTE = ['#d95926', '#199e70', '#c98500', '#d55181', '#4fa34f', '#9085e9', '#e66767'];
const SHAPES = ['diamond', 'square', 'circle', 'triangle', 'hexagon'];
function spareHue(i) {
  const hue = (i * 137.508 + 20) % 360;
  return hue > 185 && hue < 245 ? (hue + 60) % 360 : hue;
}
function soleHarness(board) {
  const names = new Set(board.entries.map((e) => e.harness));
  return names.size === 1 ? [...names][0] : null;
}
function rowLooks(rows, byModel, ourColorMap) {
  const groupOf = (r) => (r.ours ? 'ours:' + r.ours.name : byModel ? r.model || r.harness : r.harness);
  const names = [...new Set(rows.filter((r) => !r.ours).map(groupOf))];
  const looks = new Map(names.map((name, i) => [name, { name,
    color: PALETTE[i] || `hsl(${spareHue(i)} 55% 62%)`, shape: SHAPES[i % SHAPES.length] }]));
  let ourIdx = 0;
  for (const r of rows) {
    if (!r.ours) continue;
    const key = groupOf(r);
    if (!looks.has(key)) {
      const col = ourColorMap?.get(r.ours.name) || profileColor(ourIdx++);
      looks.set(key, { name: ourEntryLabel(r.ours), color: col, shape: 'star' });
    }
  }
  return (r) => looks.get(groupOf(r));
}
const glyph = (look) => h('i', { class: 'glyph', 'data-shape': look.shape, style: 'background:' + look.color });
function niceTicks(lo, hi) {
  const raw = (hi - lo) / 5;
  const mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 5, 10].map((m) => m * mag).find((s) => s >= raw * 0.7);
  const ticks = [];
  for (let v = Math.ceil(lo / step) * step; v <= hi + step * 1e-9; v += step) ticks.push(+v.toPrecision(12));
  return { ticks, step };
}
function costTicks(lo, hi) {
  const decades = [];
  for (let e = Math.floor(Math.log10(lo)); e <= Math.ceil(Math.log10(hi)); e++) decades.push(10 ** e, 2 * 10 ** e, 5 * 10 ** e);
  const ticks = decades.filter((v) => v >= lo && v <= hi);
  return ticks.length >= 3 ? ticks : niceTicks(lo, hi).ticks;
}
function arrangeLabels(plot) {
  const box = plot.getBoundingClientRect();
  if (!box.width) return;
  const labels = [...plot.querySelectorAll('.scatter-label')]
    .sort((x, y) => Number(x.closest('.scatter-point').dataset.order) - Number(y.closest('.scatter-point').dataset.order));
  const marks = [...plot.querySelectorAll('.scatter-point .glyph')].map((m) => [m.closest('.scatter-point'), m.getBoundingClientRect()]);
  const front = marks.filter(([p]) => p.dataset.frontier).map(([, m]) => [(m.left + m.right) / 2, (m.top + m.bottom) / 2]).sort((a, b) => a[0] - b[0]);
  const line = front.slice(1).flatMap(([x, y], i) => {
    const [ax, ay] = front[i]; const n = Math.ceil(Math.hypot(x - ax, y - ay) / 4);
    return Array.from({ length: n }, (_, j) => { const cx = ax + (x - ax) * j / n; const cy = ay + (y - ay) * j / n; return { left: cx, right: cx, top: cy, bottom: cy }; });
  });
  const placed = [...line];
  const overlaps = (a, b) => a.left < b.right + 4 && a.right > b.left - 4 && a.top < b.bottom + 2 && a.bottom > b.top - 2;
  const tries = [0, -18, 18, -32, 32].flatMap((dy) => [['right', dy], ['left', dy]]);
  for (const label of labels) {
    const own = label.closest('.scatter-point');
    label.hidden = false;
    const fits = tries.some(([side, dy]) => {
      label.dataset.side = side;
      label.style.setProperty('--dy', dy + 'px');
      const r = label.getBoundingClientRect();
      return r.left >= box.left && r.right <= box.right && r.top >= box.top && r.bottom <= box.bottom
        && !placed.some((o) => overlaps(r, o)) && !marks.some(([p, m]) => p !== own && overlaps(r, m));
    });
    if (fits) placed.push(label.getBoundingClientRect());
    else label.hidden = true;
  }
}
function costScatter(rows, focus, lookOf, paretoOnly) {
  const points = rows.filter((r) => r.cost_per_task_usd > 0);
  if (points.length < 2 || !points.some((r) => !r.ours)) return null;
  const costs = points.map((r) => Math.log(r.cost_per_task_usd)); const scores = points.map((r) => r.score);
  const range = (v) => { const lo = Math.min(...v); const hi = Math.max(...v); const pad = (hi - lo || 1) * 0.1; return [lo - pad, hi + pad]; };
  const [x0, x1] = range(costs); const [y0, y1] = range(scores);
  const px = (r) => (Math.log(r.cost_per_task_usd) - x0) / (x1 - x0) * 100;
  const py = (r) => (r.score - y0) / (y1 - y0) * 100;
  const pubPoints = points.filter((r) => !r.ours);
  const frontier = pubPoints.filter((r) => !pubPoints.some((o) => o !== r && beats(o, r))).sort((p, q) => p.cost_per_task_usd - q.cost_per_task_usd);
  const ourByModel = new Map();
  for (const r of points.filter((x) => x.ours)) {
    const mk = modelKey(r.model) || '_';
    if (!ourByModel.has(mk)) ourByModel.set(mk, []);
    ourByModel.get(mk).push(r);
  }
  const trajectories = [...ourByModel.values()].filter((g) => g.length >= 2)
    .map((g) => [...g].sort((a, b) => String(a.ours.started_at || '').localeCompare(String(b.ours.started_at || '')) || a.score - b.score));
  const label = (r) => (r.ours ? rowName(r) : lookOf(r).name);
  const repeated = new Set(points.filter((r, i) => points.findIndex((o) => label(o) === label(r)) !== i).map(label));
  const name = (r) => (!r.ours && repeated.has(label(r)) ? `${r.harness} · ${r.model}` : label(r));
  const order = [...points].sort((p, q) => Boolean(q.ours) - Boolean(p.ours) || frontier.includes(q) - frontier.includes(p) || q.score - p.score);
  const layer = svg('svg', { class: 'scatter-layer', viewBox: '0 0 100 100', preserveAspectRatio: 'none', 'aria-hidden': 'true' },
    svg('polyline', { class: 'frontier', points: frontier.map((r) => `${px(r)},${100 - py(r)}`).join(' ') }),
    ...trajectories.map((g) => svg('polyline', { class: 'trajectory', points: g.map((r) => `${px(r)},${100 - py(r)}`).join(' ') })));
  const yTicks = niceTicks(y0, y1);
  const grid = [
    ...yTicks.ticks.map((v) => h('div', { class: 'grid-y', style: `bottom:${(v - y0) / (y1 - y0) * 100}%` },
      h('span', { text: v.toFixed(yTicks.step < 1 ? 1 : 0) + '%' }))),
    ...costTicks(Math.exp(x0), Math.exp(x1)).map((v) => h('div', { class: 'grid-x', style: `left:${(Math.log(v) - x0) / (x1 - x0) * 100}%` },
      h('span', { text: '$' + v.toFixed(v < 0.1 ? 3 : 2) }))),
  ];
  const tip = h('div', { class: 'scatter-tip', hidden: true });
  const dots = new Map(points.map((r) => [r, h('button', { type: 'button', class: 'scatter-point',
    'data-ours': r.ours ? '1' : null, 'data-frontier': frontier.includes(r) ? '1' : null,
    'data-nonfrontier': !r.ours && !frontier.includes(r) ? '1' : null,
    'data-order': order.indexOf(r),
    style: `left:${px(r)}%;bottom:${py(r)}%`,
    'aria-label': `${rowName(r)} · ${r.model || ''} · ${score(r.score)} · ${usd(r.cost_per_task_usd)}`,
    onmouseenter: () => focus.set(r), onmouseleave: () => focus.set(null), onfocus: () => focus.set(r), onblur: () => focus.set(null),
    onclick: r.ours ? () => { location.hash = ourEntryHref(r.ours); } : null },
  glyph(lookOf(r)),
  h('span', { class: 'scatter-label', style: 'color:' + lookOf(r).color },
    h('b', { text: name(r) }), h('small', { class: 'num', text: `${score(r.score)} · ${usd(r.cost_per_task_usd)}` })))]));
  const plot = h('div', { class: 'scatter-plot', 'data-pareto': paretoOnly ? '1' : null }, ...grid, layer, ...dots.values(), tip);
  focus.on((active) => {
    const a = dots.has(active) ? active : null;
    plot.toggleAttribute('data-active', Boolean(a));
    for (const [r, dot] of dots) {
      dot.toggleAttribute('data-current', r === a);
      dot.toggleAttribute('data-killed', Boolean(a && r !== a && beats(a, r)));
    }
    tip.hidden = !a;
    if (!a) return;
    tip.replaceChildren(h('b', { text: a.ours ? ourEntryLabel(a.ours) : a.harness }),
      h('span', { text: [a.ours?.profile_version ? 'v' + a.ours.profile_version : null, a.model || '—'].filter(Boolean).join(' · ') }),
      h('span', { class: 'num', text: `${score(a.score)} · ${usd(a.cost_per_task_usd)}` }));
    tip.style.left = px(a) + '%';
    tip.style.bottom = py(a) + '%';
    tip.dataset.side = px(a) > 60 ? 'left' : 'right';
  });
  const group = (look) => {
    plot.toggleAttribute('data-group', Boolean(look));
    for (const [r, dot] of dots) dot.toggleAttribute('data-dim', Boolean(look) && lookOf(r) !== look);
  };
  const legend = h('div', { class: 'scatter-legend' }, [...new Set(points.map(lookOf))].map((look) =>
    h('span', { class: 'key', onmouseenter: () => group(look), onmouseleave: () => group(null) }, glyph(look), look.name)));
  new ResizeObserver(() => arrangeLabels(plot)).observe(plot);
  return h('div', { class: 'scatter-box' }, legend, h('div', { class: 'scatter-frame' }, h('div', { class: 'axis-y', text: '分数' }), plot,
    h('div', { class: 'axis-x', text: '每题平均成本' })));
}
const BARS_TOP = 15;
function scoreScale(lows, highs, rowCount) {
  const top = Math.max(...highs);
  const lo = Math.min(...lows, Math.max(0, top - 5)); const hi = Math.max(top, lo + 5);
  const { step } = niceTicks(Math.max(0, lo - (hi - lo) * 0.15), Math.min(100, hi));
  const x1 = Math.min(100, Math.ceil(hi / step) * step);
  const floor = Math.floor(lo / step) * step;
  const x0 = floor < x1 * 0.25 ? 0 : Math.max(0, floor - step);
  const at = (v) => (Math.min(Math.max(v, x0), x1) - x0) / (x1 - x0) * 100;
  const marks = Array.from({ length: Math.round((x1 - x0) / step) + 1 }, (_, i) => +(x0 + i * step).toPrecision(12));
  const digits = step < 1 ? 1 : 0;
  const lines = h('div', { class: 'bars-grid', style: `grid-row:1 / span ${rowCount}` },
    marks.map((v) => h('i', { style: `left:${at(v)}%` })));
  const axis = h('div', { class: 'bars-axis', style: `grid-row:${rowCount + 1}` }, marks.map((v) => h('span', { style: `left:${at(v)}%`, text: v.toFixed(digits) + '%' })));
  return { at, lines, axis };
}
function scoreBars(rows, focus, lookOf) {
  const shown = rows.filter((r, i) => i < BARS_TOP || r.ours);
  if (shown.length < 2) return null;
  const err = (r) => r.stderr || 0;
  const { at, lines, axis } = scoreScale(shown.map((r) => r.score - err(r)), shown.map((r) => r.score + err(r)), shown.length);
  const name = (r) => (r.ours ? [ourEntryLabel(r.ours), r.model || r.ours.name] : [r.model || r.harness, null]);
  const items = new Map(shown.map((r, i) => [r, h('div', { class: 'bar-row', 'data-ours': r.ours ? '1' : null, style: `--row:${i + 1}`,
    onmouseenter: () => focus.set(r), onmouseleave: () => focus.set(null),
    onclick: r.ours ? () => { location.hash = ourEntryHref(r.ours); } : null },
  h('span', { class: 'bar-name', title: name(r).filter(Boolean).join(' · ') }, glyph(lookOf(r)),
    h('span', {}, name(r)[0], name(r)[1] ? h('small', { text: ' · ' + name(r)[1] }) : null)),
  h('span', { class: 'bar-track' }, h('i', { class: 'bar-fill', style: `width:${at(r.score)}%;background:${lookOf(r).color}` }),
    err(r) ? h('i', { class: 'bar-err', style: `left:${at(r.score - err(r))}%;width:${at(r.score + err(r)) - at(r.score - err(r))}%` }) : null),
  h('span', { class: 'bar-value num', text: score(r.score) + (err(r) ? ` ±${err(r).toFixed(1)}` : '') }))]));
  focus.on((active) => { for (const [r, el] of items) el.toggleAttribute('data-current', r === active); });
  const note = rows.length > shown.length ? h('div', { class: 'bars-note', text: `前 ${BARS_TOP} 名${shown.some((r) => r.ours) ? '及我们的评测' : ''} · 共 ${rows.length} 条，完整列表见下表` }) : null;
  return h('div', { class: 'scatter-box bars-box' }, h('div', { class: 'bars' }, lines, ...items.values(), axis), note);
}
function modelDots(rows, focus, lookOf) {
  const groups = new Map();
  for (const r of rows) {
    const key = modelKey(r.model) || r.id;
    if (!groups.has(key)) groups.set(key, { model: r.model || r.harness, rows: [] });
    groups.get(key).rows.push(r);
  }
  const all = [...groups.values()];
  const shown = all.filter((g, i) => i < BARS_TOP || g.rows.some((r) => r.ours));
  if (shown.length < 2) return null;
  const entries = shown.flatMap((g) => g.rows);
  const err = (r) => r.stderr || 0;
  const { at, lines, axis } = scoreScale(entries.map((r) => r.score - err(r)), entries.map((r) => r.score + err(r)), shown.length);
  const harnessOf = (r) => (r.ours ? ourEntryLabel(r.ours) : r.harness);
  const scoreText = (r) => score(r.score) + (err(r) ? ` ±${err(r).toFixed(1)}` : '');
  const ends = (r) => [scoreText(r), h('small', { text: ' ' + harnessOf(r) })];
  const dots = new Map();
  const rowNodes = shown.map((g, i) => {
    const best = g.rows[0]; const worst = g.rows[g.rows.length - 1];
    const whiskers = g.rows.filter(err).map((r) => h('i', { class: 'bar-err', style: `left:${at(r.score - err(r))}%;width:${at(r.score + err(r)) - at(r.score - err(r))}%` }));
    const marks = g.rows.map((r) => {
      const dot = h('button', { type: 'button', class: 'pair-dot', 'data-ours': r.ours ? '1' : null, style: `left:${at(r.score)}%`,
        title: `${harnessOf(r)} · ${scoreText(r)}`, 'aria-label': `${g.model} · ${harnessOf(r)} · ${scoreText(r)}`,
        onmouseenter: () => focus.set(r), onmouseleave: () => focus.set(null), onfocus: () => focus.set(r), onblur: () => focus.set(null),
        onclick: r.ours ? () => { location.hash = ourEntryHref(r.ours); } : null }, glyph(lookOf(r)));
      dots.set(r, dot);
      return dot;
    });
    return h('div', { class: 'bar-row', style: `--row:${i + 1}` },
      h('span', { class: 'bar-name', title: g.model }, h('span', { text: g.model })),
      h('span', { class: 'bar-track pair-track' },
        g.rows.length > 1 ? h('i', { class: 'pair-span', style: `left:${at(worst.score)}%;width:${at(best.score) - at(worst.score)}%` }) : null, ...whiskers, ...marks),
      h('span', { class: 'bar-value num', title: g.rows.map((r) => `${harnessOf(r)} ${scoreText(r)}`).join('\n') },
        ...(g.rows.length > 1 ? [...ends(worst), ' – ', ...ends(best)] : ends(best))));
  });
  const box = h('div', { class: 'bars pair-bars' }, lines, ...rowNodes, axis);
  focus.on((active) => { for (const [r, dot] of dots) dot.toggleAttribute('data-current', r === active); });
  const group = (look) => {
    box.toggleAttribute('data-group', Boolean(look));
    for (const [r, dot] of dots) dot.toggleAttribute('data-dim', Boolean(look) && lookOf(r) !== look);
  };
  const legend = h('div', { class: 'scatter-legend pair-legend' }, [...new Set([...dots.keys()].map(lookOf))].map((look) =>
    h('span', { class: 'key', onmouseenter: () => group(look), onmouseleave: () => group(null) }, glyph(look), look.name)));
  const note = all.length > shown.length ? h('div', { class: 'bars-note', text: `前 ${BARS_TOP} 个模型${shown.some((g) => g.rows.some((r) => r.ours)) ? '及我们的评测' : ''} · 共 ${all.length} 个模型、${rows.length} 条，完整列表见下表` }) : null;
  return h('div', { class: 'scatter-box bars-box' }, legend, box, note);
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
  const oursList = rows.filter((r) => r.ours);
  const ours = oursList[0];
  const extra = oursList.length > 1 ? ` · 共 ${oursList.length} 个版本入榜` : '';
  return h('section', { class: 'metrics leaders' },
    best ? metric('最高分', score(best.score), `${best.harness} · ${best.model || '—'}`) : null,
    cheapest ? metric('最低成本', usd(cheapest.cost_per_task_usd), `${cheapest.harness} · ${score(cheapest.score)}`) : null,
    metric('我的最佳 Profile', ours ? `${ours.rank} / ${published + oursList.length}` : '—',
      ours ? `${score(ours.score)} · ${ourEntryLabel(ours.ours)}${extra}` : '暂无达到覆盖门槛的评测', true));
}
const BOARD_TOP = 10;
function boardPanel(board, suiteId, selectedSet, ourColorMap, onChange = render) {
  const key = board.suites.join(',') + '|' + board.title;
  const models = boardModels(board);
  const model = models.includes(state.boardModel[key]) ? state.boardModel[key] : (board.default_model || models[0] || null);
  const { rows, published } = boardRows(board, model);
  const focus = focusHub();
  const harness = soleHarness(board);
  const lookOf = rowLooks(rows, Boolean(harness), ourColorMap);
  const harnessNote = harness ? h('div', { class: 'board-harness muted', text: `Harness：${harness}（本榜公开条目都用它，图中标识按模型/Profile 区分）` }) : null;
  const priced = rows.some((r) => r.cost_per_task_usd > 0);
  const src = board.source;
  const paretoOnly = Boolean(state.boardPareto[key]);
  const scatter = costScatter(rows, focus, lookOf, paretoOnly);
  const redraw = (e) => e.target.closest('.panel').replaceWith(boardPanel(board, suiteId, selectedSet, ourColorMap, onChange));
  const paretoToggle = scatter ? h('div', { class: 'board-pareto-toggle' },
    h('button', { type: 'button', class: 'chip', 'aria-pressed': String(!paretoOnly),
      onclick: (e) => { state.boardPareto[key] = false; redraw(e); } }, '全部公开 + 我的 Profile'),
    h('button', { type: 'button', class: 'chip', 'aria-pressed': String(paretoOnly),
      onclick: (e) => { state.boardPareto[key] = true; redraw(e); } }, '仅 Pareto 前沿 + 我的 Profile')) : null;
  const picker = models.length ? h('select', { class: 'board-model', 'aria-label': '模型', onchange: (e) => { state.boardModel[key] = e.target.value; redraw(e); } },
    models.map((m) => h('option', { value: m, selected: m === model, text: m === board.default_model ? '全部模型' : m }))) : null;
  const sourceLink = h('a', { class: 'board-link', href: src.url, target: '_blank', rel: 'noopener noreferrer', title: `${src.name} · ${src.retrieved}`, text: '来源 ↗' });
  const expanded = Boolean(state.boardExpanded[key]);
  const shown = expanded ? rows : rows.filter((r, i) => i < BOARD_TOP || r.ours);
  const top = Math.max(...rows.map((r) => r.score), 1);
  const ourRows = rows.filter((r) => r.ours);
  const showDelta = ourRows.length >= 2;
  const baselineScore = showDelta ? Math.min(...ourRows.map((r) => r.score)) : null;

  const rowNodes = new Map(shown.map((r) => {
    const col = r.ours ? lookOf(r).color : null;
    const checked = r.ours && selectedSet.has(r.ours.name);
    const chk = r.ours ? h('input', { type: 'checkbox', checked, 'aria-label': '对比 ' + ourEntryLabel(r.ours),
      style: `accent-color:${col};margin:0;cursor:pointer`,
      onclick: (e) => e.stopPropagation(),
      onchange: (e) => { if (e.target.checked) selectedSet.add(r.ours.name); else selectedSet.delete(r.ours.name); onChange(); } }) : null;
    const deltaText = !showDelta ? null : !r.ours ? dash() : (() => {
      const diff = r.score - baselineScore;
      return diff <= 0.05 ? h('span', { class: 'faint', text: '基线' })
        : h('span', { class: 'pos', text: `+${diff.toFixed(1)}%` });
    })();
    return [r, h('tr', { class: r.ours ? 'ours link' : null, title: r.ours ? r.ours.name : null,
      onmouseenter: () => focus.set(r), onmouseleave: () => focus.set(null),
      onclick: r.ours ? () => { location.hash = ourEntryHref(r.ours); } : null },
    h('td', { class: 'num rank', text: String(r.rank) }),
    h('td', {}, h('span', { class: 'harness' }, chk, harness && !r.ours ? null : glyph(lookOf(r)),
      r.ours ? h('span', {}, h('strong', { text: ourEntryLabel(r.ours) }),
        r.ours.profile_version ? h('span', { class: 'tag mono', style: `margin-left:6px;border-color:${col}66;color:${col}`, text: 'v' + r.ours.profile_version }) : null,
        r.ours.profile_features?.length ? h('span', { class: 'sub mono', text: r.ours.profile_features.join(', ') }) : null)
        : r.harness)),
    h('td', { class: 'muted' }, h('span', { class: 'harness' }, harness && !r.ours ? glyph(lookOf(r)) : null, r.model || '—')),
    h('td', {}, h('div', { class: 'score-cell' }, h('span', { class: 'score-bar' }, h('span', { style: `width:${Math.max(r.score / top * 100, 1)}%;background:${col || 'var(--control)'}` })),
      h('span', { class: 'num', text: score(r.score) }))),
    priced ? h('td', { class: 'num muted', text: usd(r.cost_per_task_usd) }) : null,
    showDelta ? h('td', { class: 'num mono' }, deltaText) : null)];
  }));
  focus.on((active) => { for (const [r, tr] of rowNodes) tr.classList.toggle('active', r === active); });
  const more = rows.length > shown.length || expanded ? h('button', { type: 'button', class: 'board-more',
    onclick: (e) => { state.boardExpanded[key] = !expanded; redraw(e); } }, expanded ? '收起' : `全部 ${rows.length} 条`) : null;
  const heads = ['#', 'Profile / Harness', '模型', '分数', priced ? '每题成本' : null, showDelta ? '较基线' : null].filter(Boolean);
  const table = h('div', { class: 'table-scroll' }, h('table', { class: 'board' },
    h('thead', {}, h('tr', {}, heads.map((t, i) => h('th', { class: [0, 4, 5].includes(i) ? 'num' : null, text: t })))),
    h('tbody', {}, [...rowNodes.values()])), more);
  return panel(board.title, null, h('div', { class: 'panel-body' }, leaderCards(rows, published), harnessNote, scatter || (harness ? scoreBars : modelDots)(rows, focus, lookOf), table),
    h('div', { class: 'board-actions' }, paretoToggle, picker, sourceLink));
}

async function renderLeaderboard(suiteId) {
  state.live = false;
  navCurrent('leaderboard');
  $('#title').textContent = '公开榜单';
  const d = await api('/api/leaderboard' + (suiteId ? '?suite=' + encodeURIComponent(suiteId) : ''));
  crumbs([{ text: 'Profiles', href: '#/' }, { text: '公开榜单' }, { text: d.suite_name }]);
  const suitePicker = h('label', { class: 'scope', style: 'padding:0' }, '评测集',
    h('select', { onchange: (e) => { location.hash = '#/leaderboard/' + encodeURIComponent(e.target.value); } },
      d.suites.map((s) => h('option', { value: s.suite, selected: s.suite === d.suite, text: s.suite_name }))));

  const rankedByJob = new Map();
  for (const board of d.boards) {
    for (const j of board.jobs) if (j.ranked && !rankedByJob.has(j.name)) rankedByJob.set(j.name, j);
  }
  const ourRanked = [...rankedByJob.values()].sort((a, b) => b.score - a.score);
  const ourColorMap = new Map(ourRanked.map((j, i) => [j.name, profileColor(i)]));
  if (!state.boardSelected[d.suite]) {
    const byModel = new Map();
    for (const j of ourRanked) {
      const mk = modelKey(j.model);
      if (!byModel.has(mk)) byModel.set(mk, []);
      byModel.get(mk).push(j);
    }
    const multi = [...byModel.values()].filter((g) => g.length >= 2).sort((a, b) => b.length - a.length)[0];
    state.boardSelected[d.suite] = new Set((multi || ourRanked).slice(0, 4).map((j) => j.name));
  }
  const selectedSet = state.boardSelected[d.suite];
  for (const name of [...selectedSet]) if (!rankedByJob.has(name)) selectedSet.delete(name);

  const baselineScore = ourRanked.length >= 2 ? Math.min(...ourRanked.map((j) => j.score * 100)) : null;
  const partial = d.unranked;
  const rest = partial.length ? panel('未参与排名的评测', `覆盖率低于 ${Math.round((d.ranked_coverage || 0.8) * 100)}%`, h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, ['Profile / 评测', '模型', '题数', '分数'].map((t, i) => h('th', { class: i > 1 ? 'num' : null, text: t })))),
    h('tbody', {}, partial.map((j) => h('tr', { class: 'link', onclick: () => { location.hash = ourEntryHref(j); } },
      h('td', {}, h('span', { text: j.profile_name || j.name }), j.profile_name ? h('span', { class: 'sub mono', text: j.name }) : null),
      h('td', { text: j.model || '—' }),
      h('td', { class: 'num', text: `${j.tasks} / ${d.task_count}` }), h('td', { class: 'num', text: pct(j.score, 1) }))))))) : null;
  const about = d.description ? h('p', { class: 'muted', style: 'font-size:12.5px', text: d.description }) : null;
  const topBar = h('div', { class: 'board-top-bar' }, about || h('span', {}), suitePicker);
  return localView((redraw) => {
    const pickedJobs = ourRanked.filter((j) => selectedSet.has(j.name));
    const myProfilesStrip = ourRanked.length ? h('section', { class: 'my-profiles-strip' },
      ...ourRanked.map((j) => {
        const col = ourColorMap.get(j.name);
        const checked = selectedSet.has(j.name);
        const sc = j.score * 100;
        const diff = baselineScore !== null ? sc - baselineScore : null;
        const diffNode = diff === null ? null : diff <= 0.05 ? h('span', { class: 'faint', text: '基线' })
          : h('span', { class: 'pos', text: `+${diff.toFixed(1)}%` });
        return h('div', { class: 'mp-card', style: `border-top:2px solid ${col}` },
          h('div', { class: 'mp-top' },
            h('label', { class: 'mp-name', style: 'cursor:pointer' },
              h('input', { type: 'checkbox', checked, style: `accent-color:${col};margin:0;cursor:pointer`,
                onchange: (e) => { if (e.target.checked) selectedSet.add(j.name); else selectedSet.delete(j.name); redraw(); } }),
              h('span', { style: `color:${col}`, text: '★' }),
              h('span', { text: ourEntryLabel(j), title: ourEntryLabel(j) })),
            j.profile_version ? h('span', { class: 'tag mono', text: 'v' + j.profile_version }) : null),
          h('div', { class: 'muted', style: 'font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap', text: j.model || j.name }),
          h('div', { class: 'mp-nums' },
            h('strong', { style: `color:${col}`, text: score(sc) }),
            h('span', { class: 'mono muted', style: 'font-size:11.5px' },
              j.cost_per_task !== null && j.cost_per_task !== undefined ? usd(j.cost_per_task) + (diffNode ? ' · ' : '') : '', diffNode)));
      }),
      ourRanked.length >= 2 ? h('div', { class: 'mp-cta' },
        h('strong', { class: 'acc', style: 'font-size:13px', text: `对比已选 ${pickedJobs.length} 个 Profile` }),
        h('span', { class: 'muted', style: 'font-size:11px', text: `${d.suite_name} · ${d.task_count} 题` }),
        pickedJobs.length >= 2
          ? h('a', { class: 'button primary sm', href: '#/compare/' + pickedJobs.map((j) => encodeURIComponent(j.name)).join(','), text: `进入 ${pickedJobs.length} 版本对比台 →` })
          : h('span', { class: 'muted', style: 'font-size:11px', text: '请至少勾选 2 个版本' })) : null) : null;
    return [topBar, myProfilesStrip, ...d.boards.map((b) => boardPanel(b, d.suite, selectedSet, ourColorMap, redraw)), rest];
  });
}

// ------------------------------------------------------------ settings (database)
async function renderSettings(tab) {
  state.live = false;
  navCurrent('settings');
  $('#title').textContent = '系统配置';
  const tabs = [['database', '数据库'], ['providers', '模型 Provider'], ['login', '账号登录']];
  const selected = tabs.find(([key]) => key === tab) || tabs[0];
  crumbs([{ text: '系统配置' }, { text: selected[1] }]);
  const nav = h('nav', { class: 'settings-tabs', 'aria-label': '系统配置' }, tabs.map(([key, label]) =>
    h('a', { href: '#/settings/' + key, 'aria-current': key === selected[0] ? 'page' : null }, label)));
  const page = selected[0] === 'login' ? await renderLogin() : selected[0] === 'providers' ? await renderProviders() : await renderDatabase();
  return h('div', {}, nav, page);
}

async function renderLogin() {
  const catalog = await api('/api/workbench');
  if (!catalog.can_run || !catalog.login?.available) return panel('Metask 登录', null, h('div', { class: 'panel-body' },
    catalog.can_run ? '当前工作台未启用 Metask 账号登录。' : '只读模式'));
  const login = await api('/api/login');
  state.live = login.running;
  const signedIn = catalog.login.signed_in || login.signed_in;
  const button = h('button', { class: 'button', disabled: login.running, onclick: async () => {
    button.disabled = true;
    try { await api('/api/login', {}); await render(); }
    catch (error) { button.disabled = false; setConnection(false, error.message); }
  } }, signedIn ? '重新登录' : '登录 Metask');
  return panel('Metask 登录', login.running ? '等待确认' : signedIn ? '已登录' : '未登录', h('div', { class: 'panel-body' },
    login.running && login.verification_uri ? h('p', {}, '打开 ', h('a', { href: login.verification_uri,
      target: '_blank', rel: 'noopener noreferrer', text: login.verification_uri }), ' 并输入代码 ', h('b', { text: login.user_code })) : null,
    login.running && !login.verification_uri ? '正在获取设备码…' : null, button));
}

async function renderDatabase() {
  state.live = false;
  const st = await api('/api/store');
  const db = st.database;
  const counts = st.counts || {};
  const current = panel('当前数据库', db.format, h('div', { class: 'panel-body' }, h('dl', { class: 'kv' },
    h('dt', { text: '类型' }), h('dd', { text: `${db.format}（schema v${db.schema_version}）` }),
    h('dt', { text: '位置' }), h('dd', { class: 'mono', text: db.location }),
    db.password_env ? h('dt', { text: '密码环境变量' }) : null, db.password_env ? h('dd', { class: 'mono', text: db.password_env }) : null,
    h('dt', { text: '内容' }), h('dd', { text: `Profile ${counts.profiles ?? 0} · 评测 ${counts.jobs ?? 0} · trial ${counts.trials ?? 0} · 请求 ${counts.requests ?? 0} · 文件 ${counts.files ?? 0} · 启动记录 ${counts.runs ?? 0}` }),
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
        result.textContent = body.exists ? `连接成功：${body.database.format} ${body.database.location}（schema v${body.database.schema_version}）${body.same ? ' · 就是当前数据库' : ''}\n已有：评测 ${body.counts.jobs} · trial ${body.counts.trials} · Profile ${body.counts.profiles ?? 0}` : `可用：${body.message}`;
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

// ------------------------------------------------------------ monitor
const MONITOR_POINTS = 120;
const DOCKER_USAGE = [['images', '镜像'], ['containers', '容器'], ['volumes', '数据卷'], ['build_cache', '构建缓存']];
function bytes(n) {
  if (n === null || n === undefined) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let value = n, unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
  return (unit && value < 100 ? value.toFixed(1) : Math.round(value)) + ' ' + units[unit];
}
function byteRate(n) { return n === null || n === undefined ? '—' : bytes(n) + '/s'; }
function hitText(rate, hits, total) { return rate === null || rate === undefined ? '暂无请求' : `${pct(rate)}（${int(hits)} / ${int(total)}）`; }
function sparkline(values, label, format, ceiling) {
  const points = values.filter((v) => v !== null && v !== undefined);
  if (points.length < 2) return h('div', { class: 'spark-empty', text: points.length ? '等待下一次采样' : '' });
  const lo = Math.min(...points), hi = Math.max(...points), top = Math.max(ceiling || 0, hi) || 1, w = 120, ht = 28;
  const path = points.map((v, i) => `${(i * w / (points.length - 1)).toFixed(1)},${(ht - 2 - Math.max(0, v) * (ht - 4) / top).toFixed(1)}`).join(' ');
  const text = `${label}：最近 ${points.length} 次采样，最低 ${format(lo)}，最高 ${format(hi)}，当前 ${format(points[points.length - 1])}`;
  return svg('svg', { class: 'spark', viewBox: `0 0 ${w} ${ht}`, role: 'img', 'aria-label': text, preserveAspectRatio: 'none' },
    svg('title', {}, text), svg('polyline', { points: path }));
}
function usageBar(used, total) {
  const share = total ? Math.min(1, used / total) : 0;
  return h('div', { class: 'stack-bar', role: 'img', 'aria-label': `已用 ${pct(share)}` },
    h('span', { class: share >= 0.9 ? 'm-warn' : 'm-used', width: (100 * share) + '%' }));
}
function probeState(probe) {
  if (!probe) return h('span', { class: 'muted', text: '未探测' });
  if (probe.ok) return h('span', { class: 'probe ok', text: `可达 · ${probe.seconds}s` + (probe.status ? ` · HTTP ${probe.status}` : '') });
  return h('span', { class: 'probe bad', text: '不可达' + (probe.error ? ` · ${probe.error}` : '') + (probe.seconds ? ` · ${probe.seconds}s` : '') });
}
function monitorTable(heads, rows, empty) {
  return h('div', { class: 'table-scroll' }, h('table', {},
    h('thead', {}, h('tr', {}, heads.map(([text, numeric]) => h('th', { class: numeric ? 'num' : null, text })))),
    h('tbody', {}, rows.length ? rows : h('tr', {}, h('td', { colspan: heads.length, class: 'empty', text: empty })))));
}
function cacheState(cache, setup) {
  if (cache.error) return h('span', { class: 'probe bad', text: '读取失败：' + cache.error });
  if (cache.answering) return h('span', { class: 'probe ok', text: '运行中' });
  if (cache.configured) return h('span', { class: 'probe bad', text: '已配置，但没有响应（' + setup + '）' });
  return h('span', { class: 'muted', text: '未启用' });
}
function monitorHistory(m) {
  const all = state.monitorHistory || (state.monitorHistory = {});
  const series = all[m.executor.name] || (all[m.executor.name] = []);
  if (m.error || (series.length && series[series.length - 1].at === m.collected_at)) return series;
  const load = m.load || {}, memory = load.memory || {};
  const wire = (m.network.interfaces || []).filter((i) => i.physical);
  const sum = (key) => wire.length && wire.every((i) => i[key] !== null) ? wire.reduce((acc, i) => acc + i[key], 0) : null;
  series.push({ at: m.collected_at, cpu: load.cpu_busy_percent ?? null, load: load.average ? load.average[0] : null,
    memory: memory.total && memory.available !== null && memory.available !== undefined ? 100 * (1 - memory.available / memory.total) : null,
    rx: sum('rx_rate'), tx: sum('tx_rate') });
  if (series.length > MONITOR_POINTS) series.splice(0, series.length - MONITOR_POINTS);
  return series;
}
function loadPanel(m, series) {
  const load = m.load || {}, memory = load.memory || {}, last = series[series.length - 1] || {};
  const percent = (v) => v.toFixed(1) + '%';
  const cards = h('div', { class: 'metrics' },
    metric('CPU 占用', load.cpu_busy_percent === null || load.cpu_busy_percent === undefined ? '—' : percent(load.cpu_busy_percent), `${load.cpus ?? '—'} 核 · 采样 1 秒 · 曲线满刻度 100%`, true,
      sparkline(series.map((p) => p.cpu), 'CPU 占用', percent, 100)),
    metric('负载（1 分钟）', load.average ? load.average[0].toFixed(2) : '—', load.average ? `5 分钟 ${load.average[1].toFixed(2)} · 15 分钟 ${load.average[2].toFixed(2)} · 曲线满刻度 = 核数` : null, false,
      sparkline(series.map((p) => p.load), '1 分钟负载', (v) => v.toFixed(2), load.cpus)),
    metric('内存已用', last.memory === null || last.memory === undefined ? '—' : percent(last.memory), memory.total ? `可用 ${bytes(memory.available)} / 共 ${bytes(memory.total)}` : null, false,
      sparkline(series.map((p) => p.memory), '内存已用', percent, 100)),
    metric('交换分区已用', memory.swap_total ? bytes(memory.swap_total - memory.swap_free) : '—', memory.swap_total ? `共 ${bytes(memory.swap_total)}` : null),
    metric('已运行', dur(load.uptime_seconds)));
  const disks = monitorTable([['路径'], ['已用', true], ['可用', true], ['总量', true], ['占用']],
    (m.disks || []).map((d) => h('tr', {}, h('td', { class: 'mono wrap', text: d.paths.join('\n') }), h('td', { class: 'num', text: bytes(d.used) }),
      h('td', { class: 'num', text: bytes(d.free) }), h('td', { class: 'num', text: bytes(d.total) }), h('td', {}, usageBar(d.used, d.total)))), '没有读到磁盘信息');
  return panel('机器负载', [m.host, m.os].filter(Boolean).join(' · '), h('div', {}, h('div', { class: 'panel-body' }, cards), disks));
}
function networkPanel(m, series) {
  const all = m.network.interfaces || [];
  const wire = all.filter((i) => i.physical), virtual = all.filter((i) => !i.physical);
  const last = series[series.length - 1] || {};
  const cards = h('div', { class: 'metrics' },
    metric('下行', byteRate(last.rx ?? null), '物理网卡合计', true, sparkline(series.map((p) => p.rx), '下行速率', byteRate)),
    metric('上行', byteRate(last.tx ?? null), '物理网卡合计', false, sparkline(series.map((p) => p.tx), '上行速率', byteRate)));
  const row = (i) => h('tr', {}, h('td', { class: 'mono', text: i.name }), h('td', { class: 'num', text: byteRate(i.rx_rate) }), h('td', { class: 'num', text: byteRate(i.tx_rate) }),
    h('td', { class: 'num', text: bytes(i.rx_bytes) }), h('td', { class: 'num', text: bytes(i.tx_bytes) }));
  const heads = [['网卡'], ['下行', true], ['上行', true], ['累计接收', true], ['累计发送', true]];
  const targets = monitorTable([['源站'], ['探测地址'], ['状态']],
    (m.network.targets || []).filter((t) => !t.setting).map((t) => h('tr', {}, h('td', { text: t.label }), h('td', { class: 'mono', text: t.url }), h('td', {}, probeState(t.probe)))), '没有可探测的地址');
  return panel('网络', m.network.targets_checked_at ? `源站和镜像源的连通性每分钟探测一次 · 上次 ${when(m.network.targets_checked_at)}` : null, h('div', {},
    h('div', { class: 'panel-body' }, cards),
    monitorTable(heads, wire.map(row), all.length ? '没有物理网卡' : '这台机器没有 /proc/net/dev（非 Linux）'),
    virtual.length ? h('details', { class: 'reason monitor-more', 'data-key': 'monitor-virtual' }, h('summary', { text: `Docker 网桥和容器网卡 ${virtual.length} 个` }), monitorTable(heads, virtual.map(row), '')) : null,
    targets));
}
const MIRROR_EFFECTS = { next_run: '下一次评测开始生效', next_setup: '下次一键配置安装 Harbor 时使用', setup: '重新配置后生效' };
const MIRROR_HINTS = { url: 'http(s):// 地址，留空表示不用', urls: '多个地址用空格分开，留空表示不用', host: '镜像仓库主机名，如 ghcr.nju.edu.cn' };
function mirrorText(row) { return row.kind === 'urls' ? (row.value || []).join(' ') : row.value || ''; }
function mirrorEffect(row) {
  if (row.setting === 'docker_mirrors') return MIRROR_EFFECTS.setup + '（写入 Docker daemon 并 reload，只追加不删除）';
  if (row.cached) return MIRROR_EFFECTS.next_run + '；下载缓存' + MIRROR_EFFECTS.setup + '，此前这一类直接走镜像源';
  return MIRROR_EFFECTS[row.effect] || '';
}
function mirrorChanges(rows, values, saved) {
  return Object.fromEntries(rows.filter((r) => values[r.setting] !== saved[r.setting]).map((r) => [r.setting, values[r.setting]]));
}
function mirrorDraftLeft(draft, submitted) {
  return Object.fromEntries(Object.entries(draft || {}).filter(([key, value]) => submitted[key] !== value));
}
function mirrorPayload(rows, changes) {
  const settings = {};
  for (const row of rows) {
    if (!(row.setting in changes)) continue;
    const value = changes[row.setting];
    if (row.setting.startsWith('container_mirrors.')) {
      settings.container_mirrors = settings.container_mirrors || {};
      settings.container_mirrors[row.setting.slice('container_mirrors.'.length)] = value || null;
    } else if (row.kind === 'urls') settings[row.setting] = value.split(/[\s,]+/).filter(Boolean);
    else settings[row.setting] = row.kind === 'bool' ? value : value || null;
  }
  return settings;
}
function mirrorsPanel(m) {
  const name = m.executor.name;
  const rows = m.mirrors.settings || [];
  const daemon = (m.docker && m.docker.registry_mirrors) || [];
  const egress = typeof m.mirrors.egress === 'string' ? ({ direct: '直连（执行机器自己的网络）', workbench: '经工作台出网' }[m.mirrors.egress] || m.mirrors.egress) : '站点代理 ' + (m.mirrors.egress.proxy || '');
  const facts = h('div', { class: 'panel-body' }, h('dl', { class: 'kv' },
    h('dt', { text: '容器出网' }), h('dd', { text: egress }),
    h('dt', { text: 'Docker daemon 的 registry-mirrors' }), h('dd', { class: 'mono', text: m.error ? '未探测' : daemon.length ? daemon.join('\n') : '未配置（Docker Hub 直连）' })));
  if (!m.mirrors.editable) return panel('镜像源', '镜像源只在 SSH 执行机器上配置', h('div', {}, facts));
  const saved = Object.fromEntries(rows.map((r) => [r.setting, r.kind === 'bool' ? !!r.value : mirrorText(r)]));
  const drafts = state.mirrorDrafts || (state.mirrorDrafts = {});
  const notes = state.mirrorNotes || (state.mirrorNotes = {});
  const values = { ...saved, ...(drafts[name] || {}) };
  const feedback = h('span', { class: 'muted', role: 'status', text: notes[name] || '' });
  const save = h('button', { type: 'submit', class: 'button primary', text: '保存' });
  const undo = h('button', { type: 'button', class: 'button', text: '还原' });
  const sync = () => {
    const changes = mirrorChanges(rows, values, saved);
    const dirty = Object.keys(changes).length > 0;
    save.disabled = !dirty;
    undo.disabled = !dirty;
    state.editing = dirty;
    if (dirty) drafts[name] = changes; else delete drafts[name];
  };
  const edited = () => { delete notes[name]; feedback.textContent = ''; sync(); };
  const field = (r) => {
    if (r.kind === 'bool') {
      const box = h('input', { type: 'checkbox', 'aria-label': r.label });
      box.checked = values[r.setting];
      box.addEventListener('change', () => { values[r.setting] = box.checked; edited(); });
      return h('label', { class: 'check' }, box, '开启');
    }
    const input = h('input', { type: 'text', class: 'mirror-input mono', value: values[r.setting], placeholder: MIRROR_HINTS[r.kind],
      'aria-label': r.setting, spellcheck: 'false', autocomplete: 'off' });
    input.addEventListener('input', () => { values[r.setting] = input.value.trim(); edited(); });
    return input;
  };
  const status = (r) => {
    const probes = (r.probes || []).filter(Boolean);
    const parts = probes.map((probe) => h('div', {}, probeState(probe)));
    if (r.pending) parts.push(h('div', { class: 'flag', text: '需要重新配置：' + r.pending }));
    if (!parts.length) return h('span', { class: 'muted', text: r.kind === 'bool' ? (r.value ? '已开启' : '未开启') : mirrorText(r) ? '未探测' : '未配置' });
    return parts;
  };
  const table = monitorTable([['范围'], ['类型'], ['配置项'], ['地址'], ['生效'], ['状态']],
    rows.map((r) => h('tr', {}, h('td', { text: r.scope }), h('td', { text: r.label }), h('td', { class: 'mono', text: r.setting }),
      h('td', {}, field(r)), h('td', { class: 'muted', text: mirrorEffect(r) }), h('td', {}, status(r)))), '没有可配置的镜像源');
  const form = h('form', { class: 'mirror-form' }, table, h('div', { class: 'panel-body mirror-actions' }, save, undo, feedback));
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const controls = [...form.querySelectorAll('input, button')];
    for (const control of controls) control.disabled = true;
    feedback.textContent = '正在保存并探测新地址…';
    const submitted = mirrorChanges(rows, values, saved);
    try {
      await api('/api/monitor/mirrors', { executor: name, settings: mirrorPayload(rows, submitted) });
      const left = mirrorDraftLeft(drafts[name], submitted);
      if (Object.keys(left).length) drafts[name] = left; else delete drafts[name];
      notes[name] = '已保存到 workbench.json（保存前的版本在 backups/ 里）';
      if (form.isConnected) { state.editing = false; render(); }
    } catch (error) {
      notes[name] = '没有保存：' + error.message;
      if (!form.isConnected) return;
      for (const control of controls) control.disabled = false;
      sync();
      feedback.textContent = notes[name];
    }
  });
  undo.addEventListener('click', () => { delete drafts[name]; delete notes[name]; state.editing = false; render(); });
  const pending = m.mirrors.pending || [];
  const blocked = m.setup_running ? '一键配置正在进行' : m.busy ? '有评测在运行，结束后才能重新配置' : '';
  const rerun = h('button', { type: 'button', class: 'button', text: '重新配置', disabled: !!blocked });
  const rerunNote = h('span', { class: 'muted', role: 'status', text: blocked });
  rerun.addEventListener('click', async () => {
    rerun.disabled = true;
    try {
      await api('/api/setup', { executor: name, dry_run: false });
      state.executor = name;
      state.setupWatch = true;
      openRunDialog();
    } catch (error) { rerunNote.textContent = error.message; rerun.disabled = false; }
  });
  const todo = pending.length ? h('div', { class: 'panel-body' }, h('div', { class: 'callout mirror-pending' },
    h('div', { text: '需要重新配置才生效：' + pending.map((x) => `${x.title}（${x.reason}）`).join('；') }),
    h('div', { class: 'mirror-actions' }, rerun, rerunNote))) : null;
  const note = m.error ? '执行机器没有连上，状态未探测；设置仍可修改' : '在这里修改，保存到 workbench.json 的执行机器条目；正在运行的评测不受影响';
  const node = panel('镜像源', note, h('div', {}, facts, form, todo));
  sync();
  return node;
}
function dockerPanel(m) {
  const d = m.docker || {};
  if (d.error) return panel('Docker', null, h('div', { class: 'empty', text: '读取失败：' + d.error }));
  const usage = d.usage || {};
  return panel('Docker', `${d.version} · ${d.driver || '—'}` + (d.usage_checked_at ? ` · 占用每 10 分钟统计一次，上次 ${when(d.usage_checked_at)}` : ''), h('div', {},
    h('div', { class: 'panel-body' }, h('dl', { class: 'kv' },
      h('dt', { text: '数据目录' }), h('dd', { class: 'mono', text: d.root || '—' }),
      h('dt', { text: '容器' }), h('dd', { text: `运行中 ${d.containers_running ?? '—'} · 共 ${d.containers_total ?? '—'}` }),
      d.usage_error ? h('dt', { text: '占用统计' }) : null, d.usage_error ? h('dd', { class: 'flag', text: '读取失败：' + d.usage_error }) : null)),
    monitorTable([['类型'], ['数量', true], ['使用中', true], ['占用', true], ['可回收', true]],
      DOCKER_USAGE.filter(([k]) => usage[k]).map(([k, label]) => h('tr', {}, h('td', { text: label }), h('td', { class: 'num', text: int(usage[k].count) }), h('td', { class: 'num', text: int(usage[k].active) }),
        h('td', { class: 'num', text: bytes(usage[k].bytes) }), h('td', { class: 'num', text: bytes(usage[k].reclaimable_bytes) }))), '没有读到占用统计')));
}
function cachesPanel(m) {
  const { apt = {}, download = {}, images = {} } = m.caches || {};
  const setup = `运行 metacodes bench setup --executor ${m.executor.name}`;
  const aptBody = apt.answering ? h('dl', { class: 'kv' },
    h('dt', { text: '命中率' }), h('dd', { text: hitText(apt.hit_rate, apt.hits, apt.requests) + (apt.log_truncated ? '（只统计了日志的最后 64 MiB）' : '') }),
    h('dt', { text: '未命中（回源）' }), h('dd', { text: `${int(apt.misses)} 次 · 错误 ${int(apt.errors)} 次` }),
    h('dt', { text: '流量' }), h('dd', { text: `提供 ${bytes(apt.bytes_served)} · 回源下载 ${bytes(apt.bytes_fetched)}` }),
    h('dt', { text: '回源地址' }), h('dd', { class: 'mono', text: apt.upstream || '各软件源自己的地址' })) : null;
  const routes = Object.entries(download.routes || {});
  const totals = download.totals || {};
  const downloadBody = download.answering ? h('div', {}, h('dl', { class: 'kv' },
    h('dt', { text: '命中率' }), h('dd', { text: hitText(totals.hit_rate, totals.hits, totals.requests) }),
    h('dt', { text: '流量' }), h('dd', { text: `缓存提供 ${bytes(totals.bytes_cached)} · 回源下载 ${bytes(totals.bytes_fetched)}` }),
    h('dt', { text: '占用' }), h('dd', { text: `${int(download.entries)} 个文件 · ${bytes(download.disk_bytes)}` + (download.started_at ? ` · 启动于 ${when(download.started_at)}` : '') })),
    monitorTable([['类型'], ['回源地址'], ['请求', true], ['命中率', true], ['未命中', true], ['过期仍提供', true], ['错误', true], ['缓存提供', true], ['回源下载', true]],
      routes.map(([kind, r]) => h('tr', {}, h('td', { text: kind }), h('td', { class: 'mono', text: r.upstream || '—' }), h('td', { class: 'num', text: int(r.requests) }), h('td', { class: 'num', text: r.hit_rate === null ? '—' : pct(r.hit_rate) }),
        h('td', { class: 'num', text: int(r.misses) }), h('td', { class: 'num', text: int(r.stale) }), h('td', { class: 'num', text: int(r.errors) }), h('td', { class: 'num', text: bytes(r.bytes_cached) }), h('td', { class: 'num', text: bytes(r.bytes_fetched) }))), '还没有请求')) : null;
  const prepared = (images.hits || 0) + (images.misses || 0) + (images.failed || 0);
  const imagesBody = images.error ? h('span', { class: 'probe bad', text: '读取失败：' + images.error }) : !images.trials ? h('span', { class: 'muted', text: '暂无数据（还没有评测记录题目的准备过程）' }) : h('dl', { class: 'kv' },
    h('dt', { text: '命中率' }), h('dd', { text: prepared ? hitText(images.hit_rate, images.hits, (images.hits || 0) + (images.misses || 0)) : '暂无镜像准备记录' }),
    h('dt', { text: '未命中' }), h('dd', { text: `拉取 ${int(images.pulled)} 个（${dur(images.pull_seconds)}） · 构建 ${int(images.built)} 个（${dur(images.build_seconds)}） · 失败 ${int(images.failed)} 个` }),
    h('dt', { text: '现在' }), h('dd', { text: `排队 ${int(images.queued)} · 准备中 ${int(images.preparing)}（含已排到、占着名额继续准备的） · 已就绪等待 ${int(images.ready)} · 准备失败等待 ${int(images.unprepared || 0)}` }),
    h('dt', { text: '统计范围' }), h('dd', { text: `最近 ${int(images.trials)} 次 trial 的准备记录` }));
  const block = (title, note, stateNode, body) => h('div', { class: 'cache-block' }, h('h3', {}, title, h('small', { text: note })), stateNode, body);
  return panel('缓存', '先查缓存，未命中才回源', h('div', { class: 'panel-body cache-blocks' },
    block('apt 缓存', '任务容器里的 apt-get，apt-cacher-ng', cacheState(apt, setup), aptBody),
    block('下载缓存', 'pip / uv / npm / go / conda / rustup / GitHub Releases', cacheState(download, setup), downloadBody),
    block('镜像', 'Docker 本地镜像库：已有就不拉取', null, imagesBody)));
}
async function renderMonitor(name) {
  state.live = true;
  navCurrent('monitor');
  $('#title').textContent = '监控';
  crumbs([{ text: 'Profiles', href: '#/' }, { text: '执行机器的负载、网络、镜像源、Docker 和缓存' }]);
  let m;
  try { m = await api('/api/monitor' + (name ? '?executor=' + encodeURIComponent(name) : '')); } catch (e) {
    return h('div', { class: 'empty', text: e.message || '只读模式' });
  }
  const picker = h('select', { 'aria-label': '执行机器', onchange: (e) => { location.hash = '#/monitor/' + encodeURIComponent(e.target.value); } },
    (m.executors || []).map((e) => { const o = h('option', { value: e.name, text: e.label }); o.selected = e.name === m.executor.name; return o; }));
  const scope = h('div', { class: 'scope' }, h('span', { text: '执行机器' }), picker,
    m.collected_at ? h('span', { class: 'meta', text: '采集于 ' + new Date(m.collected_at).toLocaleTimeString('zh-CN', { hour12: false }) }) : null);
  if (m.error) return h('div', { class: 'stack monitor' }, scope, h('div', { class: 'callout', text: `无法采集 ${m.executor.label}：${m.error}` }),
    m.mirrors ? mirrorsPanel(m) : null);
  const series = monitorHistory(m);
  return h('div', { class: 'stack monitor' }, scope, loadPanel(m, series), networkPanel(m, series), mirrorsPanel(m), dockerPanel(m), cachesPanel(m));
}

// ------------------------------------------------------------ refresh loop
function tick() {
  const label = $('#countdown');
  if (document.querySelector('.run-dialog[open]') || state.editing) { label.textContent = '编辑中'; return; }
  if (!state.auto || !state.live) { label.textContent = state.live ? '已暂停' : '无运行中'; return; }
  state.countdown -= 1;
  label.textContent = state.countdown + 's';
  if (state.countdown <= 0) { state.countdown = REFRESH_S; render(); }
}
document.addEventListener('DOMContentLoaded', () => {
  $('#create-run').addEventListener('click', openRunDialog);
  $('#refresh').addEventListener('click', () => { state.countdown = REFRESH_S; render(); });
  $('#auto').addEventListener('click', (e) => { state.auto = !state.auto; e.currentTarget.setAttribute('aria-pressed', String(state.auto)); tick(); });
  window.addEventListener('hashchange', (event) => {
    const dialog = document.querySelector('.run-dialog[open]');
    if (dialog && dialog.ariaBusy !== 'true') {
      if (new URL(event.newURL).hash.startsWith('#/settings/')) {
        state.savedRun = { url: event.oldURL, runDraft: state.runDraft, taskWanted: state.taskWanted,
          suitePick: state.suitePick, pickBundle: state.pickBundle, executor: state.executor };
      }
      clearRunDraft();
      dialog.close('navigation');
    }
    if (!dialog && state.savedRun?.url === event.newURL) {
      const { url, ...draft } = state.savedRun;
      state.savedRun = null;
      Object.assign(state, draft);
      openRunDialog();
    }
    state.countdown = REFRESH_S;
    window.scrollTo(0, 0);
    render();
  });
  render();
  state.timer = setInterval(tick, 1000);
});

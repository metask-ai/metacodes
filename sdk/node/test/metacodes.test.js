'use strict';
// End-to-end tests of the Node package against the real AgentCore library and
// the addon in prebuilds/. Without them the suite skips, unless
// METACODES_NODE_SDK_REQUIRE_LIB=1, which CI sets so a missing build fails.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const metacodes = require('..');
const { startMockProvider } = require('./mock_provider');

const addon = path.join(__dirname, '..', 'prebuilds', `${process.platform}-${process.arch}`, 'metacodes.node');
const available = fs.existsSync(addon) && metacodes.candidateLibraryPaths().some((candidate) => fs.existsSync(candidate));
const skip = !available && process.env.METACODES_NODE_SDK_REQUIRE_LIB !== '1'
  ? 'addon or AgentCore library not built; see README.md'
  : false;

function workspace(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'metacodes-node-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

async function withProvider(t, script) {
  const provider = await startMockProvider(script);
  t.after(() => provider.close());
  return provider;
}

function open(t, runtimeOptions, provider, root, sessionOptions = {}) {
  const runtime = new metacodes.Runtime(runtimeOptions);
  t.after(() => runtime.close());
  const session = runtime.session('mock-model', {
    baseUrl: provider.baseUrl, apiKey: 'test-key', workspace: root, ...sessionOptions,
  });
  return { runtime, session };
}

test('a text run returns the final answer, events and usage', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'hello from the mock']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  const result = await session.run('say hello', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  assert.equal(result.text, 'hello from the mock');
  assert.equal(result.stopReason, 'end_turn');
  assert.equal(result.turns, 1);
  assert.equal(result.usage.input_tokens, 11);
  assert.ok(tags.includes('text_chunk'));
  assert.ok(tags.includes('output_segment_end'));
  assert.match(JSON.stringify(provider.requests[0].messages), /say hello/);
});

test('a model failure reaches the result and a later success clears it', { skip }, async (t) => {
  const provider = await withProvider(t, [
    ['status', 402, { 'x-request-id': 'req-node-1' }, { error: { code: 'insufficient_balance', message: 'Balance too low' } }],
    ['text', 'fine now'],
  ]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  const failed = await session.run('fails', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  assert.equal(failed.stopReason, 'api_error');
  assert.equal(failed.modelError.category, 'payment_required');
  assert.equal(failed.modelError.code, 'insufficient_balance');
  assert.equal(failed.modelError.message, 'Balance too low');
  assert.equal(failed.modelError.http_status, 402);
  assert.equal(failed.modelError.request_id, 'req-node-1');
  assert.equal(failed.modelError.retry, 'not_retryable');
  assert.equal(tags.filter((tag) => tag === 'model_error').length, 1);
  assert.equal(tags[tags.length - 1], 'run_state');
  const recovered = await session.run('succeeds');
  assert.equal(recovered.stopReason, 'end_turn');
  assert.equal(recovered.modelError, null);
});

test('every event of a Run arrives before its Promise settles', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'ordered']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  await session.run('go', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  const last = tags.at(-1);
  assert.equal(last, 'run_state');
});

test('an async JavaScript tool result reaches the model', { skip }, async (t) => {
  const calls = [];
  const add = metacodes.tool({
    name: 'add',
    description: 'Add two integers.',
    inputSchema: { type: 'object', properties: { a: { type: 'integer' }, b: { type: 'integer' } }, required: ['a', 'b'] },
    handler: async ({ a, b }) => {
      calls.push([a, b]);
      await new Promise((resolve) => setTimeout(resolve, 10));
      return String(a + b);
    },
  });
  const provider = await withProvider(t, [['tool', 'add', { a: 2, b: 3 }], ['echo']]);
  const { session } = open(t, { tools: [], hostTools: [add] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('add 2 and 3');
  assert.deepEqual(calls, [[2, 3]]);
  assert.equal(result.text, 'saw: 5');
  assert.equal(result.toolCalls, 1);
  assert.ok(provider.requests[0].tools.some((advertised) => advertised.name === 'add'));
});

test('a throwing tool becomes a model-visible error', { skip }, async (t) => {
  const broken = metacodes.tool({ name: 'broken', handler: () => { throw new Error('disk on fire'); } });
  const provider = await withProvider(t, [['tool', 'broken', {}], ['echo']]);
  const { session } = open(t, { tools: [], hostTools: [broken] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('try it');
  assert.match(result.text, /disk on fire/);
  assert.equal(result.stopReason, 'end_turn');
});

test('the built-in Read tool reads the workspace', { skip }, async (t) => {
  const root = workspace(t);
  fs.writeFileSync(path.join(root, 'notes.txt'), 'the secret is 42\n');
  const provider = await withProvider(t, [['tool', 'Read', { file_path: 'notes.txt' }], ['echo']]);
  const { session } = open(t, { tools: ['Read'] }, provider, root);
  const result = await session.run('read notes.txt');
  assert.match(result.text, /the secret is 42/);
});

test('Runtime points RG_BIN at the ripgrep staged beside the library', { skip }, (t) => {
  const saved = process.env.RG_BIN;
  delete process.env.RG_BIN;
  t.after(() => { if (saved === undefined) delete process.env.RG_BIN; else process.env.RG_BIN = saved; });
  const runtime = new metacodes.Runtime({ tools: ['Grep'] });
  t.after(() => runtime.close());
  const staged = path.join(__dirname, '..', 'prebuilds', `${process.platform}-${process.arch}`, 'rg');
  if (!fs.existsSync(staged)) return t.skip('no ripgrep staged');
  assert.ok(process.env.RG_BIN && fs.realpathSync(process.env.RG_BIN) === fs.realpathSync(staged));
});

test('a permission request reaches the handler and a deny holds', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const requests = [];
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'x' }], ['echo']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: (request) => { requests.push(request); return request.denyOnce(); },
  });
  const result = await session.run('write a file');
  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'permission');
  assert.equal(requests[0].data.tool.name, 'Write');
  assert.equal(fs.existsSync(target), false);
  assert.equal(result.stopReason, 'end_turn');
});

test('an async allow lets the write happen', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'written' }], ['text', 'done']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: async (request) => request.allowOnce(),
  });
  const result = await session.run('write a file');
  assert.equal(fs.readFileSync(target, 'utf8'), 'written');
  assert.equal(result.text, 'done');
});

test('without a handler the write is not allowed', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'x' }], ['text', 'ok']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root);
  await session.run('write a file');
  assert.equal(fs.existsSync(target), false);
});

test('stream yields events and then the result', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'streamed']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const stream = session.stream('go');
  const tags = [];
  for await (const event of stream) tags.push(Object.keys(event)[0]);
  assert.ok(tags.includes('text_chunk'));
  assert.equal((await stream.result).text, 'streamed');
});

test('a throwing listener rejects the Run and the session survives', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'answer'], ['text', 'answer']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  await assert.rejects(session.run('one', { onEvent: () => { throw new TypeError('listener bug'); } }), /listener bug/);
  const result = await session.run('two');
  assert.equal(result.text, 'answer');
});

test('a second concurrent run on one session is refused', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'first'], ['text', 'second']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const first = session.run('one');
  await assert.rejects(session.run('two'), /already active/);
  assert.equal((await first).text, 'first');
});

test('two sessions run concurrently', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'same'], ['text', 'same']]);
  const runtime = new metacodes.Runtime({ tools: [] });
  t.after(() => runtime.close());
  const root = workspace(t);
  const options = { baseUrl: provider.baseUrl, apiKey: 'test-key', workspace: root };
  const [a, b] = await Promise.all([
    runtime.session('mock-model', options).run('a'),
    runtime.session('mock-model', options).run('b'),
  ]);
  assert.equal(a.text, 'same');
  assert.equal(b.text, 'same');
});

test('a shell tool requires a shell policy', { skip }, async (t) => {
  const provider = await withProvider(t, []);
  const runtime = new metacodes.Runtime({ tools: ['Bash'] });
  t.after(() => runtime.close());
  assert.throws(
    () => runtime.session('mock-model', { baseUrl: provider.baseUrl, apiKey: 'k', workspace: workspace(t), tools: ['Bash'] }),
    (error) => error.code === 'INVALID_ARGUMENT',
  );
});

test('describe and setModel', { skip }, async (t) => {
  const provider = await withProvider(t, []);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  assert.match(JSON.stringify(session.describe()), /mock-model/);
  session.setModel('mock-model-2');
  assert.match(JSON.stringify(session.describe()), /mock-model-2/);
});

test('unknown built-in tools are rejected', { skip }, () => {
  assert.throws(() => new metacodes.Runtime({ tools: ['Telepathy'] }), /unknown built-in tools/);
});

// A regression of the tests below hangs instead of failing (AgentCore waits
// for a call that never completes), so each carries a timeout.
const TIMEOUT = 30_000;

// -- results a handler cannot serialize ------------------------------------

test('a tool result JSON.stringify throws on is a model-visible error, not a crash', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'big', {}], ['echo']]);
  const big = metacodes.tool({ name: 'big', description: 'Returns a BigInt.', handler: () => ({ n: 1n }) });
  const { session } = open(t, { tools: [], hostTools: [big] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('go');
  assert.match(result.text, /TypeError/);
  assert.equal(result.stopReason, 'end_turn');
});

test('a tool result JSON.stringify drops is a model-visible error', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'fn', {}], ['echo']]);
  const fn = metacodes.tool({ name: 'fn', description: 'Returns a function.', handler: () => () => 1 });
  const { session } = open(t, { tools: [], hostTools: [fn] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('go');
  assert.match(result.text, /fn result is not JSON-serializable/);
});

test('a UI answer JSON.stringify throws on rejects the Run and the session survives', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [
    ['tool', 'Write', { file_path: target, content: 'x' }], ['text', 'unused'], ['text', 'second'],
  ]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, { onUiRequest: () => ({ bad: 1n }) });
  await assert.rejects(session.run('write'), TypeError);
  assert.equal(fs.existsSync(target), false);
  const again = await session.run('hi');
  assert.equal(again.text, 'second');
});

test('a handler rejecting with a value that has no string form still answers the call', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'odd', {}], ['echo']]);
  const odd = metacodes.tool({ name: 'odd', description: 'Throws a bare object.', handler: () => { throw Object.create(null); } });
  const { session } = open(t, { tools: [], hostTools: [odd] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('go');
  assert.match(result.text, /Error/);
  assert.equal(result.stopReason, 'end_turn');
});

// -- an active Run: submit, abort, close -----------------------------------

function blockingTool() {
  let release;
  let started;
  const startedPromise = new Promise((resolve) => { started = resolve; });
  const released = new Promise((resolve) => { release = resolve; });
  const wait = metacodes.tool({
    name: 'wait',
    description: 'Waits for the test.',
    // Capped so a broken test fails instead of holding the suite.
    // unref(): the cap must not keep the test process alive after the suite.
    handler: async () => {
      started();
      await Promise.race([released, new Promise((resolve) => setTimeout(resolve, 10_000).unref())]);
      return 'waited';
    },
  });
  return { wait, started: startedPromise, release };
}

test('submit hands the active Run more input', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'wait', {}], ['text', 'done']]);
  const { wait, started, release } = blockingTool();
  const { session } = open(t, { tools: [], hostTools: [wait] }, provider, workspace(t), { permissionMode: 'full_access' });
  const run = session.run('start');
  await started;
  session.submit('and mention the weather');
  release();
  const result = await run;
  assert.equal(result.inputAccepted, 1);
  assert.equal(result.inputAdopted, 1);
  assert.match(JSON.stringify(provider.requests[1].messages), /and mention the weather/);
});

test('updateCredential from a tool changes the next request', { skip, timeout: TIMEOUT }, async (t) => {
  let session;
  const rotate = metacodes.tool({
    name: 'rotate',
    description: 'Rotates the provider key.',
    handler: async () => {
      session.updateCredential('rotated-key');
      return 'rotated';
    },
  });
  const provider = await withProvider(t, [['tool', 'rotate', {}], ['text', 'done'], ['text', 'again']]);
  ({ session } = open(t, { tools: [], hostTools: [rotate] }, provider, workspace(t), { permissionMode: 'full_access', apiKey: 'first-key' }));
  const result = await session.run('rotate the key');
  assert.equal(result.text, 'done');
  assert.throws(() => session.updateCredential('bad key'), (error) => !String(error.message).includes('bad key'));
  await session.run('once more');
  // The Run's first request used the creation key; the turn after the tool,
  // and the next Run after the refused update, the rotated one.
  assert.deepEqual(provider.authorizations, ['Bearer first-key', 'Bearer rotated-key', 'Bearer rotated-key']);
});

test('abort stops the active Run', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'wait', {}], ['text', 'never asked']]);
  const { wait, started, release } = blockingTool();
  const { session } = open(t, { tools: [], hostTools: [wait] }, provider, workspace(t), { permissionMode: 'full_access' });
  const run = session.run('start');
  await started;
  session.abort();
  release();
  const result = await run;
  assert.equal(result.stopReason, 'aborted');
  assert.equal(provider.requests.length, 1);
});

test('close during a Run is refused and keeps the handle', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'wait', {}], ['text', 'done']]);
  const { wait, started, release } = blockingTool();
  const { runtime, session } = open(t, { tools: [], hostTools: [wait] }, provider, workspace(t), { permissionMode: 'full_access' });
  const run = session.run('start');
  await started;
  assert.throws(() => session.close());
  assert.ok(session._handle);
  release();
  assert.equal((await run).text, 'done');
  session.close();
  assert.equal(session._handle, null);
  assert.equal(runtime.sessions.has(session), false);
});

// -- permissions ---------------------------------------------------------

function writeScript(root, ...names) {
  return [...names.map((name) => ['tool', 'Write', { file_path: path.join(root, name), content: name }]), ['text', 'done']];
}

test('allow and deny rules decide without asking', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const asked = [];
  const onUiRequest = (request) => { asked.push(request); return request.allowOnce(); };
  const denied = await withProvider(t, writeScript(root, 'denied.txt'));
  await open(t, { tools: ['Write'] }, denied, root, { deny: ['Write'], onUiRequest }).session.run('write');
  const allowed = await withProvider(t, writeScript(root, 'allowed.txt'));
  await open(t, { tools: ['Write'] }, allowed, root, { allow: ['Write'], onUiRequest }).session.run('write');
  assert.equal(fs.existsSync(path.join(root, 'denied.txt')), false);
  assert.equal(fs.existsSync(path.join(root, 'allowed.txt')), true);
  assert.deepEqual(asked, []);
});

test('setPermissionMode applies to the next Run', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const provider = await withProvider(t, [...writeScript(root, 'first.txt'), ...writeScript(root, 'second.txt')]);
  const { session } = open(t, { tools: ['Write'] }, provider, root);
  await session.run('write one');
  session.setPermissionMode('full_access');
  await session.run('write two');
  assert.equal(fs.existsSync(path.join(root, 'first.txt')), false);
  assert.equal(fs.existsSync(path.join(root, 'second.txt')), true);
});

test('allowSession is asked once per target', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const asked = [];
  const provider = await withProvider(t, writeScript(root, 'a.txt', 'a.txt', 'b.txt'));
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: (request) => { asked.push(request.data.candidate.target); return request.allowSession(); },
  });
  await session.run('write three times');
  assert.deepEqual(asked, [path.join(root, 'a.txt'), path.join(root, 'b.txt')]);
});

test('an ask_question answer reaches the model', { skip, timeout: TIMEOUT }, async (t) => {
  const question = {
    question: 'Which colour?', header: 'Colour', multiSelect: false,
    options: [{ label: 'Red', description: 'warm' }, { label: 'Blue', description: 'cool' }],
  };
  const provider = await withProvider(t, [['tool', 'AskUserQuestion', { questions: [question] }], ['echo']]);
  const kinds = [];
  const { session } = open(t, { tools: ['AskUserQuestion'] }, provider, workspace(t), {
    onUiRequest: (request) => { kinds.push(request.kind); return request.answer(['Blue']); },
  });
  const result = await session.run('ask me');
  assert.deepEqual(kinds, ['ask_question']);
  assert.match(result.text, /Blue/);
});

// -- providers -----------------------------------------------------------

test('the openai provider speaks chat completions', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['text', 'hello over chat completions']]);
  const runtime = new metacodes.Runtime({ tools: [] });
  t.after(() => runtime.close());
  const session = runtime.session('mock-model', {
    provider: 'openai', baseUrl: provider.openaiUrl, apiKey: 'test-key', workspace: workspace(t),
  });
  const result = await session.run('say hello');
  assert.equal(result.text, 'hello over chat completions');
  assert.equal(result.stopReason, 'end_turn');
  assert.match(JSON.stringify(provider.requests[0].messages), /say hello/);
});

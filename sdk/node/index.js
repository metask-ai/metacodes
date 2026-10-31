'use strict';
// Embed the metacodes agent runtime (AgentCore C ABI) in Node.js.
// See README.md; the native bridge is src/addon.c.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ABI_REVISION = 26;
const BUILTIN_TOOLS = [
  'Read', 'Write', 'Edit', 'Glob', 'Grep', 'Bash', 'BashOutput', 'KillShell',
  'WebSearch', 'WebFetch', 'AskUserQuestion',
];
const DEFAULT_TOOLS = ['Read', 'Glob', 'Grep'];
const SHELL_TOOLS = ['Bash', 'BashOutput', 'KillShell'];
// The CLI agent loop's own default (src/core/agent_loop.zig Options.max_turns).
const DEFAULT_MAX_TURNS = 400;
const MAX_TURNS = 1000;
const PROVIDERS = { anthropic: 1, openai: 2, gemini: 3 };
const PERMISSION_MODES = { default: 1, accept_edits: 2, auto: 3, dont_ask: 4, full_access: 5 };
const SHELL_POLICIES = { disabled: 1, sandboxed: 2, unrestricted: 3 };
const OPENAI_PROTOCOL_RESPONSES = 1;
const STOP_REASONS = {
  1: 'end_turn', 2: 'max_turns', 3: 'aborted', 4: 'tool_error', 5: 'api_error',
  6: 'tool_loop', 7: 'checkpoint_budget_exhausted', 8: 'checkpoint_resource_limit',
};
const API_KEY_ENV = {
  anthropic: ['ANTHROPIC_API_KEY'],
  openai: ['OPENAI_API_KEY'],
  gemini: ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
};
const HOST_OK = 0;
const HOST_FAILED = 1;
const UI_ANSWERED = 0;
const UI_UNAVAILABLE = 1;

const PLATFORM_DIR = path.join(__dirname, 'prebuilds', `${process.platform}-${process.arch}`);

function libraryFileName() {
  if (process.platform === 'darwin') return 'libmetask_agentcore.dylib';
  if (process.platform === 'win32') return 'metask_agentcore.dll';
  return 'libmetask_agentcore.so';
}

/** Where the AgentCore shared library is looked for, in order. */
function candidateLibraryPaths(explicit) {
  if (explicit) return [path.resolve(explicit)];
  const name = libraryFileName();
  const paths = [];
  if (process.env.METACODES_AGENTCORE_LIB) paths.push(path.resolve(process.env.METACODES_AGENTCORE_LIB));
  paths.push(path.join(PLATFORM_DIR, name));
  if (process.env.METACODES_AGENTCORE_SDK) paths.push(path.join(process.env.METACODES_AGENTCORE_SDK, 'lib', name));
  const opt = path.join(os.homedir(), '.local', 'opt');
  paths.push(path.join(opt, 'metacodes', 'sdk', 'agentcore', 'lib', name));
  paths.push(path.join(opt, 'metacodes-dev', 'sdk', 'agentcore', 'lib', name));
  return paths;
}

let native = null;
let loadedLibrary = null;

function loadNative(explicit) {
  if (!native) {
    const addon = path.join(PLATFORM_DIR, 'metacodes.node');
    if (!fs.existsSync(addon)) {
      throw new Error(`metacodes: no native addon for ${process.platform}-${process.arch} at ${addon}`);
    }
    native = require(addon);
  }
  if (loadedLibrary) {
    if (explicit && path.resolve(explicit) !== loadedLibrary) {
      throw new Error(`metacodes: AgentCore is already loaded from ${loadedLibrary}`);
    }
    return native;
  }
  const tried = [];
  for (const candidate of candidateLibraryPaths(explicit)) {
    if (fs.existsSync(candidate)) {
      native.load(candidate);
      loadedLibrary = candidate;
      return native;
    }
    tried.push(candidate);
  }
  const error = new Error(
    'metacodes: AgentCore shared library not found. Set METACODES_AGENTCORE_LIB or install ' +
      `metacodes with its SDK. Tried: ${tried.join(', ')}`,
  );
  error.code = 'LIBRARY_NOT_FOUND';
  throw error;
}

function bundledRipgrep(libraryPath) {
  const rg = process.platform === 'win32' ? 'rg.exe' : 'rg';
  for (const candidate of [path.join(path.dirname(libraryPath), rg), path.join(path.dirname(libraryPath), '..', 'bin', rg)]) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// JSON for a value a handler returned. A value JSON.stringify throws on (a
// BigInt, a cycle) or turns into undefined (a function, a symbol) is the
// handler's error: it must reach the rejection handler that completes the
// pending call, not escape as an unhandled rejection that kills the host or
// leaves AgentCore waiting for a call that never completes.
function toJson(value, what) {
  const text = JSON.stringify(value ?? null);
  if (typeof text !== 'string') throw new TypeError(`${what} is not JSON-serializable`);
  return text;
}

// A rejection value can be anything, including one String() throws on
// (Object.create(null)); the text must never throw.
function errorText(error) {
  try {
    return `${error && error.name ? error.name : 'Error'}: ${error && error.message ? error.message : String(error)}`;
  } catch (_) {
    return 'Error: the handler rejected with a value that has no string form';
  }
}

/** Answer a blocked native call exactly once; a second answer would touch freed memory. */
function once(handle, fallbackStatus) {
  let done = false;
  return (status, text) => {
    if (done) return;
    done = true;
    native.completeCall(handle, status ?? fallbackStatus, text ?? '');
  };
}

/** Define a tool implemented in JavaScript. `handler(args)` may be async. */
function tool({ name, description, inputSchema, handler }) {
  if (!name || typeof handler !== 'function') throw new TypeError('tool needs a name and a handler');
  return {
    name,
    description: description || name,
    inputSchema: inputSchema || { type: 'object', properties: {} },
    handler,
  };
}

class UiRequest {
  constructor(kind, data) {
    this.kind = kind;
    this.data = data;
  }

  _permission(choice) {
    if (this.kind !== 'permission') throw new Error('not a permission request');
    const response = {
      permission: choice,
      request_id: this.data.request_id,
      policy_generation: this.data.policy_generation,
    };
    if (choice.endsWith('_session')) {
      if (!this.data.candidate) throw new Error('this request offers no session-scoped answer');
      response.rule_id = this.data.candidate.rule_id;
    }
    return response;
  }

  allowOnce() { return this._permission('allow_once'); }
  allowSession() { return this._permission('allow_session'); }
  denyOnce() { return this._permission('deny_once'); }
  denySession() { return this._permission('deny_session'); }

  /** Answer an ask_question request: one array of chosen labels per question. */
  answer(...values) {
    if (this.kind !== 'ask_question') throw new Error('not a question request');
    return { answers: values.map((chosen) => ({ values: [...chosen] })) };
  }
}

/** Rebuilds the final answer from output-segment events (see the ABI document). */
class RunState {
  constructor() {
    this.open = [];
    this.pending = new Map();
    this.finalText = '';
    this.segments = [];
    this.modelError = null;
    this.usage = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
  }

  observe(tag, payload) {
    if (tag === 'output_segment_begin') {
      this.open = [];
    } else if (tag === 'text_chunk') {
      this.open.push(payload);
    } else if (tag === 'output_segment_end') {
      const text = this.open.join('');
      this.open = [];
      const group = payload.group ?? 0;
      this.segments.push({ disposition: payload.disposition, group, text });
      if (payload.disposition === 'continued') {
        if (!this.pending.has(group)) this.pending.set(group, []);
        this.pending.get(group).push(text);
      } else if (payload.disposition === 'final') {
        this.finalText = (this.pending.get(group) || []).join('') + text;
        this.pending.delete(group);
      }
    } else if (tag === 'model_error' && payload && typeof payload === 'object') {
      this.modelError = payload;
    } else if (tag === 'usage' && payload && typeof payload === 'object') {
      for (const key of Object.keys(this.usage)) this.usage[key] += Number(payload[key] || 0);
    }
  }
}

class AgentCoreError extends Error {
  constructor(operation, status, statusName, diagnostic) {
    super(`${operation} failed: ${statusName}${diagnostic ? `: ${diagnostic}` : ''}`);
    this.name = 'AgentCoreError';
    this.code = statusName;
    this.status = status;
    this.diagnostic = diagnostic || '';
  }
}

class Runtime {
  /**
   * @param {{tools?: string[], hostTools?: object[], library?: string}} [options]
   */
  constructor({ tools = DEFAULT_TOOLS, hostTools = [], library } = {}) {
    const unknown = tools.filter((name) => !BUILTIN_TOOLS.includes(name));
    if (unknown.length) throw new Error(`unknown built-in tools: ${unknown.join(', ')}`);
    this._native = loadNative(library);
    this.tools = [...tools];
    this.hostTools = [...hostTools];
    this.sessions = new Set();
    if ((tools.includes('Glob') || tools.includes('Grep')) && !process.env.RG_BIN) {
      const rg = bundledRipgrep(loadedLibrary);
      if (rg) process.env.RG_BIN = rg;
    }
    const specs = this.hostTools.map((hostTool) => ({
      name: hostTool.name,
      description: hostTool.description,
      schema: JSON.stringify(hostTool.inputSchema),
    }));
    this._handle = this._native.runtimeCreate(this.tools, specs, (kind, handle, index, args) => {
      this._dispatchTool(handle, index, args);
    });
  }

  _dispatchTool(handle, index, args) {
    const finish = once(handle, HOST_FAILED);
    const hostTool = this.hostTools[index];
    Promise.resolve()
      .then(() => hostTool.handler(args ? JSON.parse(args) : {}))
      .then((value) => (typeof value === 'string' ? value : toJson(value, `${hostTool.name} result`)))
      .then(
        (text) => finish(HOST_OK, text),
        (error) => finish(HOST_FAILED, errorText(error)),
      )
      // Last resort: the call is answered whatever went wrong above; once()
      // ignores a second answer.
      .catch(() => finish(HOST_FAILED, 'Error'));
  }

  /** Create a Session; see README.md for the options. */
  session(model, options = {}) {
    const session = new Session(this, model, options);
    this.sessions.add(session);
    return session;
  }

  close() {
    if (!this._handle) return;
    for (const session of [...this.sessions]) session.close();
    this._native.runtimeDestroy(this._handle);
    this._handle = null;
  }
}

class Session {
  constructor(runtime, model, options = {}) {
    const {
      provider = 'anthropic',
      apiKey,
      baseUrl = '',
      workspace = '.',
      workspaceHome = '',
      tools,
      permissionMode = 'default',
      shell = 'disabled',
      openaiProtocol,
      allow = [],
      ask = [],
      deny = [],
      onEvent,
      onUiRequest,
    } = options;
    if (!(provider in PROVIDERS)) throw new Error(`provider must be one of ${Object.keys(PROVIDERS).join(', ')}`);
    if (!(permissionMode in PERMISSION_MODES)) throw new Error(`permissionMode must be one of ${Object.keys(PERMISSION_MODES).join(', ')}`);
    if (!(shell in SHELL_POLICIES)) throw new Error(`shell must be one of ${Object.keys(SHELL_POLICIES).join(', ')}`);
    let protocol = 0;
    if (openaiProtocol === 'responses') {
      if (provider !== 'openai') throw new Error("openaiProtocol applies to provider 'openai' only");
      protocol = OPENAI_PROTOCOL_RESPONSES;
    } else if (openaiProtocol && openaiProtocol !== 'chat_completions') {
      throw new Error('openaiProtocol must be chat_completions or responses');
    }
    let key = apiKey;
    if (key === undefined) {
      for (const name of [...API_KEY_ENV[provider], 'METACODES_API_KEY']) {
        if (process.env[name]) { key = process.env[name]; break; }
      }
    }
    let selected = tools;
    if (!selected) {
      selected = [...runtime.tools, ...runtime.hostTools.map((hostTool) => hostTool.name)];
      if (shell === 'disabled') selected = selected.filter((name) => !SHELL_TOOLS.includes(name));
    }
    this.runtime = runtime;
    this.model = model;
    this._native = runtime._native;
    this._onEvent = onEvent;
    this._onUiRequest = onUiRequest;
    this._nextRunId = 1;
    this._nextInputId = 1;
    this._active = null;
    this._handle = this._native.sessionCreate(
      runtime._handle,
      {
        provider: PROVIDERS[provider],
        protocol,
        permissionMode: PERMISSION_MODES[permissionMode],
        shell: SHELL_POLICIES[shell],
        apiKey: key || '',
        baseUrl,
        workspaceRoot: path.resolve(workspace),
        workspaceHome: workspaceHome ? path.resolve(workspaceHome) : '',
        model,
        tools: selected,
        allow,
        ask,
        deny,
      },
      (kind, a, b) => this._dispatch(kind, a, b),
    );
  }

  _dispatch(kind, a, b) {
    if (kind === 'event') {
      this._event(a);
    } else if (kind === 'ui') {
      this._uiRequest(a, b);
    } else if (kind === 'done') {
      this._done(a);
    }
  }

  _event(json) {
    const active = this._active;
    let event;
    try {
      event = JSON.parse(json);
    } catch (error) {
      return;
    }
    const keys = Object.keys(event);
    if (active && keys.length === 1) active.state.observe(keys[0], event[keys[0]]);
    for (const listener of [this._onEvent, active && active.onEvent]) {
      if (!listener) continue;
      try {
        listener(event);
      } catch (error) {
        // A broken listener must not poison the Session: stop the Run and
        // reject its Promise once AgentCore has returned.
        if (active && !active.error) active.error = error;
        this.abort();
      }
    }
  }

  _uiRequest(handle, json) {
    const finish = once(handle, UI_UNAVAILABLE);
    if (!this._onUiRequest) return finish(UI_UNAVAILABLE, '');
    let request;
    try {
      const data = JSON.parse(json);
      request = 'ask_question' in data
        ? new UiRequest('ask_question', { questions: data.ask_question })
        : new UiRequest('permission', data.permission || data);
    } catch (error) {
      return finish(UI_UNAVAILABLE, '');
    }
    Promise.resolve()
      .then(() => this._onUiRequest(request))
      .then((answer) => (answer == null ? null : toJson(answer, 'onUiRequest answer')))
      .then(
        (text) => (text == null ? finish(UI_UNAVAILABLE, '') : finish(UI_ANSWERED, text)),
        (error) => {
          if (this._active && !this._active.error) this._active.error = error;
          finish(UI_UNAVAILABLE, '');
        },
      )
      .catch(() => finish(UI_UNAVAILABLE, ''));
  }

  _done(outcome) {
    const active = this._active;
    this._active = null;
    if (!active) return;
    if (active.error) return active.reject(active.error);
    if (outcome.status !== 0) {
      return active.reject(new AgentCoreError('session.run_input', outcome.status, outcome.statusName, outcome.diagnostic));
    }
    active.resolve({
      text: active.state.finalText,
      stopReason: STOP_REASONS[outcome.stopReasonCode] || String(outcome.stopReasonCode),
      turns: outcome.turns,
      toolCalls: outcome.toolCalls,
      usage: active.state.usage,
      segments: active.state.segments,
      inputAccepted: outcome.inputAccepted,
      inputAdopted: outcome.inputAdopted,
      modelError: active.state.modelError,
    });
  }

  /**
   * Run one prompt to completion.
   * @returns {Promise<{text: string, stopReason: string, turns: number, toolCalls: number, usage: object, segments: object[]}>}
   */
  run(prompt, { maxTurns, onEvent } = {}) {
    if (!this._handle) return Promise.reject(new Error('session is closed'));
    if (this._active) return Promise.reject(new Error('a Run is already active on this session'));
    const turns = maxTurns === undefined ? DEFAULT_MAX_TURNS : Number(maxTurns);
    if (!Number.isInteger(turns) || turns < 1 || turns > MAX_TURNS) {
      return Promise.reject(new RangeError(`maxTurns must be between 1 and ${MAX_TURNS}`));
    }
    return new Promise((resolve, reject) => {
      const runId = this._nextRunId++;
      this._active = { runId, state: new RunState(), onEvent, resolve, reject, error: null };
      try {
        this._native.sessionRun(this._handle, runId, String(prompt), turns);
      } catch (error) {
        this._active = null;
        reject(error);
      }
    });
  }

  /** Run `prompt` and iterate over its events; `stream.result` resolves to the RunResult. */
  stream(prompt, options = {}) {
    const queue = [];
    let wake = null;
    let finished = false;
    let failure = null;
    const push = (event) => {
      queue.push(event);
      if (wake) { wake(); wake = null; }
    };
    const result = this.run(prompt, { ...options, onEvent: push }).then(
      (value) => { finished = true; if (wake) wake(); return value; },
      (error) => { finished = true; failure = error; if (wake) wake(); throw error; },
    );
    result.catch(() => {});
    return {
      result,
      abort: () => this.abort(),
      async *[Symbol.asyncIterator]() {
        while (true) {
          if (queue.length) { yield queue.shift(); continue; }
          if (finished) break;
          await new Promise((resolve) => { wake = resolve; });
        }
        if (failure) throw failure;
      },
    };
  }

  /** Ask the active Run to stop; it settles with stopReason 'aborted'. */
  abort() {
    if (this._active && this._handle) this._native.sessionAbort(this._handle, this._active.runId);
  }

  /** Hand the active Run more user text; returns its acceptance sequence. */
  submit(text) {
    if (!this._active) throw new Error('no active Run');
    return this._native.sessionSubmit(this._handle, this._active.runId, this._nextInputId++, String(text));
  }

  /**
   * Replace the provider credential in place (AgentCore Revision 25). Every
   * request sent afterwards uses it: the next turn of a Run already going, a
   * retry, a compaction, a Skill, a request still waiting for a connection. A
   * request already sent keeps the old key. Callable from this Session's own tool and
   * UI handlers. 1 to 16384 bytes of printable ASCII; anything else throws and
   * keeps the previous key.
   */
  updateCredential(apiKey) {
    this._native.sessionUpdateCredential(this._handle, String(apiKey));
  }

  describe() {
    return JSON.parse(this._native.sessionDescribe(this._handle));
  }

  setModel(model) {
    this._native.sessionSetModel(this._handle, model);
    this.model = model;
  }

  setPermissionMode(mode) {
    if (!(mode in PERMISSION_MODES)) throw new Error(`permissionMode must be one of ${Object.keys(PERMISSION_MODES).join(', ')}`);
    this._native.sessionSetPermissionMode(this._handle, PERMISSION_MODES[mode]);
  }

  close() {
    if (!this._handle) return;
    this._native.sessionDestroy(this._handle);
    this._handle = null;
    this.runtime.sessions.delete(this);
  }
}

module.exports = {
  ABI_REVISION,
  AgentCoreError,
  BUILTIN_TOOLS,
  DEFAULT_TOOLS,
  Runtime,
  Session,
  UiRequest,
  candidateLibraryPaths,
  tool,
};

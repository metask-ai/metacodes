'use strict';
// A scripted Anthropic Messages SSE server on loopback, for tests only.
// Each request takes the next script step:
//   ['text', '...']            one text block, end_turn
//   ['tool', name, inputObject] one tool_use block
//   ['echo']                   "saw: " + the last tool_result text it received
//   ['status', code, headers, bodyObject]  that non-2xx JSON

const http = require('node:http');

function sse(events) {
  return events.map(([name, data]) => `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`).join('');
}

function start(index) {
  return ['message_start', {
    type: 'message_start',
    message: {
      id: `msg_${index}`, type: 'message', role: 'assistant', model: 'mock-model', content: [],
      stop_reason: null, stop_sequence: null, usage: { input_tokens: 11, output_tokens: 1 },
    },
  }];
}

function finish(stopReason) {
  return [
    ['message_delta', { type: 'message_delta', delta: { stop_reason: stopReason, stop_sequence: null }, usage: { output_tokens: 7 } }],
    ['message_stop', { type: 'message_stop' }],
  ];
}

function textResponse(index, text) {
  return sse([
    start(index),
    ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
    ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } }],
    ['content_block_stop', { type: 'content_block_stop', index: 0 }],
    ...finish('end_turn'),
  ]);
}

function toolResponse(index, name, input) {
  return sse([
    start(index),
    ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: `toolu_${index}`, name, input: {} } }],
    ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(input) } }],
    ['content_block_stop', { type: 'content_block_stop', index: 0 }],
    ...finish('tool_use'),
  ]);
}

// OpenAI Chat Completions SSE: one content delta, `stop`, then usage.
function openaiTextResponse(text) {
  const chunks = [
    { choices: [{ index: 0, delta: { role: 'assistant', content: '' } }] },
    { choices: [{ index: 0, delta: { content: text } }] },
    { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] },
    { choices: [], usage: { prompt_tokens: 11, completion_tokens: 7 } },
  ];
  return `${chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join('')}data: [DONE]\n\n`;
}

function lastToolResult(body) {
  for (const message of [...(body.messages || [])].reverse()) {
    if (!Array.isArray(message.content)) continue;
    for (const block of message.content) {
      if (block && block.type === 'tool_result') {
        if (Array.isArray(block.content)) return block.content.map((part) => part.text || '').join('');
        return String(block.content);
      }
    }
  }
  return '';
}

async function startMockProvider(script) {
  const steps = [...script];
  const requests = [];
  const authorizations = [];
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      requests.push(body);
      authorizations.push(request.headers.authorization || '');
      const index = requests.length;
      const step = steps.shift() || ['text', 'script exhausted'];
      if (step[0] === 'status') {
        const failure = JSON.stringify(step[3]);
        response.writeHead(step[1], { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(failure), ...step[2] });
        response.end(failure);
        return;
      }
      let payload;
      if (request.url.endsWith('/chat/completions')) payload = openaiTextResponse(step[0] === 'text' ? step[1] : 'unsupported step');
      else if (step[0] === 'tool') payload = toolResponse(index, step[1], step[2]);
      else if (step[0] === 'echo') payload = textResponse(index, `saw: ${lastToolResult(body)}`);
      else payload = textResponse(index, step[1]);
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Content-Length': Buffer.byteLength(payload) });
      response.end(payload);
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    requests,
    authorizations,
    baseUrl: `http://127.0.0.1:${server.address().port}/v1/messages`,
    openaiUrl: `http://127.0.0.1:${server.address().port}/v1/chat/completions`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

module.exports = { startMockProvider };

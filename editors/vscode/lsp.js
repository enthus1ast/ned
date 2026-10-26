// JSON-RPC 2.0 the way the Language Server Protocol sends it over stdio: each message is a header
// ("Content-Length: <bytes>", an empty line) and then that many bytes of UTF-8 JSON. A request carries an id and
// gets one answer; a notification carries none. Node's streams only, no npm packages — so the extension is plain
// files and the .vsix can be made with Python alone (tests/build/vscode.sh).
'use strict';

const ErrorCodes = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
  ServerNotInitialized: -32002,
  RequestCancelled: -32800,
  ContentModified: -32801,
  ServerCancelled: -32802,
  ConnectionClosed: -32099          // (not sent by anyone: what a request gets when the server is gone)
};

class ResponseError extends Error {
  constructor(code, message, data) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

// (a cancelled request, or one the server gave up because the text changed: nothing to tell the person about)
function isCancel(e) {
  return !!e && (e.code === ErrorCodes.RequestCancelled || e.code === ErrorCodes.ContentModified ||
                 e.code === ErrorCodes.ServerCancelled);
}

function clock() {
  return new Date().toLocaleTimeString();
}

function paramsText(params) {
  return params === undefined ? '\nNo parameters provided.\n' : `\nParams: ${JSON.stringify(params, null, 2)}\n`;
}

class Connection {
  // input: the server's stdout; output: its stdin. log(line) writes to the Output channel.
  constructor(input, output, log) {
    this.input = input;
    this.output = output;
    this.log = log;
    this.trace = 'off';                 // 'off' | 'messages' | 'verbose' (nedls.trace.server)
    this.nextId = 0;
    this.pending = new Map();           // our requests waiting for their answer, by id
    this.requestHandlers = new Map();
    this.notificationHandlers = new Map();
    this.chunks = [];                   // what has come of the message being read
    this.size = 0;                      // (their bytes)
    this.need = 0;                      // (the bytes it takes, header and body, once its header is read)
    this.closed = false;
    this.closeListeners = [];
    input.on('data', (chunk) => this.receive(chunk));
    input.on('end', () => this.close());
    input.on('close', () => this.close());
    input.on('error', () => this.close());
    // (writing to a server that has just died: EPIPE comes as an event, and an event nobody listens to would
    // take the whole extension host down)
    output.on('error', () => this.close());
  }

  onRequest(method, handler) { this.requestHandlers.set(method, handler); }
  onNotification(method, handler) { this.notificationHandlers.set(method, handler); }
  onClose(listener) { this.closeListeners.push(listener); }

  // ── reading ──

  receive(chunk) {
    if (this.closed) return;              // (what a server says after we are done with it: nobody to hear it)
    this.chunks.push(chunk);
    this.size += chunk.length;
    // (a long message comes in many pieces: they are joined once it is all there, not copied again for each)
    if (this.size < this.need) return;
    let buf = this.chunks.length === 1 ? this.chunks[0] : Buffer.concat(this.chunks, this.size);
    this.chunks = [];
    this.size = 0;
    this.need = 0;
    while (!this.closed) {
      const end = buf.indexOf('\r\n\r\n');
      if (end < 0) break;
      let length = -1;
      for (const line of buf.toString('ascii', 0, end).split('\r\n')) {
        const k = line.indexOf(':');
        if (k > 0 && line.slice(0, k).trim().toLowerCase() === 'content-length') {
          length = parseInt(line.slice(k + 1).trim(), 10);
        }
      }
      if (!(length >= 0)) {
        // (a header without a length: there is no telling where its body ends — skipped, the next header read)
        this.log('nedls sent a message without Content-Length: dropped');
        buf = buf.subarray(end + 4);
        continue;
      }
      if (buf.length < end + 4 + length) {             // (the rest of the body is still on its way)
        this.need = end + 4 + length;
        break;
      }
      const body = buf.toString('utf8', end + 4, end + 4 + length);
      buf = buf.subarray(end + 4 + length);
      let msg;
      try {
        msg = JSON.parse(body);
      } catch (e) {
        this.log(`nedls sent a message that is not JSON: ${body.slice(0, 200)}`);
        continue;
      }
      try {
        this.dispatch(msg);
      } catch (e) {
        this.log(`a message from nedls could not be handled: ${e && e.stack || e}`);
      }
    }
    if (buf.length && !this.closed) {
      this.chunks = [buf];
      this.size = buf.length;
    }
  }

  dispatch(msg) {
    if (!msg || typeof msg !== 'object') return;
    if (typeof msg.method === 'string') {
      if (msg.id !== undefined && msg.id !== null) this.handleRequest(msg);
      else this.handleNotification(msg);
    } else if (msg.id !== undefined && msg.id !== null) {
      this.handleResponse(msg);
    }
  }

  handleResponse(msg) {
    const p = this.pending.get(msg.id);
    if (!p) return;                       // (the answer to a request given up on: cancelled)
    this.pending.delete(msg.id);
    p.done();
    if (this.trace !== 'off') {
      let s = `[Trace - ${clock()}] Received response '${p.method} - (${msg.id})' in ${Date.now() - p.started}ms.`;
      if (this.trace === 'verbose') {
        s += msg.error ? `\nRequest failed: ${msg.error.message} (${msg.error.code}).`
                       : `\nResult: ${JSON.stringify(msg.result, null, 2)}`;
      }
      this.log(s + (this.trace === 'verbose' ? '\n' : ''));
    }
    if (msg.error) {
      p.reject(new ResponseError(msg.error.code, msg.error.message || 'request failed', msg.error.data));
    } else {
      p.resolve(msg.result === undefined ? null : msg.result);
    }
  }

  handleRequest(msg) {
    const started = Date.now();
    this.traceIn(`Received request '${msg.method} - (${msg.id})'.`, msg.params);
    const handler = this.requestHandlers.get(msg.method);
    if (!handler) {
      // (an unknown request is answered, not left hanging: the server may be waiting for it)
      this.reply(msg, started, undefined, new ResponseError(ErrorCodes.MethodNotFound,
                                                            `Unhandled method ${msg.method}`));
      return;
    }
    Promise.resolve()
      .then(() => handler(msg.params))
      .then((result) => this.reply(msg, started, result === undefined ? null : result),
            (e) => this.reply(msg, started, undefined,
                              new ResponseError(typeof (e && e.code) === 'number' ? e.code : ErrorCodes.InternalError,
                                                String(e && e.message || e))));
  }

  reply(msg, started, result, error) {
    if (this.trace !== 'off') {
      let s = `[Trace - ${clock()}] Sending response '${msg.method} - (${msg.id})'. ` +
              `Processing request took ${Date.now() - started}ms`;
      if (this.trace === 'verbose') {
        s += error ? `\nRequest failed: ${error.message} (${error.code}).`
                   : `\nResult: ${JSON.stringify(result, null, 2)}\n`;
      }
      this.log(s);
    }
    if (error) {
      this.write({ jsonrpc: '2.0', id: msg.id, error: { code: error.code, message: error.message } });
    } else {
      this.write({ jsonrpc: '2.0', id: msg.id, result });
    }
  }

  handleNotification(msg) {
    this.traceIn(`Received notification '${msg.method}'.`, msg.params);
    const handler = this.notificationHandlers.get(msg.method);
    if (!handler) return;                 // ($/… and the ones we do not use: nothing to do, as the protocol says)
    try {
      handler(msg.params);
    } catch (e) {
      this.log(`${msg.method}: ${e && e.stack || e}`);
    }
  }

  traceIn(what, params) {
    if (this.trace === 'off') return;
    let s = `[Trace - ${clock()}] ${what}`;
    if (this.trace === 'verbose') s += paramsText(params);
    this.log(s);
  }

  // ── writing ──

  write(msg) {
    if (this.closed) return;
    const body = Buffer.from(JSON.stringify(msg), 'utf8');
    try {
      this.output.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii'), body]));
    } catch (e) {
      this.close();
    }
  }

  notify(method, params) {
    if (this.closed) return;
    if (this.trace !== 'off') {
      let s = `[Trace - ${clock()}] Sending notification '${method}'.`;
      if (this.trace === 'verbose') s += paramsText(params);
      this.log(s);
    }
    this.write(params === undefined ? { jsonrpc: '2.0', method } : { jsonrpc: '2.0', method, params });
  }

  // A request; its answer as a promise. With a cancellation token from VS Code: when VS Code no longer wants the
  // answer, the server is told ($/cancelRequest) and the promise is rejected at once with RequestCancelled —
  // the late answer, if one comes, is dropped.
  request(method, params, token) {
    if (this.closed) {
      return Promise.reject(new ResponseError(ErrorCodes.ConnectionClosed, 'nedls is not running'));
    }
    if (token && token.isCancellationRequested) {
      return Promise.reject(new ResponseError(ErrorCodes.RequestCancelled, 'cancelled'));
    }
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      let sub = null;
      this.pending.set(id, { method, started: Date.now(), resolve, reject, done: () => sub && sub.dispose() });
      if (token) {
        sub = token.onCancellationRequested(() => {
          const p = this.pending.get(id);
          if (!p) return;
          this.pending.delete(id);
          p.done();
          this.notify('$/cancelRequest', { id });
          reject(new ResponseError(ErrorCodes.RequestCancelled, 'cancelled'));
        });
      }
      if (this.trace !== 'off') {
        let s = `[Trace - ${clock()}] Sending request '${method} - (${id})'.`;
        if (this.trace === 'verbose') s += paramsText(params);
        this.log(s);
      }
      this.write(params === undefined ? { jsonrpc: '2.0', id, method } : { jsonrpc: '2.0', id, method, params });
    });
  }

  // The server is gone (or we are done with it): every request still waiting gets an error, not silence.
  close() {
    if (this.closed) return;
    this.closed = true;
    const waiting = [...this.pending.values()];
    this.pending.clear();
    for (const p of waiting) {
      p.done();
      p.reject(new ResponseError(ErrorCodes.ConnectionClosed, 'the connection to nedls closed'));
    }
    for (const l of this.closeListeners) {
      try { l(); } catch (_) { /* (one listener's trouble is not the others') */ }
    }
  }
}

module.exports = { Connection, ResponseError, ErrorCodes, isCancel };

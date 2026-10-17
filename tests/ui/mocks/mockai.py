#!/usr/bin/env python3
"""Strict mock of the Anthropic and OpenAI APIs for ned tests.
Model names choose behaviour (all on the OpenAI side):
  o4-mini*, gpt-5*, gpt-6*  reasoning: reject max_tokens and non-default temperature
  o1-mini                   also rejects the system role
  *-pro                     only on /responses (404 on chat/completions)
  gpt-6-verify              refuses stream=true (organisation not verified)
  legacy-*                  rejects max_completion_tokens
  empty-*                   returns no text, finish_reason=length
"""
import json, sys, time, threading, re
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

import os
LOG = os.environ.get('NED_TEST_MOCK_LOG', '/tmp/ned-mock-requests.log')
lock = threading.Lock()

def log(path, body):
    with lock:
        with open(LOG, 'a') as f:
            f.write(json.dumps({'path': path, 'body': body}) + '\n')

def err(h, code, msg, param=None, ecode=None):
    b = json.dumps({'error': {'message': msg, 'type': 'invalid_request_error', 'param': param, 'code': ecode}}).encode()
    h.send_response(code); h.send_header('Content-Type', 'application/json'); h.send_header('Content-Length', str(len(b)))
    h.end_headers(); h.wfile.write(b)

def reasoning(m):
    m = m.split('/')[-1]
    return (len(m) > 1 and m[0] == 'o' and m[1].isdigit()) or m.startswith('gpt-5') or m.startswith('gpt-6')

def last_user_text(msgs):
    for m in reversed(msgs):
        if m.get('role') == 'user':
            c = m.get('content')
            if isinstance(c, list):
                return ' '.join(x.get('text', '') for x in c if isinstance(x, dict))
            return c or ''
    return ''

def has_tool_result(msgs):
    return bool(msgs) and (msgs[-1].get('role') == 'tool' or msgs[-1].get('type') == 'function_call_output')

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass

    def sse_start(self):
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close'); self.end_headers()
        self.close_connection = True

    def ev(self, obj, event=None):
        s = ''
        if event: s += 'event: ' + event + '\n'
        s += 'data: ' + (obj if isinstance(obj, str) else json.dumps(obj)) + '\n\n'
        self.wfile.write(s.encode()); self.wfile.flush()

    def do_GET(self):
        if self.path.endswith('/models'):
            ids = ['gpt-6', 'gpt-6-pro', 'gpt-6-verify', 'o4-mini-2025-04-16', 'o1-mini', 'gpt-4.1', 'legacy-chat',
                   'empty-model', 'text-embedding-3-small', 'whisper-1', 'dall-e-3', 'gpt-image-1', 'tts-1',
                   'gpt-4o-realtime-preview', 'omni-moderation-latest']
            b = json.dumps({'object': 'list', 'data': [{'id': i, 'object': 'model'} for i in ids]}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            err(self, 404, 'not found')

    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(n)
        try: body = json.loads(raw)
        except Exception: return err(self, 400, 'bad json')
        log(self.path, body)
        if self.path.endswith('/v1/messages'): return self.anthropic(body)
        if self.path.endswith('/chat/completions'): return self.chat(body)
        if self.path.endswith('/responses'): return self.resp_api(body)
        err(self, 404, 'unknown path ' + self.path)

    # ── Anthropic ──
    def anthropic(self, b):
        text = 'Hello from mock ' + b.get('model', '?') + '. You said: ' + last_user_text(b.get('messages', []))[-60:]
        if not b.get('stream'):
            out = {'content': [{'type': 'text', 'text': text}], 'usage': {'input_tokens': 10, 'output_tokens': 5}}
            bb = json.dumps(out).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(bb))); self.end_headers(); self.wfile.write(bb); return
        self.sse_start()
        self.ev({'type': 'message_start', 'message': {'usage': {'input_tokens': 100, 'output_tokens': 1}}}, 'message_start')
        self.ev({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
        for w in text.split(' '):
            self.ev({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': w + ' '}})
        self.ev({'type': 'message_delta', 'usage': {'output_tokens': 20}})
        self.ev({'type': 'message_stop'})

    # ── OpenAI chat completions ──
    def chat(self, b):
        m = b.get('model', '')
        if m == 'missing-model':
            return err(self, 404, 'The model `missing-model` does not exist or you do not have access to it.', None, 'model_not_found')
        if m == 'o9-small' and (b.get('max_completion_tokens') or 0) > 16384:
            return err(self, 400, 'max_tokens is too large: %d. This model supports at most 16384 completion tokens, whereas you provided %d.' % (b['max_completion_tokens'], b['max_completion_tokens']), 'max_tokens', 'invalid_value')
        if m == 'broke-model':
            return err(self, 429, 'You exceeded your current quota, please check your plan and billing details.', None, 'insufficient_quota')
        if m.endswith('-pro'):
            return err(self, 404, 'This model is only supported in v1/responses and not in v1/chat/completions.', 'model')
        if reasoning(m) or m == 'empty-model':
            if 'max_tokens' in b:
                return err(self, 400, "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.", 'max_tokens', 'unsupported_parameter')
            if 'temperature' in b and b['temperature'] != 1:
                return err(self, 400, "Unsupported value: 'temperature' does not support %s with this model. Only the default (1) value is supported." % b['temperature'], 'temperature', 'unsupported_value')
        if m == 'o1-mini' and any(x.get('role') == 'system' for x in b.get('messages', [])):
            return err(self, 400, "Unsupported value: 'messages[0].role' does not support 'system' with this model.", 'messages[0].role', 'unsupported_value')
        if m.startswith('legacy') and 'max_completion_tokens' in b:
            return err(self, 400, 'Unrecognized request argument supplied: max_completion_tokens')
        if m == 'gpt-6-verify' and b.get('stream'):
            return err(self, 400, 'Your organization must be verified to stream this model. Please go to: https://platform.openai.com/settings/organization/general and click on Verify Organization. If you just verified, it can take up to 15 minutes for access to propagate.', 'stream', 'unsupported_value')
        msgs = b.get('messages', [])
        user = last_user_text(msgs)
        want_tool = 'list the files' in user and 'tools' in b and not has_tool_result(msgs)
        want_edit = 'doc comment to shout' in user and 'tools' in b and not has_tool_result(msgs)
        want_cube = 'add a cube proc' in user and 'tools' in b
        want_gen = 'run the generator' in user and 'tools' in b and not has_tool_result(msgs)
        want_plan = ('PLANTASK' in user or 'twice2 and thrice2' in user or 'of the plan now' in user) and 'tools' in b
        mcp_name = None
        if 'use the echo tool' in user and not has_tool_result(msgs):
            for t in b.get('tools') or []:
                n = (t.get('function') or t).get('name', '')
                if n.endswith('__echo'): mcp_name = n
        mcp_args = '{"text": "pong"}'
        if 'read the greeting resource' in user and not has_tool_result(msgs):
            for t in b.get('tools') or []:
                n = (t.get('function') or t).get('name', '')
                if n.endswith('__read_resource'): mcp_name = n
            mcp_args = '{"uri": "note://greeting"}'
        if m == 'empty-model':
            text, finish = '', 'length'
        elif has_tool_result(msgs):
            text, finish = 'Tool said: ' + str(msgs[-1].get('content', ''))[:80].replace('\n', ' | '), 'stop'
        elif 'Fix this compiler error' in user and '<code>' in user:
            code = user.split('<code>\n', 1)[1].split('\n</code>', 1)[0]
            if 'Your previous answer was' in user:
                text = code.replace('let sum = 0', 'var sum = 0')
            else:
                text = code.replace('sum += x', 'sum += x +')
            finish = 'stop'
        elif 'Write a test file for the Nim module below' in user:
            imp = re.search(r'\nimport (\S+)\nThen one suite', user).group(1)
            if 'does not compile' in user:
                text = ('```nim\nimport std/unittest\nimport ' + imp + '\n\nsuite "utils":\n  test "twice doubles":\n'
                        '    check twice(2) == 4\n  test "shout adds a bang":\n    check shout("a") == "A!"\n'
                        '  test "twice of a negative":\n    check twice(-1) == 2\n```\n')
            else:
                text = ('Here:\n\n```nim\nimport std/unittest\nimport ' + imp + '\n\nsuite "utils":\n  test "twice doubles":\n'
                        '    check twicee(2) == 4\n```\n')
            finish = 'stop'
        elif 'This unit test fails:' in user and 'x * 3' in user:
            # (the first answer wrong when the test asks for a second try; right with the failure fed back)
            fix = 'x * 5' if ('second try' in user and 'Your previous answer was' not in user) else 'x * 2'
            text, finish = ('FILE: calc.nim\n<<<<<<< SEARCH\nproc twice*(x: int): int = x * 3\n=======\n'
                            'proc twice*(x: int): int = ' + fix + '\n>>>>>>> REPLACE\n'), 'stop'
        elif '<CURSOR>' in user and 'GHOSTGOOD' in user:
            text, finish = 'name.toUpperAscii', 'stop'          # (an inline suggestion that compiles)
        elif '<CURSOR>' in user and 'GHOSTBAD' in user:
            text, finish = 'name.toUpperFirst', 'stop'          # (one that names what does not exist)
        elif 'PELICAN' in user:
            text, finish = 'The attached resource says PELICAN.', 'stop'
        elif 'Write a proc' in user:
            text, finish = ('Here it is:\n\n```nim\nproc triple*(x: int): int =\n  ## three times x\n  x * 3\n```\n\nUse it anywhere.'), 'stop'
        elif 'Write statements' in user:
            text, finish = ('Add these:\n\n```nim\nlet z = 3\necho z\n```\n'), 'stop'
        elif 'Review this diff like a careful' in user:
            text, finish = ('{"file": "src/demo.nim", "line": 2, "severity": "warning", "message": "greet ignores empty names"}'), 'stop'
        elif 'Explain this file' in user:
            text, finish = ('`demo.nim` is the package entry point:\n\n- **greet** builds a greeting from a name.\n'
                            '- Under `when isMainModule` it creates a `Person`, greets them and prints `shout("done")` '
                            'from `demo/utils`.\n\n```nim\necho greet("Ann")   # Hello, Ann!\n```\n\n'
                            'Tip: `Person.age` is `Natural`, so negative ages are rejected at runtime.'), 'stop'
        else:
            text, finish = 'Hello from ' + m + '. You said: ' + user[-60:], 'stop'
        if not b.get('stream'):
            msg = {'role': 'assistant', 'content': text if not want_tool else None}
            if want_tool:
                msg['tool_calls'] = [{'id': 'call_1', 'type': 'function', 'function': {'name': 'list_files', 'arguments': '{"filter": ".nim"}'}}]
                finish = 'tool_calls'
            out = {'id': 'x', 'object': 'chat.completion', 'model': m,
                   'choices': [{'index': 0, 'message': msg, 'finish_reason': finish}],
                   'usage': {'prompt_tokens': 50, 'completion_tokens': 7, 'prompt_tokens_details': {'cached_tokens': 0}}}
            bb = json.dumps(out, indent=2).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(bb))); self.end_headers(); self.wfile.write(bb); return
        self.sse_start()
        if mcp_name:
            self.ev({'choices': [{'index': 0, 'delta': {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'call_m1', 'type': 'function', 'function': {'name': mcp_name, 'arguments': mcp_args}}]}}]})
            self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}]})
            self.ev('[DONE]'); return
        if want_gen:
            args = {'command': 'echo agent > fromagent.txt && echo generated'}
            self.ev({'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'Running it.'}}]})
            self.ev({'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'id': 'call_g1', 'type': 'function', 'function': {'name': 'run_command', 'arguments': json.dumps(args)}}]}}]})
            self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}]})
            self.ev('[DONE]'); return
        if want_cube:
            last = str(msgs[-1].get('content', '')) if has_tool_result(msgs) else ''
            if not has_tool_result(msgs):
                args, say = {'path': 'src/demo/utils.nim', 'old_text': '', 'new_text': 'proc cube*(x: int): int = x * x * y\n'}, 'Adding cube.'
            elif "undeclared identifier: 'y'" in last:
                args, say = {'path': 'src/demo/utils.nim', 'old_text': 'x * x * y', 'new_text': 'x * x * x'}, 'Fixing what the check found.'
            else:
                args, say = None, 'Done: `cube` is added' + (', and the check is clean.' if 'no errors]' in last else '.')
            self.ev({'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': say}}]})
            if args:
                self.ev({'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'id': 'call_c%d' % len(msgs), 'type': 'function', 'function': {'name': 'edit_file', 'arguments': json.dumps(args)}}]}}]})
                self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}]})
            else:
                self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})
            self.ev('[DONE]'); return
        if want_plan:
            # plan first (an edit tried while planning is refused), then each step its own run
            args = None
            if 'Plan this change before making it' in user or 'Change the plan' in user:
                if not has_tool_result(msgs) and 'Change the plan' not in user:
                    args, say = {'path': 'src/demo/utils.nim', 'old_text': '', 'new_text': '# sneaky\n'}, 'Let me just start.'
                else:
                    say = ('Here is the plan:\n\n1. Add `twice2` to src/demo/utils.nim\n   - a proc that doubles\n'
                           '2. Add `thrice2` to src/demo/utils.nim\n\nRisks: none.')
            elif 'Do step 1 of the plan' in user:
                if not has_tool_result(msgs):
                    args, say = {'path': 'src/demo/utils.nim', 'old_text': '', 'new_text': 'proc twice2*(x: int): int = x * 2\n'}, 'Step 1.'
                else: say = 'Added twice2.'
            elif 'Do step 2 of the plan' in user:
                if not has_tool_result(msgs):
                    args, say = {'path': 'src/demo/utils.nim', 'old_text': '', 'new_text': 'proc thrice2*(x: int): int = x * 3\n'}, 'Step 2.'
                else: say = 'Added thrice2.'
            else: say = 'Done.'
            self.ev({'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': say}}]})
            if args:
                self.ev({'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'id': 'call_p%d' % len(msgs), 'type': 'function', 'function': {'name': 'edit_file', 'arguments': json.dumps(args)}}]}}]})
                self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}]})
            else:
                self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})
            self.ev('[DONE]'); return
        if want_edit:
            args = json.dumps({'path': 'src/demo/utils.nim', 'old_text': 'proc shout*(s: string): string =\n',
                               'new_text': 'proc shout*(s: string): string =\n  ## `s` in capitals, followed by "!"\n  runnableExamples:\n    assert shout("hi") == "HI!"\n'})
            self.ev({'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'I will document `shout` and add a runnable example.'}}]})
            self.ev({'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'id': 'call_e1', 'type': 'function', 'function': {'name': 'edit_file', 'arguments': args}}]}}]})
            self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}]})
            self.ev('[DONE]'); return
        if want_tool:
            self.ev({'choices': [{'index': 0, 'delta': {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'call_1', 'type': 'function', 'function': {'name': 'list_files', 'arguments': ''}}]}}]})
            self.ev({'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': '{"filter": '}}]}}]})
            self.ev({'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': '".nim"}'}}]}}]})
            self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}]})
        else:
            for w in text.split(' ') if text else []:
                self.ev({'choices': [{'index': 0, 'delta': {'content': w + ' '}}]})
                time.sleep(0.01)
            self.ev({'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}]})
        if (b.get('stream_options') or {}).get('include_usage'):
            self.ev({'choices': [], 'usage': {'prompt_tokens': 1234, 'completion_tokens': 56, 'prompt_tokens_details': {'cached_tokens': 1000}}})
        self.ev('[DONE]')

    # ── OpenAI Responses API ──
    def resp_api(self, b):
        m = b.get('model', '')
        for bad in ('max_tokens', 'max_completion_tokens', 'messages'):
            if bad in b:
                return err(self, 400, "Unsupported parameter: '%s'. In the Responses API, this parameter has moved to 'max_output_tokens'." % bad if bad != 'messages' else "Unknown parameter: 'messages'.", bad)
        if reasoning(m) and 'temperature' in b:
            return err(self, 400, "Unsupported parameter: 'temperature' is not supported with this model.", 'temperature')
        items = b.get('input', [])
        user = ''
        for it in reversed(items):
            if it.get('role') == 'user':
                user = it.get('content') if isinstance(it.get('content'), str) else json.dumps(it.get('content')); break
        want_tool = 'list the files' in user and 'tools' in b and not has_tool_result(items)
        if has_tool_result(items):
            text = 'Responses tool said: ' + str(items[-1].get('output', ''))[:80].replace('\n', ' | ')
        else:
            text = 'Responses hello from ' + m + '. You said: ' + user[-60:]
        if not b.get('stream'):
            out = {'id': 'resp_1', 'object': 'response', 'status': 'completed', 'error': None, 'output': [
                       {'type': 'reasoning', 'id': 'rs_1', 'summary': []},
                       {'type': 'message', 'id': 'msg_1', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text}]}],
                   'usage': {'input_tokens': 40, 'output_tokens': 9, 'input_tokens_details': {'cached_tokens': 0}}}
            bb = json.dumps(out).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(bb))); self.end_headers(); self.wfile.write(bb); return
        self.sse_start()
        self.ev({'type': 'response.created', 'response': {'id': 'resp_1'}}, 'response.created')
        self.ev({'type': 'response.output_item.added', 'output_index': 0, 'item': {'type': 'reasoning', 'id': 'rs_1'}}, 'response.output_item.added')
        if want_tool:
            self.ev({'type': 'response.output_item.added', 'output_index': 1, 'item': {'type': 'function_call', 'id': 'fc_1', 'call_id': 'call_r1', 'name': 'list_files', 'arguments': ''}}, 'response.output_item.added')
            self.ev({'type': 'response.function_call_arguments.delta', 'output_index': 1, 'delta': '{"filter":'}, 'response.function_call_arguments.delta')
            self.ev({'type': 'response.function_call_arguments.delta', 'output_index': 1, 'delta': ' ".nim"}'}, 'response.function_call_arguments.delta')
            self.ev({'type': 'response.function_call_arguments.done', 'output_index': 1, 'arguments': '{"filter": ".nim"}'}, 'response.function_call_arguments.done')
        else:
            self.ev({'type': 'response.output_item.added', 'output_index': 1, 'item': {'type': 'message', 'id': 'msg_1'}}, 'response.output_item.added')
            for w in text.split(' '):
                self.ev({'type': 'response.output_text.delta', 'output_index': 1, 'delta': w + ' '}, 'response.output_text.delta')
        self.ev({'type': 'response.completed', 'response': {'usage': {'input_tokens': 321, 'output_tokens': 12, 'input_tokens_details': {'cached_tokens': 300}}}}, 'response.completed')

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()

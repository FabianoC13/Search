// What a tool attached to your Search must not see or do, checked against
// the bridge's port (run.sh). Usage: node safety.mjs <port> <private target id>
import http from 'node:http';
const [port, hidden] = [process.argv[2], process.argv[3]];
let failures = 0;
const check = (ok, what) => { console.log(ok ? 'ok  ' : 'FAIL', what); if (!ok) failures++; };

const get = (path, headers = {}) => new Promise(done => {
  http.get({ host: '127.0.0.1', port, path, headers }, response => {
    let body = ''; response.on('data', c => body += c); response.on('end', () => done({ status: response.statusCode, body }));
  }).on('error', e => done({ status: 0, body: String(e) }));
});

function connect(url, options) {
  const ws = new WebSocket(url, options);
  let next = 1; const waiting = new Map(); const events = [];
  ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } else events.push(m); };
  const send = (method, params = {}, sessionId) => new Promise(d => { const id = next++; waiting.set(id, d); ws.send(JSON.stringify({ id, method, params, sessionId })); });
  return new Promise((done, fail) => { ws.onopen = () => done({ ws, send, events }); ws.onerror = () => fail(new Error('refused')); });
}

const version = JSON.parse((await get('/json/version')).body);
check(!(await get('/json/list')).body.includes(hidden), '/json/list leaves the private tab out');
check((await get(`/json/activate/${hidden}`)).status === 404, '/json/activate of the private tab: 404');
check((await get(`/json/close/${hidden}`)).status === 404, '/json/close of the private tab: 404');
check((await get('/json/version', { Host: 'evil.example:9222' })).status === 403, 'a Host that is not loopback: 403');

const tool = await connect(version.webSocketDebuggerUrl);
const targets = (await tool.send('Target.getTargets')).result.targetInfos;
check(targets.length > 0 && !targets.some(t => t.targetId === hidden), 'Target.getTargets leaves the private tab out');
const attach = await tool.send('Target.attachToTarget', { targetId: hidden, flatten: true });
check(!!attach.error, 'Target.attachToTarget on the private tab: refused');
const info = await tool.send('Target.getTargetInfo', { targetId: hidden });
check(!!info.error, 'Target.getTargetInfo on the private tab: refused');
const closing = await tool.send('Target.closeTarget', { targetId: hidden });
check(!!closing.error, 'Target.closeTarget on the private tab: refused');
await tool.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
await new Promise(d => setTimeout(d, 500));
const attached = tool.events.filter(e => e.method === 'Target.attachedToTarget').map(e => e.params.targetInfo.targetId);
check(attached.length > 0 && !attached.includes(hidden), 'auto-attach never reaches the private tab');
await tool.send('Target.setDiscoverTargets', { discover: true });
await new Promise(d => setTimeout(d, 300));
check(!tool.events.some(e => e.method === 'Target.targetCreated' && e.params.targetInfo.targetId === hidden), 'discovery never names the private tab');
const crash = await tool.send('Browser.crash');
check(!!crash.error, 'Browser.crash: refused');

let refused = false;
try { await connect(`ws://127.0.0.1:${port}/devtools/page/${hidden}`); } catch { refused = true; }
check(refused, 'a WebSocket to the private tab: refused');
refused = false;
try { await connect(version.webSocketDebuggerUrl, { headers: { Origin: 'https://evil.example' } }); } catch { refused = true; }
check(refused, 'a WebSocket a web page opens (it has an Origin): refused');

const closed = new Promise(d => tool.ws.onclose = d);
await tool.send('Browser.close');
await closed;
check((await get('/json/version')).status === 200, 'Browser.close from a tool: your Search keeps running');
console.log(failures ? `${failures} failed` : 'all passed');
process.exit(failures ? 1 : 0);

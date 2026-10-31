const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');
const { PowerControl } = require('../../power-control');
const sec = require('../../security');
const discovery = require('../../discovery');
const { startHub } = require('../../server');

function temp(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test('inventory is bounded, retyped and distinguishes unavailable from empty', () => {
  assert.equal(sec.normalizeReport({}).peripherals, null);
  assert.deepEqual(sec.normalizeReport({ peripherals: [] }).peripherals, []);
  const r = sec.normalizeReport({ uptime: '42', peripherals: [null, { name: 'USB\u0000 keyboard', kind: 'Input', vendor: 'x'.repeat(500), secret: 'drop' }] });
  assert.equal(r.uptime, 42);
  assert.deepEqual(r.peripherals, [{ name: 'USB keyboard', kind: 'Input', vendor: 'x'.repeat(80) }]);
  assert.equal(sec.normalizeReport({ peripherals: Array(200).fill({ name: 'Mouse' }) }).peripherals.length, 128);
  assert.equal(sec.normalizeReport({ uptime: Infinity }).uptime, null);
});

test('power command binds device, action and expiry; results cannot cross devices', t => {
  const file = path.join(temp(t), 'audit.json'), c = new PowerControl(file);
  const cmd = c.queue('pc', 'shutdown', '127.0.0.1');
  assert.throws(() => c.queue('pc', 'shutdown', 'peer'), /pending/);
  assert.deepEqual(c.deliver('other', ['shutdown'], 'key'), []);
  assert.deepEqual(c.deliver('pc', [], 'key'), []);
  const [wire] = c.deliver('pc', ['shutdown'], 'key');
  const sig = crypto.createHmac('sha256', 'key').update(`device-monitor-cmd-v2:pc:${cmd.id}:shutdown:${cmd.expires}`).digest('hex');
  assert.equal(wire.sig, sig);
  assert.deepEqual(c.deliver('pc', ['shutdown'], 'key'), []);
  assert.equal(c.result('other', { id: cmd.id, ok: true }), false);
  assert.equal(c.result('pc', { id: cmd.id, ok: false, message: 'denied' }), true);
  assert.equal(c.result('pc', { id: cmd.id, ok: true }), false);
  assert.equal(JSON.parse(fs.readFileSync(file)).at(-1).status, 'failed');
});

test('expiry, restart and audit failure never silently requeue power', t => {
  const file = path.join(temp(t), 'audit.json'), c = new PowerControl(file);
  const cmd = c.queue('pc', 'shutdown', 'peer');
  cmd.expires = 0;
  assert.deepEqual(c.deliver('pc', ['shutdown'], 'key'), []);
  assert.equal(c.events.at(-1).status, 'expired');
  c.queue('pc', 'shutdown', 'peer');
  const restarted = new PowerControl(file);
  assert.equal(restarted.events.at(-1).status, 'interrupted');
  assert.deepEqual(restarted.deliver('pc', ['shutdown'], 'key'), []);
  restarted.queue('other', 'shutdown', 'peer');
  restarted.cancel('other');
  assert.deepEqual(restarted.deliver('other', ['shutdown'], 'key'), []);
  assert.equal(restarted.events.at(-1).status, 'cancelled');
  restarted.file = path.join(file, 'nonexistent');
  assert.throws(() => restarted.queue('pc', 'shutdown', 'peer'), /persist/);
  assert.equal(restarted.pending.size, 0);
});

test('Wake sends standard magic packets and rejects socket failures', async t => {
  const dgram = require('node:dgram');
  const original = dgram.createSocket;
  t.after(() => { dgram.createSocket = original; });
  let packets = [];
  class Socket extends EventEmitter {
    bind(cb) { cb(); }
    setBroadcast() {}
    close() {}
    send(packet, port, addr, cb) { packets.push({ packet, port, addr }); queueMicrotask(() => cb()); }
  }
  dgram.createSocket = () => new Socket();
  await discovery.wake(['aa:bb:cc:dd:ee:ff']);
  assert.ok(packets.length >= 2);
  assert.equal(packets[0].packet.length, 102);
  assert.equal(packets[0].packet.subarray(0, 6).toString('hex'), 'ffffffffffff');
  assert.equal(packets[0].packet.subarray(6).toString('hex'), 'aabbccddeeff'.repeat(16));
  await assert.rejects(discovery.wake([]), /Invalid/);
  dgram.createSocket = () => {
    const s = new Socket(); s.bind = () => queueMicrotask(() => s.emit('error', new Error('bind failed'))); return s;
  };
  await assert.rejects(discovery.wake(['aa:bb:cc:dd:ee:ff']), /bind failed/);
});

test('hub enforces authentication, origin, confirmation and local opt-in', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-hub-test-')), port = 20000 + Math.floor(Math.random() * 20000);
  const hub = await startHub({ port, dataDir: dir });
  t.after(() => { hub.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${port}`;
  async function request(url, body, headers = {}) {
    return fetch(base + url, { method: body === undefined ? 'GET' : 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
  }
  const auth = { Authorization: `Bearer ${hub.token}` };
  const report = { id: 'pc', token: hub.token, hostname: 'Test PC', uptime: 42, peripherals: [{ name: 'Keyboard' }], macs: ['aa:bb:cc:dd:ee:ff'], actions: [] };
  assert.equal((await request('/api/report', report)).status, 200);
  assert.equal((await request('/api/power/log')).status, 401);
  const url = '/api/devices/pc/action';
  assert.equal((await request(url, { action: 'shutdown', confirmedDevice: 'pc' })).status, 401);
  assert.equal((await request(url, { action: 'shutdown', confirmedDevice: 'pc' }, { ...auth, Origin: 'https://evil.example' })).status, 403);
  assert.equal((await request(url, { action: 'shutdown' }, auth)).status, 400);
  assert.equal((await request(url, { action: 'shutdown', confirmedDevice: 'other' }, auth)).status, 400);
  assert.equal((await request(url, { action: 'shutdown', confirmedDevice: 'pc' }, auth)).status, 409);
  report.actions = ['shutdown'];
  await request('/api/report', report);
  const queued = await request(url, { action: 'shutdown', confirmedDevice: 'pc' }, auth);
  assert.equal(queued.status, 200);
  const { id } = await queued.json();
  const reply = await (await request('/api/report', report)).json();
  assert.equal(reply.commands[0].id, id);
  report.actionResult = { id, ok: false, message: 'OS denied' };
  await request('/api/report', report);
  const events = await (await request('/api/power/log', undefined, auth)).json();
  assert.equal(events.at(-1).status, 'failed');
  assert.ok(!JSON.stringify(events).includes(hub.token));
  const devices = await (await request('/api/devices', undefined, auth)).json();
  assert.ok(JSON.stringify(devices).includes('Keyboard'));
});

test('dashboard scripts parse', () => {
  const html = fs.readFileSync(path.join(__dirname, '../../public/index.html'), 'utf8');
  for (const m of html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)) new vm.Script(m[1]);
});

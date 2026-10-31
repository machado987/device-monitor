const crypto = require('crypto');
const { readJson, writeJson } = require('./safe-json');

// Bounded, durable audit trail. Shared-key authentication identifies a peer, not a person.
class PowerControl {
  constructor(file) {
    this.file = file;
    const saved = readJson(file, []);
    this.events = Array.isArray(saved) ? saved.slice(-500) : [];
    this.pending = new Map();
    const last = new Map(this.events.filter(e => e.id).map(e => [e.id, e]));
    for (const e of last.values()) if (['queued', 'delivered'].includes(e.status))
      this.record({ id: e.id, device: e.device, action: e.action, status: 'interrupted' });
  }
  record(event) {
    const next = [...this.events, { ...event, at: Date.now() }].slice(-500);
    if (!writeJson(this.file, next)) throw new Error('Unable to persist power audit log');
    this.events = next;
  }
  queue(device, action, peer) {
    if ([...this.pending.values()].some(c => c.device === device && c.expires > Date.now()))
      throw new Error('A power command is already pending for this device');
    const cmd = { id: crypto.randomBytes(6).toString('hex'), device, action, expires: Date.now() + 60000, peer, delivered: false };
    this.record({ ...cmd, status: 'queued' });
    this.pending.set(cmd.id, cmd);
    return cmd;
  }
  deliver(device, actions, token) {
    this.expire();
    const out = [];
    for (const c of this.pending.values()) {
      if (c.device !== device || c.delivered || !actions.includes(c.action)) continue;
      this.record({ id: c.id, device, action: c.action, status: 'delivered' });
      c.delivered = true;
      const { id, action, expires } = c;
      const sig = crypto.createHmac('sha256', String(token)).update(`device-monitor-cmd-v2:${device}:${id}:${action}:${expires}`).digest('hex');
      out.push({ id, action, expires, sig });
    }
    return out;
  }
  result(device, result) {
    const c = this.pending.get(result.id);
    if (!c || c.device !== device || !c.delivered || c.expires <= Date.now()) return false;
    this.record({ id: c.id, device, action: c.action, status: result.ok ? 'accepted' : 'failed', message: result.message });
    this.pending.delete(c.id);
    return true;
  }
  expire() {
    for (const c of this.pending.values()) if (c.expires <= Date.now()) {
      this.record({ id: c.id, device: c.device, action: c.action, status: c.delivered ? 'unconfirmed' : 'expired' });
      this.pending.delete(c.id);
    }
  }
  cancel(device) {
    for (const c of this.pending.values()) if (c.device === device) {
      this.record({ id: c.id, device, action: c.action, status: 'cancelled' });
      this.pending.delete(c.id);
    }
  }
}
module.exports = { PowerControl };

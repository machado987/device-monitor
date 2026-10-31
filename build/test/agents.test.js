const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
test('Linux/macOS handler rejects tampering and replay (OS commands mocked)', () => {
  const r = spawnSync(process.platform === 'win32' ? 'python' : 'python3', [path.join(__dirname, 'agent-power.py')], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr || r.error?.message);
});
test('Windows handler rejects tampering and replay (OS command mocked)', { skip: process.platform !== 'win32' }, () => {
  const r = spawnSync('powershell.exe', ['-NoProfile', '-File', path.join(__dirname, 'agent-power.ps1')], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr || r.error?.message);
});
test('shell agent syntax', { skip: process.platform === 'win32' }, () => {
  for (const file of ['agent.sh', 'agent-macos.sh']) {
    const r = spawnSync('/bin/bash', ['-n', path.join(__dirname, '../../agent', file)], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
  }
});

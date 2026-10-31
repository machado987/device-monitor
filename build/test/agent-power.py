"""Exercise the exact embedded agent handler with all OS commands mocked."""
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
def embedded(file):
    return (ROOT / 'agent' / file).read_text().split("<<'DM_PY'\n", 1)[1].split('\nDM_PY', 1)[0]

class AgentPower(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = patch.dict(os.environ, TOKEN='secret', DM_DEVICE_ID='pc', DM_ALLOW_SHUTDOWN='1')
        self.env.start(); self.addCleanup(self.env.stop)
        self.home = patch.object(Path, 'home', return_value=Path(self.tmp.name))
        self.home.start(); self.addCleanup(self.home.stop)
        self.ns = {}
        exec(embedded('agent.sh').split('\ntry:\n    if sys.argv', 1)[0], self.ns)
        # Every test installs the mock before invoking any command handler.
        self.run = patch('subprocess.run').start()
        self.addCleanup(patch.stopall)
        self.run.return_value.returncode = 0

    def cmd(self, **changes):
        c = dict(id='aabbccddeeff', action='shutdown', expires=int(time.time()*1000)+55000)
        c.update(changes)
        message = f"device-monitor-cmd-v2:pc:{c['id']}:{c['action']}:{c['expires']}"
        c['sig'] = hmac.new(b'secret', message.encode(), hashlib.sha256).hexdigest()
        return c

    def execute(self, c):
        return self.ns['execute']({'commands': [c]})

    def test_agents_share_identical_handler(self):
        self.assertEqual(embedded('agent.sh'), embedded('agent-macos.sh'))

    def test_opt_in_signature_target_expiry_and_action(self):
        c = self.cmd()
        os.environ['DM_ALLOW_SHUTDOWN'] = '0'
        self.assertIsNone(self.execute(c))
        os.environ['DM_ALLOW_SHUTDOWN'] = '1'
        for invalid in [dict(c, sig='bad'), self.cmd(expires=0), self.cmd(action='restart'), self.cmd(expires=int(time.time()*1000)+120000)]:
            self.assertIsNone(self.execute(invalid))
        os.environ['DM_DEVICE_ID'] = 'other'
        self.assertIsNone(self.execute(c))
        self.run.assert_not_called()

    def test_valid_command_is_not_replayed_after_handler_restart(self):
        c = self.cmd()
        with patch.object(sys, 'platform', 'linux'):
            self.assertTrue(self.execute(c)['ok'])
        self.run.assert_called_once_with(['/usr/bin/systemctl', '--no-ask-password', 'poweroff'], capture_output=True, timeout=10)
        fresh = {}
        exec(embedded('agent.sh').split('\ntry:\n    if sys.argv', 1)[0], fresh)
        self.assertIsNone(fresh['execute']({'commands': [c]}))
        self.assertEqual(self.run.call_count, 1)

    def test_macos_permission_failure_is_reported(self):
        self.run.return_value.returncode = 1
        with patch.object(sys, 'platform', 'darwin'):
            result = self.execute(self.cmd())
        self.assertFalse(result['ok'])
        self.assertIn('denied', result['message'])
        self.assertEqual(self.run.call_args.args[0], ['/sbin/shutdown', '-h', '+1'])

    def test_malformed_replay_ledger_fails_closed(self):
        folder = Path(self.tmp.name)/'.device-monitor'; folder.mkdir()
        (folder/'power-seen.json').write_text('broken')
        self.assertFalse(self.execute(self.cmd())['ok'])
        self.run.assert_not_called()

    def test_macos_usb_inventory_has_no_serial_numbers(self):
        self.run.return_value.stdout = json.dumps({'SPUSBDataType': [{'_name': 'Bus', '_items': [{'_name':'Keyboard','vendor_id':'123','serial_num':'private'}]}]})
        # Separate profiler and ifconfig replies.
        from types import SimpleNamespace
        self.run.side_effect = [SimpleNamespace(returncode=0, stdout=self.run.return_value.stdout), SimpleNamespace(returncode=0, stdout='ether aa:bb:cc:dd:ee:ff')]
        with patch.object(sys, 'platform', 'darwin'):
            inventory = self.ns['collect']()
        self.assertEqual(inventory['peripherals'], [{'name':'Keyboard','kind':'USB','vendor':None}])
        self.assertEqual(inventory['macs'], ['aa:bb:cc:dd:ee:ff'])

if __name__ == '__main__': unittest.main()

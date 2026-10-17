import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('watcher',Path(__file__).with_name('watch_passenger_backend.py'))
watcher=importlib.util.module_from_spec(spec)
spec.loader.exec_module(watcher)


class WatcherTests(unittest.TestCase):
    def test_live_configuration_and_environment_precedence(self):
        with tempfile.TemporaryDirectory(prefix='yangi-passenger-watcher-') as directory:
            root=Path(directory)
            (root/'server.mjs').write_text('// isolated configuration test')
            (root/'.env').write_text('PORT=8788\nTM_API_MOCK=false\nSESSION_SECRET=test-only-placeholder\n')
            with patch.dict(watcher.os.environ,{'TM_API_MOCK':'true'}):
                self.assertEqual(watcher.configuration(root)['TM_API_MOCK'],'false')
            (root/'.env').write_text('PORT=8788\nTM_API_MOCK=true\n')
            with self.assertRaises(ValueError):watcher.configuration(root)

    def test_free_port_and_dead_worker_allow_restart_but_live_worker_blocks_it(self):
        with tempfile.TemporaryDirectory(prefix='yangi-passenger-watcher-') as directory:
            root=Path(directory);(root/'data').mkdir()
            (root/'data/settlement-worker.lock').write_text('{"pid":12345}')
            with patch.object(watcher.socket,'create_connection',side_effect=OSError),patch.object(watcher,'process_alive',return_value=True):
                self.assertFalse(watcher.state(root)['may_start'])
            with patch.object(watcher.socket,'create_connection',side_effect=OSError),patch.object(watcher,'process_alive',return_value=False):
                self.assertTrue(watcher.state(root)['may_start'])
            for invalid in ('invalid lock','{"pid":0}'):
                (root/'data/settlement-worker.lock').write_text(invalid)
                with patch.object(watcher.socket,'create_connection',side_effect=OSError):
                    self.assertFalse(watcher.state(root)['may_start'])

    def test_unhealthy_existing_listener_is_never_replaced(self):
        with tempfile.TemporaryDirectory(prefix='yangi-passenger-watcher-') as directory:
            with patch.object(watcher.socket,'create_connection'),patch.object(watcher.urllib.request,'urlopen',side_effect=OSError):
                result=watcher.state(Path(directory))
                self.assertFalse(result['healthy']);self.assertFalse(result['may_start'])


if __name__=='__main__':unittest.main()

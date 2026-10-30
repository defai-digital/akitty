import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('r2-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class DistributionTests(unittest.TestCase):
    def test_github_digest_and_publication_are_required(self):
        data = b'signed archive'
        row = {'tag_name': 'v0.6.0', 'draft': False, 'prerelease': False,
               'assets': [{'name': 'app.zip', 'size': len(data), 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}]}
        release.validate_assets(row, 'v0.6.0', {'app.zip': data})
        with self.assertRaises(RuntimeError):
            release.validate_assets(row, 'v0.6.0', {'app.zip': b'tampered'})
        row['draft'] = True
        with self.assertRaises(RuntimeError):
            release.validate_assets(row, 'v0.6.0', {'app.zip': data})

    def test_immutable_bytes_cannot_be_overwritten(self):
        class Store:
            def storage(self, key, data=None):
                if data is not None:
                    raise AssertionError('must not upload')
                return b'old'
        with self.assertRaises(RuntimeError):
            release.put_verified(Store(), 'releases/download/v0.6.0/app.zip', b'new')

    def test_public_readback_failure_is_not_success(self):
        class Store:
            value = None
            def storage(self, key, data=None):
                if data is not None:
                    self.value = data
                return self.value
        with patch.object(release, 'public', return_value=b'wrong'):
            with self.assertRaises(RuntimeError):
                release.put_verified(Store(), 'appcast.xml', b'feed', mutable=True)


if __name__ == '__main__':
    unittest.main()

"""Parse real Go fixtures without loading dependencies or applying build tags."""
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Scripts/upstream-api.go'


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.environment = dict(os.environ, GO111MODULE='off', GOCACHE=str(pathlib.Path(tempfile.gettempdir()) / 'swift-tailcat-round4-parser-cache'),
                                 GOPROXY='off', GOTOOLCHAIN='local', GOWORK='off')

    def parse(self, root):
        return subprocess.run(['go', 'run', str(HELPER), str(root)], env=self.environment,
                              text=True, capture_output=True)

    def test_root_exported_functions_and_methods_across_build_tags(self):
        (self.root / 'api.go').write_text('''package tailcat
// func Bogus() {}
var text = "func BogusString() {}"
type Server struct{}
func private() {}
func Exported[T any](value T) T { return value }
func (server *Server) Method(
    value func() struct{ Name string },
) (result interface{ Call() }) { return nil }
type privateServer struct{}
func (server *privateServer) HiddenReceiver() {}
type Generic[T any] struct{}
func (server Generic[T]) GenericMethod() {}
''')
        (self.root / 'js.go').write_text('//go:build js\n\npackage tailcat\nfunc JSOnly() {}\n')
        (self.root / 'api_test.go').write_text('package tailcat\nfunc TestExcluded() {}\n')
        (self.root / 'internal').mkdir()
        (self.root / 'internal/api.go').write_text('package internal\nfunc NestedExcluded() {}\n')
        result = self.parse(self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [
            {'file': 'api.go', 'line': 6, 'signature': 'func Exported[T any](value T) T'},
            {'file': 'api.go', 'line': 7, 'signature': 'func (server *Server) Method(\n    value func() struct{ Name string },\n) (result interface{ Call() })'},
            {'file': 'api.go', 'line': 13, 'signature': 'func (server Generic[T]) GenericMethod()'},
            {'file': 'js.go', 'line': 4, 'signature': 'func JSOnly()'},
        ])
        self.assertEqual(result.stdout, self.parse(self.root).stdout)

    def test_empty_package_inventory_is_an_array(self):
        (self.root / 'api.go').write_text('package tailcat\nfunc hidden() {}\n')
        result = self.parse(self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])

    def test_malformed_source_fails_without_partial_inventory(self):
        (self.root / 'a.go').write_text('package tailcat\nfunc Valid() {}\n')
        (self.root / 'b.go').write_text('package tailcat\nfunc Broken(\n')
        result = self.parse(self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('b.go', result.stderr)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("pwa_build", Path(__file__).resolve().parents[1] / "tool" / "build_pwa.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

class PwaBuildTests(unittest.TestCase):
    def test_unknown_environment_keys_cannot_enter_public_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text("URL=https://erp.test/api/method/itgenie.api_utils\nSITE_URL=https://erp.test/\nAPI_SECRET=private\n")
            with self.assertRaisesRegex(ValueError, "not approved"):
                build.public_environment(path)

    def test_release_hash_changes_with_assets_and_excludes_private_models(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "assets/assets/face_recognition").mkdir(parents=True)
            (root / "assets/assets/face_recognition/model.onnx").write_bytes(b"model")
            (root / "index.html").write_text("index")
            (root / "main.dart.js").write_text("first")
            env = {"URL": "https://erp.test/api/method/itgenie.api_utils", "SITE_URL": "https://erp.test/"}
            first, _ = build.prepare_release(root, env)
            assets = (root / "pwa-assets.js").read_text()
            self.assertNotIn("model.onnx", assets)
            self.assertIn("main.dart.js", assets)
            self.assertIn('"firebase": null', (root / "pwa-config.js").read_text())
            (root / "main.dart.js").write_text("second")
            second, _ = build.prepare_release(root, env)
            self.assertNotEqual(first, second)
            self.assertEqual(second, build.prepare_release(root, env)[0])

if __name__ == "__main__":
    unittest.main()

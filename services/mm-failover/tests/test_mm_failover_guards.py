"""services/mm-failover 的单元测试（python3 -m unittest，无外部依赖，不触网）。

覆盖 mm_failover.py 的纯函数护栏（W-14 D-02 补骨架）：
  _check_bind（通配地址拒绝）、_is_loopback、_shared_mode、
  _allowed_paths、模型族判定（minimax / grok / claude）、_model_of、_classify。
跑法：
    python3 -m unittest discover -s services/mm-failover/tests -v
"""
import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SVC = os.path.dirname(_HERE)
_spec = importlib.util.spec_from_file_location(
    "mm_failover_under_test", os.path.join(_SVC, "mm_failover.py"))
mm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mm)


class _EnvCase(unittest.TestCase):
    """改 env / 模块全局的用例：用完必还原。"""

    def setUp(self):
        self._saved_env = {k: os.environ.get(k) for k in (
            "MM_FAILOVER_SHARED_MODE", "MM_FAILOVER_ALLOWED_PATHS")}
        self._saved_host = mm.LISTEN_HOST

    def tearDown(self):
        for k, v in self._saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        mm.LISTEN_HOST = self._saved_host

    def _set_host_mode(self, host, mode="auto"):
        mm.LISTEN_HOST = host
        os.environ["MM_FAILOVER_SHARED_MODE"] = mode


class TestCheckBind(unittest.TestCase):
    def test_refuses_wildcards(self):
        for h in ("", "0.0.0.0", "*", "::", "[::]"):
            with self.subTest(host=h):
                self.assertIsNotNone(mm._check_bind(h))

    def test_allows_specific_addresses(self):
        for h in ("127.0.0.1", "100.76.189.39", "localhost"):
            with self.subTest(host=h):
                self.assertIsNone(mm._check_bind(h))


class TestIsLoopback(unittest.TestCase):
    def test_loopback(self):
        for h in ("127.0.0.1", "localhost", "::1"):
            with self.subTest(host=h):
                self.assertTrue(mm._is_loopback(h))

    def test_not_loopback(self):
        for h in ("100.76.189.39", "8.8.8.8", "0.0.0.0", "", "not-an-ip"):
            with self.subTest(host=h):
                self.assertFalse(mm._is_loopback(h))


class TestSharedMode(_EnvCase):
    def test_explicit_on_off(self):
        mm.LISTEN_HOST = "127.0.0.1"
        os.environ["MM_FAILOVER_SHARED_MODE"] = "1"
        self.assertTrue(mm._shared_mode())
        os.environ["MM_FAILOVER_SHARED_MODE"] = "0"
        self.assertFalse(mm._shared_mode())

    def test_auto_follows_bind_address(self):
        self._set_host_mode("127.0.0.1")
        self.assertFalse(mm._shared_mode())
        self._set_host_mode("100.76.189.39")
        self.assertTrue(mm._shared_mode())


class TestAllowedPaths(_EnvCase):
    def test_loopback_allows_all(self):
        self._set_host_mode("127.0.0.1")
        os.environ.pop("MM_FAILOVER_ALLOWED_PATHS", None)
        self.assertIsNone(mm._allowed_paths())

    def test_shared_allows_only_whitelist(self):
        self._set_host_mode("100.76.189.39")
        os.environ.pop("MM_FAILOVER_ALLOWED_PATHS", None)
        self.assertEqual(mm._allowed_paths(), {"/v1/chat/completions", "/healthz"})

    def test_env_override(self):
        self._set_host_mode("127.0.0.1")
        os.environ["MM_FAILOVER_ALLOWED_PATHS"] = "/a,/b"
        self.assertEqual(mm._allowed_paths(), {"/a", "/b"})


class TestModelFamilies(unittest.TestCase):
    def test_minimax(self):
        self.assertTrue(mm._is_minimax_model("MiniMax-M3.1-Flash-Preview"))
        self.assertTrue(mm._is_minimax_model("minimax-x"))
        self.assertFalse(mm._is_minimax_model("grok-4.7"))
        self.assertFalse(mm._is_minimax_model(""))
        self.assertFalse(mm._is_minimax_model(None))

    def test_grok(self):
        self.assertTrue(mm._is_grok_model("grok-4.7"))
        self.assertTrue(mm._is_grok_model("GROK-x"))
        self.assertFalse(mm._is_grok_model("minimax-x"))
        self.assertFalse(mm._is_grok_model(None))

    def test_claude(self):
        self.assertTrue(mm._is_claude_model("claude-opus-5-5"))
        self.assertTrue(mm._is_claude_model("c-o-5-5"))  # 实测别名
        self.assertTrue(mm._is_claude_model("c-s-5-5"))
        self.assertFalse(mm._is_claude_model("c-x"))
        self.assertFalse(mm._is_claude_model("grok-4.7"))
        self.assertFalse(mm._is_claude_model(""))

    def test_fallback_model(self):
        self.assertEqual(mm.BAOSI_FALLBACK_MODEL, "grok-4.7")

    def test_model_of(self):
        self.assertEqual(mm._model_of('{"model": "grok-4.7"}'), "grok-4.7")
        self.assertIsNone(mm._model_of('{"no": 1}'))
        self.assertIsNone(mm._model_of('{"model": 123}'))
        self.assertIsNone(mm._model_of('not json'))

    def test_classify(self):
        self.assertEqual(mm._classify(b"missing required parameter"), "req")
        self.assertEqual(mm._classify(b"Error: unknown model xyz"), "leg")
        self.assertIsNone(mm._classify(b"hello world"))
        self.assertIsNone(mm._classify(b"\xff\xfe invalid"))


if __name__ == "__main__":
    unittest.main()

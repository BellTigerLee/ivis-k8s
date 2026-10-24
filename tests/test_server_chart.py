import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

from test_charts import ROOT, render


CHART = ROOT / "charts/ivis-server"


class ServerChartTest(unittest.TestCase):
    def test_plain_job_and_deployment(self):
        docs = render(CHART, namespace="ivis-observer")
        by_kind = {doc["kind"]: doc for doc in docs}
        self.assertIn("Job", by_kind)
        self.assertIn("Deployment", by_kind)
        self.assertNotIn("Secret", by_kind)
        self.assertNotIn("Namespace", by_kind)
        deployment = by_kind["Deployment"]["spec"]
        self.assertEqual(deployment["replicas"], 1)
        self.assertEqual(deployment["strategy"], {"type": "Recreate"})
        self.assertNotIn("initContainers", deployment["template"]["spec"])
        job = by_kind["Job"]
        self.assertNotIn("helm.sh/hook", job["metadata"].get("annotations", {}))
        self.assertNotIn("ttlSecondsAfterFinished", job["spec"])
        self.assertFalse(job["spec"]["template"]["spec"]["automountServiceAccountToken"])

    def test_namespace_identity_credentials_and_security(self):
        values = {
            "name": "custom-server",
            "postgres": {"credentials": {"existingSecret": "my-pg", "dsnKey": "connection"}},
            "clickhouse": {"credentials": {"existingSecret": "my-ch", "usernameKey": "login", "passwordKey": "token"}},
        }
        for namespace in ("ivis-observer", "another-observer"):
            docs = render(CHART, values=values, namespace=namespace)
            by_kind = {d["kind"]: d for d in docs}
            for doc in docs:
                if doc["kind"] not in ("ClusterRole", "ClusterRoleBinding"):
                    self.assertEqual(doc["metadata"]["namespace"], namespace)
            binding = by_kind["ClusterRoleBinding"]
            self.assertEqual(binding["subjects"], [{"kind": "ServiceAccount", "name": "custom-server", "namespace": namespace}])
            self.assertEqual(binding["roleRef"]["name"], by_kind["ClusterRole"]["metadata"]["name"])
            self.assertEqual({v for rule in by_kind["ClusterRole"]["rules"] for v in rule["verbs"]}, {"list"})
            for kind in ("Job", "Deployment"):
                pod = by_kind[kind]["spec"]["template"]["spec"]
                volumes = {v["name"]: v for v in pod["volumes"]}
                self.assertEqual(volumes["postgres"]["secret"]["secretName"], "my-pg")
                self.assertEqual(volumes["postgres"]["secret"]["items"], [{"key": "connection", "path": "dsn"}])
                self.assertEqual(volumes["clickhouse"]["secret"]["items"], [{"key": "login", "path": "username"}, {"key": "token", "path": "password"}])
                self.assertEqual(volumes["tmp"]["emptyDir"], {"sizeLimit": "64Mi"})
                self.assertTrue(pod["securityContext"]["runAsNonRoot"])
                self.assertEqual(pod["securityContext"]["seccompProfile"], {"type": "RuntimeDefault"})
                container = pod["containers"][0]
                self.assertEqual(container["image"], "belltigerlee/ivis-server:0.4.0")
                self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
                self.assertEqual(container["securityContext"]["capabilities"], {"drop": ["ALL"]})
                self.assertNotIn("initContainers", pod)
            self.assertEqual(by_kind["Service"]["spec"]["selector"], by_kind["Deployment"]["spec"]["selector"]["matchLabels"])

    def test_options_job_identity_examples_and_digest(self):
        first = {d["kind"]: d for d in render(CHART)}
        changed = {d["kind"]: d for d in render(CHART, values={"schemaJob": {"revision": "rerun-2"}})}
        self.assertNotEqual(first["Job"]["metadata"]["name"], changed["Job"]["metadata"]["name"])
        self.assertEqual(first["Job"]["metadata"]["name"], {d["kind"]: d for d in render(CHART)}["Job"]["metadata"]["name"])
        docs = render(CHART, values={"schemaJob": {"enabled": False}})
        self.assertNotIn("Job", {d["kind"] for d in docs})
        self.assertFalse(any(d["kind"] == "ConfigMap" and "pg-001-core.sql" in d["data"] for d in docs))
        digest = "sha256:" + "1" * 64
        for doc in render(CHART, values={"image": {"digest": digest}}):
            if doc["kind"] in ("Job", "Deployment"):
                self.assertEqual(doc["spec"]["template"]["spec"]["containers"][0]["image"], "belltigerlee/ivis-server@" + digest)
        examples = sorted((ROOT / "examples/ivis-server").glob("*.yaml"))
        self.assertTrue(examples)
        for example in examples:
            with self.subTest(example=example.name):
                render(CHART, values=yaml.safe_load(example.read_text()))
        docs = render(CHART, values={"postgres": {"credentials": {"mode": "userPassword", "usernameKey": "login", "passwordKey": "pass"}}})
        pod = next(d for d in docs if d["kind"] == "Deployment")["spec"]["template"]["spec"]
        pg = next(v for v in pod["volumes"] if v["name"] == "postgres")
        self.assertEqual(pg["secret"]["items"], [{"key": "login", "path": "username"}, {"key": "pass", "path": "password"}])

    def test_invalid_values_rejected(self):
        cases = (
            "image.digest=invalid", "postgres.credentials.password=plaintext",
            "postgres.database=bad-name", "clickhouse.url=http://user:password@host:8123",
            "clickhouse.signalsDatabase=system", "inventory.intervalSeconds=1",
            "kumec.enabled=true,inventory.enabled=false", "signals.pendingRows=1",
            "signals.topicAdapters.unknown=otlp-logs/protobuf", "signals.jsonBackend=orjson",
            "image.repository=INVALID IMAGE", "schemaJob.activeDeadlineSeconds=0",
        )
        for value in cases:
            with self.subTest(value=value):
                result = subprocess.run(["helm", "template", "verify", str(CHART), "--set", value],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)

    def test_packaged_payload_sizes_and_ddl(self):
        docs = render(CHART)
        maps = {d["metadata"]["name"]: d["data"] for d in docs if d["kind"] == "ConfigMap"}
        for data in maps.values():
            self.assertLess(sum(len(v.encode()) for v in data.values()), 900000)
        self.assertEqual(set(maps["ivis-server-sql"]), {
            "pg-001-core.sql", "pg-002-seed.sql", "pg-003-execution.sql", "pg-004-kumec-signals.sql",
            "ch-ivis_kumec_history.sql", "ch-ivis_signal_event.sql", "ch-ivis_signal_sample.sql",
        })
        self.assertEqual(set(maps["ivis-server-runtime"]), {"credentials.py", "schema.py", "runner.py"})
        sql = "\n".join(maps["ivis-server-sql"].values())
        self.assertNotRegex(sql, r"(?im)^\s*(DROP|TRUNCATE|CREATE USER|CREATE ROLE|ALTER ROLE)\b")
        self.assertIn("value` Int128", sql)
        self.assertIn("public.ivis_begin_execution", sql)
        self.assertIn("ivis_signal.task_current", sql)
        self.assertIn("ivis_kumec.placement", sql)


class RunnerCliTest(unittest.TestCase):
    def test_missing_credentials_fails_without_traceback_or_values(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(CHART / "files/runner.py"), "schema"],
                env={"PATH": os.defpath, "IVIS_HELM_CREDENTIAL_ROOT": directory},
                capture_output=True, text=True, timeout=10,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.strip(), "ivis schema: credentials_unavailable")

    def test_postgres_transaction_preserves_function_body(self):
        sys.path.insert(0, str(CHART / "files"))
        try:
            from credentials import Credentials
            from schema import prepare_postgres, SchemaError
            driver = mock.MagicMock()
            class DatabaseFailure(RuntimeError):
                sqlstate = "42501"
            driver.Error = DatabaseFailure
            connection = driver.connect.return_value.__enter__.return_value
            with mock.patch.dict(sys.modules, {"psycopg": driver}), mock.patch.dict(
                os.environ, {"IVIS_INVENTORY_ENABLED": "1", "IVIS_SIGNALS_ENABLED": "1"}, clear=True
            ):
                prepare_postgres(CHART / "files/sql", Credentials("synthetic-dsn", "synthetic-user", "synthetic-password"))
                queries = [c.args[0] for c in connection.execute.call_args_list]
                functions = [q for q in queries if "CREATE OR REPLACE FUNCTION" in q]
                self.assertEqual(len(functions), 1)
                self.assertIn("RETURN run_name;", functions[0])
                self.assertIn("END;\n$$;", functions[0])
                self.assertFalse(any(q.strip() == "COMMIT;" for q in queries))
                self.assertEqual(connection.transaction.call_count, 1)
                connection.execute.side_effect = DatabaseFailure("synthetic-password and server details")
                with self.assertRaisesRegex(SchemaError, "^postgres_failed_42501$"):
                    prepare_postgres(CHART / "files/sql", Credentials("synthetic-dsn", "synthetic-user", "synthetic-password"))
        finally:
            sys.path.pop(0)


if __name__ == "__main__":
    unittest.main()

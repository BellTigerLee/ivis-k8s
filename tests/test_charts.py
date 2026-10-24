"""Offline Helm distribution contracts; no cluster access or BPF attachment."""
import itertools
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
from typing import Any
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/ivis-node-agent"
MODULES = ("process", "cpu", "syscall")
SCRATCH = Path(os.environ.get("TMPDIR", Path.home() / ".cache/ivis-k8s-tests"))
SCRATCH.mkdir(parents=True, exist_ok=True)


class UniqueLoader(yaml.SafeLoader):
    """Reject duplicate mapping keys that ordinary YAML loaders hide."""


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping
)


def run(*args, **kwargs):
    return subprocess.run(
        args, check=True, capture_output=True, text=True, timeout=60, **kwargs
    )


def render(chart=CHART, values=None, namespace="ivis-validation", release="verify"):
    with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
        args = ["helm", "template", release, str(chart), "--namespace", namespace]
        if values is not None:
            path = Path(directory) / "override.yaml"
            path.write_text(yaml.safe_dump(values))
            args += ["--values", str(path)]
        output = run(*args).stdout
    return [doc for doc in yaml.load_all(output, Loader=UniqueLoader) if doc]


def objects(docs):
    return {doc["kind"]: doc for doc in docs}


def config(docs):
    return yaml.load(
        objects(docs)["ConfigMap"]["data"]["agent.yaml"], Loader=UniqueLoader
    )


def pod(docs):
    return objects(docs)["DaemonSet"]["spec"]["template"]["spec"]


def selection(bits):
    return {"modules": {name: {"enabled": bit} for name, bit in zip(MODULES, bits)}}


class ChartCatalogTest(unittest.TestCase):
    def test_all_charts_lint_standalone_and_package(self):
        charts = sorted(ROOT.glob("charts/*/Chart.yaml"))
        self.assertTrue(charts, "no installable charts")
        names = set()
        for metadata in charts:
            with self.subTest(chart=metadata.parent.name):
                chart = metadata.parent
                info = yaml.safe_load(metadata.read_text())
                self.assertEqual(info["name"], chart.name)
                self.assertNotIn(info["name"], names)
                names.add(info["name"])
                for filename in ("values.yaml", "values.schema.json", "README.md", "LICENSE"):
                    self.assertTrue((chart / filename).is_file(), filename)
                self.assertFalse(info.get("dependencies"), "keep charts independent")
                self.assertFalse(any(path.is_symlink() for path in chart.rglob("*")))
                run("helm", "lint", str(chart), "--strict")
                baseline = render(chart)
                identities = [
                    (d["apiVersion"], d["kind"], d["metadata"].get("namespace"), d["metadata"]["name"])
                    for d in baseline
                ]
                self.assertEqual(len(identities), len(set(identities)))
                with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                    copied = Path(directory) / chart.name
                    shutil.copytree(chart, copied)
                    self.assertEqual(render(copied), baseline)
                    run("helm", "package", str(copied), "--destination", directory)
                    archives = list(Path(directory).glob("*.tgz"))
                    self.assertEqual(len(archives), 1)
                    self.assertEqual(render(archives[0]), baseline)
                    with tarfile.open(archives[0]) as archive:
                        license_file = archive.extractfile(f"{chart.name}/LICENSE")
                        assert license_file is not None
                        packaged = license_file.read()
                        self.assertEqual(packaged, (chart / "LICENSE").read_bytes())
                        self.assertFalse(any("/dev/" in n or "/.git/" in n for n in archive.getnames()))


class NodeAgentTest(unittest.TestCase):
    def test_default_scope_and_image(self):
        docs = render()
        self.assertEqual(
            set(objects(docs)),
            {"ConfigMap", "DaemonSet", "ServiceAccount", "ClusterRole", "ClusterRoleBinding"},
        )
        self.assertEqual(len(docs), 5)
        self.assertEqual([c["name"] for c in pod(docs)["containers"]], ["agent"])
        self.assertEqual(pod(docs)["containers"][0]["image"], "belltigerlee/ivis-prove-agent:0.5.3")
        self.assertEqual(set(config(docs)["modules"]), set(MODULES))
        self.assertEqual(config(docs)["otlp"]["endpoint"], "http://collector:4318")
        self.assertFalse(config(docs)["otlp"]["use_protobuf"])
        self.assertNotIn("hubble", yaml.safe_dump(docs).lower())
        self.assertNotIn("kafka", yaml.safe_dump(docs).lower())

    def test_all_module_combinations_and_idle_privileges(self):
        for bits in itertools.product((False, True), repeat=len(MODULES)):
            with self.subTest(enabled=bits):
                docs = render(values=selection(bits))
                expected = {name for name, bit in zip(MODULES, bits) if bit}
                self.assertEqual(set(config(docs)["modules"]), expected)
                self.assertEqual(len(pod(docs)["containers"]), 1)
                volumes = {v["name"] for v in pod(docs)["volumes"]}
                self.assertEqual("tracefs" in volumes, bits[2])
                self.assertEqual("ClusterRole" in objects(docs), any(bits))
                if not any(bits):
                    self.assertEqual(volumes, {"config"})
                    self.assertFalse(pod(docs).get("hostPID", False))
                    self.assertFalse(pod(docs)["automountServiceAccountToken"])
                    security = pod(docs)["containers"][0]["securityContext"]
                    self.assertEqual(security["capabilities"], {"drop": ["ALL"]})
                    self.assertTrue(security["runAsNonRoot"])

    def test_namespace_and_name_are_consistent(self):
        for namespace in ("ivis-observer", "another-observer"):
            with self.subTest(namespace=namespace):
                docs = render(namespace=namespace, values={"name": "custom-agent"})
                for doc in docs:
                    if doc["kind"] not in ("ClusterRole", "ClusterRoleBinding"):
                        self.assertEqual(doc["metadata"]["namespace"], namespace)
                        self.assertEqual(doc["metadata"]["name"], "custom-agent")
                binding = objects(docs)["ClusterRoleBinding"]
                self.assertEqual(binding["subjects"][0]["namespace"], namespace)
                self.assertEqual(binding["subjects"][0]["name"], "custom-agent")
                self.assertEqual(binding["roleRef"]["name"], f"{namespace}.custom-agent-reader")

    def test_encoding_and_timing(self):
        for protocol, protobuf in (("http", False), ("http", True), ("grpc", True)):
            with self.subTest(protocol=protocol, protobuf=protobuf):
                docs = render(values={"agent": {"otlp": {"protocol": protocol, "use_protobuf": protobuf}}})
                self.assertEqual(config(docs)["otlp"]["protocol"], protocol)
                self.assertEqual(config(docs)["otlp"]["use_protobuf"], protobuf)
        docs = render(values={"modules": {"cpu": {"config": {"mode": "timing"}}}})
        self.assertEqual(config(docs)["modules"]["cpu"]["feature"]["mode"], "timing")

    def test_invalid_settings_rejected(self):
        cases = (
            "agent.otlp.protocol=grpc",
            "agent.otlp.use_protobuf=invalid",
            "modules.cpu.config.mode=both",
            "agent.delivery.directory=/var/lib/ivis-delivery/outbox",
            "agent.image.tag=obsolete",
            "image.repository=INVALID IMAGE",
            "image.digest=invalid",
        )
        for value in cases:
            with self.subTest(value=value):
                result = subprocess.run(
                    ["helm", "template", "verify", str(CHART), "--set", value],
                    capture_output=True, text=True, timeout=30,
                )
                self.assertNotEqual(result.returncode, 0)

    def test_shared_image_version_and_explicit_overrides(self):
        # Synthetic tags are only rendered, not pulled or advertised as releases.
        for mode in ("builtin", "external"):
            with self.subTest(mode=mode):
                values: dict[str, Any] = {"image": {"tag": "render-shared"}, "agent": {"mode": mode}}
                docs = render(values=values)
                self.assertTrue(all(
                    c["image"].endswith(":render-shared") for c in pod(docs)["containers"]
                ))
                values["image"]["repository"] = "example.invalid/agent"
                values["image"]["pullPolicy"] = "Never"
                docs = render(values=values)
                containers = {c["name"]: c for c in pod(docs)["containers"]}
                self.assertEqual(containers["agent"]["image"], "example.invalid/agent:render-shared")
                self.assertTrue(all(c["imagePullPolicy"] == "Never" for c in containers.values()))
                if mode == "external":
                    values["modules"] = {"cpu": {"image": {"tag": "render-cpu"}}}
                    docs = render(values=values)
                    containers = {c["name"]: c for c in pod(docs)["containers"]}
                    self.assertTrue(containers["module-cpu"]["image"].endswith(":render-cpu"))
                    self.assertTrue(containers["module-process"]["image"].endswith(":render-shared"))
                    self.assertTrue(containers["module-process"]["image"].startswith("belltigerlee/ivis-process-module:"))

    def test_digest_precedence(self):
        digest = "sha256:" + "1" * 64  # Synthetic render-only value, never pulled.
        for mode in ("builtin", "external"):
            with self.subTest(mode=mode):
                docs = render(values={"image": {"digest": digest}, "agent": {"mode": mode}})
                containers = {c["name"]: c for c in pod(docs)["containers"]}
                self.assertEqual(containers["agent"]["image"], f"belltigerlee/ivis-prove-agent@{digest}")
                if mode == "external":
                    self.assertTrue(all("@" not in c["image"] for name, c in containers.items() if name != "agent"))

    def test_examples_and_legacy_mode(self):
        for path in sorted((ROOT / "examples/ivis-node-agent").glob("*.yaml")):
            with self.subTest(example=path.name):
                docs = render(values=yaml.safe_load(path.read_text()))
                if path.stem == "idle":
                    self.assertFalse(config(docs)["modules"])
        docs = render(values={"agent": {"mode": "external"}})
        self.assertEqual(
            {c["name"] for c in pod(docs)["containers"]},
            {"agent", "module-process", "module-cpu", "module-syscall"},
        )
        self.assertNotIn("hubble", yaml.safe_dump(docs).lower())


@unittest.skipUnless(os.environ.get("IVIS_AGENT_BINARY"), "IVIS_AGENT_BINARY not provided")
class RuntimeConfigTest(unittest.TestCase):
    def test_rendered_configs_with_real_binary(self):
        profiles = [selection(bits) for bits in itertools.product((False, True), repeat=3)]
        profiles += [
            {"agent": {"otlp": {"protocol": "grpc", "use_protobuf": True}}},
            {"agent": {"otlp": {"protocol": "http", "use_protobuf": True}}},
            {"modules": {"cpu": {"config": {"mode": "timing"}}}},
            {"agent": {"mode": "external"}},
        ]
        for values in profiles:
            with self.subTest(values=values), tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
                docs = render(values=values)
                path = Path(directory) / "agent.yaml"
                path.write_text(objects(docs)["ConfigMap"]["data"]["agent.yaml"])
                mode = values.get("agent", {}).get("mode", "builtin")
                flag = "--config" if mode == "external" else "--builtin-config"
                result = run(
                    os.environ["IVIS_AGENT_BINARY"], flag, str(path), "--check-config",
                    env={**os.environ, "NODE_NAME": "validation-node"},
                )
                self.assertIn("configuration valid", result.stdout)

    def test_all_off_real_idle_start_and_shutdown(self):
        cfg = config(render(values=selection((False, False, False))))
        # Only the local listen address is changed to avoid conflicting with a live agent.
        cfg["listen"] = "127.0.0.1:0"
        with tempfile.TemporaryDirectory(dir=SCRATCH) as directory:
            path = Path(directory) / "idle.yaml"
            path.write_text(yaml.safe_dump(cfg))
            process = subprocess.Popen(
                [os.environ["IVIS_AGENT_BINARY"], "--builtin-config", str(path)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            try:
                time.sleep(0.5)
                self.assertIsNone(process.poll(), "idle process exited prematurely")
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout, "")
                stats = json.loads(stderr.strip().splitlines()[-1])
                self.assertEqual(stats["requests"], 0)
                self.assertEqual(stats["source_samples"], 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()

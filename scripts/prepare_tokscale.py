#!/usr/bin/env python3
"""可选开发工具：预取并校验官方 tokscale，供显式启用的隔离集成测试使用。"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "ThirdParty/tokscale/tokscale-manifest.json"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_tarball(path, expected_integrity):
    actual = "sha512-" + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode("ascii")
    if actual != expected_integrity:
        raise ValueError("tokscale 包 SHA-512 与锁定清单不一致")


def extract_binary(tarball, destination, expected_sha256):
    # 不展开整个 tarball，避免上游路径、符号链接或安装脚本影响构建机。
    with tarfile.open(tarball, "r:gz") as archive:
        members = [m for m in archive.getmembers() if m.name == "package/bin/tokscale"]
        if len(members) != 1 or not members[0].isfile():
            raise ValueError("tokscale 包缺少唯一的普通二进制文件")
        member = members[0]
        if member.size > 64 * 1024 * 1024:
            raise ValueError("tokscale 二进制大小超出预期")
        with archive.extractfile(member) as stream:
            content = stream.read()
    if hashlib.sha256(content).hexdigest() != expected_sha256:
        raise ValueError("tokscale 二进制 SHA-256 与锁定清单不一致")
    destination.write_bytes(content)
    destination.chmod(0o755)


def prepare(manifest, arch, cache_dir):
    spec = manifest["platforms"][arch]
    directory = cache_dir / manifest["version"] / arch
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / "tokscale"
    if binary.is_file() and not binary.is_symlink() and sha256(binary) == spec["binarySHA256"]:
        binary.chmod(0o755)
        return binary
    tarball = directory / "package.tgz"
    if tarball.is_file():
        verify_tarball(tarball, spec["integrity"])
    else:
        with tempfile.TemporaryDirectory(prefix="download-", dir=directory) as staging:
            downloaded = Path(staging) / "package.tgz"
            subprocess.run([
                "/usr/bin/curl", "--fail", "--show-error", "--location",
                "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "15",
                "--max-time", "180", "--retry", "2", "--output", str(downloaded), spec["url"],
            ], check=True)
            verify_tarball(downloaded, spec["integrity"])
            os.replace(downloaded, tarball)
    with tempfile.TemporaryDirectory(prefix="extract-", dir=directory) as staging:
        extracted = Path(staging) / "tokscale"
        extract_binary(tarball, extracted, spec["binarySHA256"])
        os.replace(extracted, binary)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", action="append", choices=["arm64", "x86_64"])
    parser.add_argument("--cache-dir", type=Path, default=ROOT / ".build/tokscale")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST_PATH.read_text())
    architectures = list(dict.fromkeys(args.arch or [os.uname().machine]))
    if not architectures or any(arch not in manifest["platforms"] for arch in architectures):
        parser.error("仅支持 macOS arm64 / x86_64 架构")
    for arch in architectures:
        print(prepare(manifest, arch, args.cache_dir))
    print("tokscale " + manifest["version"] + " 已校验：" + ", ".join(architectures))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Transfer debug runtime products without copying object files or rebuilding."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

MANIFEST = ".vane-ci-build.json"


def toolchain_key():
    commands = (["swift", "--version"], ["xcodebuild", "-version"],
                ["xcrun", "--show-sdk-path"], ["xcrun", "--show-sdk-build-version"])
    return hashlib.sha256(b"".join(subprocess.check_output(command) for command in commands)).hexdigest()


def pack(root, binary, archive, revision, toolchain):
    root, binary = root.resolve(), binary.resolve()
    if not binary.is_relative_to(root / ".build") or binary.name != "debug":
        raise ValueError("only workspace-owned native debug products may be shared")
    description = binary / "description.json"
    products = json.loads(description.read_text())["builtTestProducts"]
    lease_holder = binary / "NativeLeaseHolder"
    if lease_holder.is_symlink() or not lease_holder.is_file() or not lease_holder.stat().st_mode & 0o111:
        raise ValueError("debug artifact must contain an executable native lease holder")
    payload = [binary / "vane", lease_holder, description, *sorted(binary.glob("*.bundle")), root / "Vane.app"]
    if not products:
        raise ValueError("debug artifact must contain built XCTest products")
    for product in products:
        executable = Path(product["binaryPath"])
        bundle = next((path for path in executable.parents if path.suffix == ".xctest"), None)
        if bundle is None or not bundle.is_relative_to(binary) or not executable.is_file():
            raise ValueError("missing or misplaced XCTest executable")
        payload.append(bundle)
    for path in payload:
        if not path.exists() or not path.resolve().is_relative_to(root):
            raise ValueError(f"missing or nonlocal runtime product: {path}")
    metadata = {"schema": 1, "revision": revision, "toolchain": toolchain,
                "root": str(root), "binary": str(binary.relative_to(root))}
    data = (json.dumps(metadata) + "\n").encode()
    with tarfile.open(archive, "w:gz", compresslevel=1) as tar:
        member = tarfile.TarInfo(MANIFEST)
        member.size = len(data)
        tar.addfile(member, io.BytesIO(data))
        for path in payload:
            tar.add(path, arcname=str(path.relative_to(root)))
        # Preserve SwiftPM's public configuration path without copying build caches.
        member = tarfile.TarInfo(".build/debug")
        member.type = tarfile.SYMTYPE
        member.linkname = str(binary.relative_to(root / ".build"))
        tar.addfile(member)
    print(f"Shared runtime archive: {archive.stat().st_size / 1024 / 1024:.1f} MiB")


def restore(root, archive, revision, toolchain):
    root = root.resolve()
    with tarfile.open(archive) as tar:
        metadata = json.load(tar.extractfile(MANIFEST))
        if (metadata.get("schema"), metadata.get("root"), metadata.get("revision"), metadata.get("toolchain")) != (
            1, str(root), revision, toolchain
        ):
            raise ValueError("shared build revision, checkout path, or toolchain does not match this runner")
        binary = PurePosixPath(metadata["binary"])
        if binary.is_absolute() or ".." in binary.parts or binary.parts[0] != ".build" or binary.name != "debug":
            raise ValueError("invalid debug product directory in shared build")
        for member in tar.getmembers():
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not (
                member.name in (MANIFEST, ".build/debug") or name.is_relative_to(binary) or
                name.is_relative_to("Vane.app")
            ):
                raise ValueError("unexpected shared build archive path: " + member.name)
        try:
            lease_holder = tar.getmember(str(binary / "NativeLeaseHolder"))
        except KeyError:
            raise ValueError("shared runtime is missing its native lease holder") from None
        if not lease_holder.isfile() or not lease_holder.mode & 0o111:
            raise ValueError("shared runtime native lease holder must be an executable file")
        tar.extractall(root, filter="data")
    print("Restored matching debug runtime; no compilation required")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("toolchain")
    for name in ("pack", "restore"):
        command = commands.add_parser(name)
        command.add_argument("--archive", type=Path, required=True)
        command.add_argument("--revision", required=True)
        command.add_argument("--root", type=Path, default=Path.cwd())
        if name == "pack":
            command.add_argument("--bin-path", type=Path, required=True)
    args = parser.parse_args()
    try:
        key = toolchain_key()
        if args.command == "toolchain":
            print(key)
        elif args.command == "pack":
            pack(args.root, args.bin_path, args.archive, args.revision, key)
        else:
            restore(args.root, args.archive, args.revision, key)
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        parser.exit(1, f"shared build error: {error}\n")


if __name__ == "__main__":
    main()

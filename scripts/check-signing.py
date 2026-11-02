#!/usr/bin/env python3
"""Verify that updates keep their identity without accepting an unrelated signer."""
from pathlib import Path
import argparse
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


def command(arguments, *, source=None, expect_success=True):
    result = subprocess.run([str(value) for value in arguments], input=source, text=True, capture_output=True)
    if expect_success and result.returncode:
        raise RuntimeError(result.stderr.strip() or "Signing check failed")
    return result


def requirement(path):
    result = command(["codesign", "-d", "-r-", path])
    for line in (result.stdout + result.stderr).splitlines():
        if "designated =>" in line:
            return line.split("designated =>", 1)[1].strip()
    raise RuntimeError("No designated requirement was found")


def code_hash(path):
    result = command(["codesign", "-d", "--verbose=4", path])
    return re.search(r"^CDHash=(\S+)", result.stdout + result.stderr, re.MULTILINE).group(1)


parser = argparse.ArgumentParser()
parser.add_argument("--application", type=Path)
arguments = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="FrameRecSigningCheck-") as temporary:
    paths = [Path(temporary) / name for name in ("before", "after", "unrelated")]
    for index, path in enumerate(paths):
        command(["clang", "-x", "c", "-", "-o", path], source=f"int main(void){{return {index + 1};}}")
    for path in paths[:2]:
        command([sys.executable, root / "scripts/sign-app.py", path, "--identifier", "com.framerec.signingcheck"])
    original = requirement(paths[0])
    assert "cdhash" not in original, "The permission identity must not be tied to one build"
    assert original == requirement(paths[1]), "A new build changed the signing identity"
    assert code_hash(paths[0]) != code_hash(paths[1]), "Fixtures must contain different executables"
    command(["codesign", "--verify", "--strict", "-R", "=" + original, paths[1]])
    command(["codesign", "--force", "--sign", "-", "--identifier", "com.framerec.signingcheck", paths[2]])
    rejected = command(["codesign", "--verify", "--strict", "-R", "=" + original, paths[2]], expect_success=False)
    assert rejected.returncode != 0, "An unrelated signing identity was incorrectly accepted"
print("Signing identity verified: changed build accepted; unrelated signer rejected.")

if arguments.application:
    original_app = arguments.application.resolve()
    original_requirement = requirement(original_app)
    with tempfile.TemporaryDirectory(prefix="FrameRecBundleSigningCheck-") as temporary:
        updated_app = Path(temporary) / "FrameRec.app"
        shutil.copytree(original_app, updated_app)
        info_path = updated_app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleVersion"] = str(int(info["CFBundleVersion"]) + 1)
        info_path.write_bytes(plistlib.dumps(info))
        command([sys.executable, root / "scripts/sign-app.py", updated_app])
        assert requirement(updated_app) == original_requirement, "App bundle update changed the signing identity"
        assert code_hash(updated_app) != code_hash(original_app), "Bundle fixtures must have different code hashes"
        command(["codesign", "--verify", "--deep", "--strict", "-R", "=" + original_requirement, updated_app])
    print("App bundle update verified: new bundle version satisfies the previous build's identity.")

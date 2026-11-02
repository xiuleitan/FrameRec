#!/usr/bin/env python3
"""Sign local builds with one persistent certificate; never edit TCC or trust settings."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys


def run(arguments, operation):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True)
    if result.returncode:
        # Don't include the command line or generated secrets in exceptions.
        raise RuntimeError(f"{operation}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def local_identity():
    directory = Path(os.environ.get("FRAMEREC_SIGNING_HOME", str(Path.home() / "Library/Application Support/FrameRec/Signing")))
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    metadata = directory / "identity.json"
    keychain = directory / "identity.keychain-db"
    password = directory / "password"
    certificate = directory / "certificate.pem"
    private_key = directory / "pending-private-key.pem"
    p12 = directory / "pending-identity.p12"
    configuration = directory / "certificate.cnf"
    creating = not metadata.exists()
    if not creating and not all(path.exists() for path in (keychain, password, certificate)):
        raise RuntimeError("Local signing identity is incomplete. Restore its signing directory; refusing to silently change the app identity.")
    if creating:
        if any(path.exists() for path in (keychain, password, certificate, p12, private_key)):
            raise RuntimeError("Incomplete first-time signing setup. Resolve the existing signing directory before retrying; no identity was replaced.")
        password.write_text(secrets.token_urlsafe(36))
        password.chmod(0o600)
        configuration.write_text("""[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = FrameRec Local Code Signing
O = FrameRec Local Development
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
""")
        run(["openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650", "-sha256",
             "-config", configuration, "-keyout", private_key, "-out", certificate], "Create local code-signing certificate")
        private_key.chmod(0o600)
        openssl_version = run(["openssl", "version"], "Check certificate tooling")
        legacy_option = ["-legacy"] if openssl_version.startswith("OpenSSL 3.") else []
        run(["openssl", "pkcs12", "-export", *legacy_option, "-inkey", private_key, "-in", certificate,
             "-name", "FrameRec Local Code Signing", "-out", p12, "-passout", f"file:{password}"], "Package local signing identity")
        p12.chmod(0o600)

    source = Path(__file__).with_name("signing-keychain.swift")
    helper = directory / "signing-keychain"
    if not helper.exists() or source.stat().st_mtime > helper.stat().st_mtime:
        run(["swiftc", source, "-o", helper], "Compile local keychain helper")
    run([helper, directory], "Prepare local signing keychain")
    keychain.chmod(0o600)
    fingerprint = run(["openssl", "x509", "-in", certificate, "-noout", "-fingerprint", "-sha1"], "Read signing certificate identity")
    fingerprint = fingerprint.rsplit("=", 1)[-1].replace(":", "").strip()
    if creating:
        metadata.write_text(json.dumps({"schemaVersion": 1, "certificateSHA1": fingerprint}, indent=2) + "\n")
        metadata.chmod(0o600)
    elif json.loads(metadata.read_text())["certificateSHA1"] != fingerprint:
        raise RuntimeError("The local signing certificate has changed. Refusing to change the app's identity.")
    for path in (private_key, p12, configuration):
        path.unlink(missing_ok=True)
    return fingerprint, keychain


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("application", type=Path)
    parser.add_argument("--identifier", default="com.framerec.app")
    args = parser.parse_args()
    identity = os.environ.get("FRAMEREC_SIGN_IDENTITY")
    keychain = None
    if not identity:
        identity, keychain = local_identity()
    if identity == "-":
        raise RuntimeError("Ad-hoc signing changes the privacy identity on every build. Use the persistent local signer or a development certificate.")
    command = ["codesign", "--force", "--sign", identity, "--identifier", args.identifier, "--timestamp=none"]
    if keychain:
        command += ["--keychain", keychain]
    command.append(args.application)
    try:
        run(command, "Sign application with persistent identity")
        run(["codesign", "--verify", "--deep", "--strict", args.application], "Verify application signature")
    finally:
        if keychain:
            run(["security", "lock-keychain", keychain], "Lock local signing keychain")
    print("Signed with a persistent code-signing identity.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FrameRec signing failed: {error}", file=sys.stderr)
        sys.exit(1)

# A stand-in for Bitwarden: rbw's local copy of a vault, written the way rbw
# 1.15 writes it (src/db.rs), for a test to put where rbw keeps its cache.
# `rbw unlock` and `rbw get` read only this file and never ask the server
# (modules/common/bash/secrets.bash says why), so the real rbw and its real
# agent run on it in a VM with no network: the master password, the items and
# the SSH key are the test's own.
#
# The crypto is Bitwarden's, as rbw reads it (src/identity.rs,
# src/cipherstring.rs): the master key is PBKDF2-SHA256 of the password,
# salted with the lowercase email; HKDF-Expand stretches it into an AES key
# and an HMAC key; the vault's own 64-byte key is wrapped with those, and
# every field is a type 2 cipher string (AES-256-CBC, PKCS#7, HMAC-SHA256 over
# the IV and the ciphertext) under the vault's key. Every value is derived
# from fixed seeds, so the file is the same at every build.
#
# Usage: make-vault.py SPEC OUT
#   SPEC: JSON {email, password, iterations, items: [...]}, an item being
#     {"name", "login": {"username", "password"}} or {"name", "ssh": SEED}
#     (SEED: a string the Ed25519 key is derived from).
#   OUT: a directory; gets db.json and NAME.pub for each SSH item.
import base64
import hashlib
import hmac
import json
import os
import sys

from cryptography.hazmat.primitives import hashes, padding, serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand


def seeded(label, n):
    out = b""
    i = 0
    while len(out) < n:
        out += hashlib.sha256(f"{label}/{i}".encode()).digest()
        i += 1
    return out[:n]


def encrypt(key, plaintext, label):
    enc, mac = key[:32], key[32:]
    iv = seeded("iv/" + label, 16)
    padder = padding.PKCS7(128).padder()
    data = padder.update(plaintext) + padder.finalize()
    encryptor = Cipher(algorithms.AES(enc), modes.CBC(iv)).encryptor()
    ct = encryptor.update(data) + encryptor.finalize()
    tag = hmac.new(mac, iv + ct, hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode()
    return f"2.{b64(iv)}|{b64(ct)}|{b64(tag)}"


def main(spec_path, out):
    spec = json.load(open(spec_path))
    email = spec["email"].strip().lower()
    master = hashlib.pbkdf2_hmac(
        "sha256", spec["password"].encode(), email.encode(), spec["iterations"], 32
    )
    stretched = b"".join(
        HKDFExpand(algorithm=hashes.SHA256(), length=32, info=info).derive(master)
        for info in (b"enc", b"mac")
    )
    vault_key = seeded("vault-key", 64)

    os.makedirs(out, exist_ok=True)
    entries = []
    for n, item in enumerate(spec["items"]):
        e = lambda value, field: encrypt(vault_key, value.encode(), f"{n}/{field}")
        if "login" in item:
            data = {
                "Login": {
                    "username": e(item["login"]["username"], "username"),
                    "password": e(item["login"]["password"], "password"),
                    "totp": None,
                    "uris": [],
                }
            }
        else:
            key = Ed25519PrivateKey.from_private_bytes(seeded("ssh/" + item["ssh"], 32))
            private = key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.OpenSSH,
                serialization.NoEncryption(),
            ).decode()
            # OpenSSH writes the body in lines of 70, and rbw's agent (the
            # ssh-key crate) reads no other width; cryptography writes 64.
            lines = private.strip().splitlines()
            body = "".join(lines[1:-1])
            private = "\n".join(
                [lines[0]] + [body[i : i + 70] for i in range(0, len(body), 70)] + [lines[-1]]
            ) + "\n"
            public = key.public_key().public_bytes(
                serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH
            ).decode()
            with open(os.path.join(out, item["name"] + ".pub"), "w") as f:
                f.write(public + "\n")
            data = {
                "SshKey": {
                    "private_key": e(private, "private"),
                    "public_key": e(public, "public"),
                    "fingerprint": None,
                }
            }
        entries.append(
            {
                "id": "00000000-0000-4000-8000-%012d" % n,
                "org_id": None,
                "folder": None,
                "folder_id": None,
                "name": e(item["name"], "name"),
                "data": data,
                "fields": [],
                "notes": None,
                "history": [],
                "key": None,
                "master_password_reprompt": 0,
            }
        )

    db = {
        # Never sent anywhere: rbw needs a login on record before it unlocks.
        "access_token": "stub-access-token",
        "refresh_token": "stub-refresh-token",
        "kdf": 0,
        "iterations": spec["iterations"],
        "memory": None,
        "parallelism": None,
        "protected_key": encrypt(stretched, vault_key, "protected-key"),
        # The account's RSA key, which only an organization's items need: the
        # stand-in has none, and rbw only decrypts this.
        "protected_private_key": encrypt(vault_key, seeded("rsa", 48), "private-key"),
        "protected_org_keys": {},
        "entries": entries,
    }
    with open(os.path.join(out, "db.json"), "w") as f:
        json.dump(db, f)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

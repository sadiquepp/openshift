#!/usr/bin/env python3
"""Convert an RSA public key PEM to JWK components for Terraform external data source."""
import json, sys, subprocess, base64, hashlib

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

inp = json.load(sys.stdin)
pem = inp["public_key_pem"]

result = subprocess.run(
    ["openssl", "rsa", "-pubin", "-text", "-noout"],
    input=pem, capture_output=True, text=True,
)

lines = result.stdout.split("\n")
mod_lines = []
in_modulus = False
exp_val = 65537

for line in lines:
    if "Modulus:" in line:
        in_modulus = True
        continue
    if "Exponent:" in line:
        in_modulus = False
        exp_val = int(line.split("(")[0].split(":")[1].strip())
        break
    if in_modulus:
        mod_lines.append(line.strip().replace(":", ""))

mod_bytes = bytes.fromhex("".join(mod_lines))
if mod_bytes[0] == 0:
    mod_bytes = mod_bytes[1:]

exp_bytes = exp_val.to_bytes((exp_val.bit_length() + 7) // 8, "big")

der = subprocess.run(
    ["openssl", "rsa", "-pubin", "-outform", "DER"],
    input=pem.encode(), capture_output=True,
).stdout

json.dump({
    "n":   b64url(mod_bytes),
    "e":   b64url(exp_bytes),
    "kid": b64url(hashlib.sha256(der).digest()),
}, sys.stdout)

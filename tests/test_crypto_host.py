#!/usr/bin/env python3
# Author: sunfang1cn@gmail.com
"""Build the freestanding crypto on Windows and check it against Python."""

from __future__ import annotations

import ctypes
import hashlib
import pathlib
import re
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src" / "main" / "airplay_crypto.c"


def mgf1(seed: bytes, length: int) -> bytes:
    result = bytearray()
    counter = 0
    while len(result) < length:
        result.extend(hashlib.sha1(seed + counter.to_bytes(4, "big")).digest())
        counter += 1
    return bytes(result[:length])


def parse_modulus() -> int:
    text = SOURCE.read_text(encoding="utf-8")
    match = re.search(r"RSA_N\[RSA_LIMBS\]\s*=\s*\{(.*?)\};", text, re.S)
    assert match
    limbs = [int(value, 16) for value in re.findall(r"0x([0-9a-f]+)u", match.group(1))]
    assert len(limbs) == 64
    return sum(value << (32 * index) for index, value in enumerate(limbs))


def build_library(output_dir: pathlib.Path) -> pathlib.Path:
    dll = output_dir / "airplay_crypto_test.dll"
    compile_args = [
            "cl",
            "/nologo",
            "/O2",
            "/LD",
            "/DAIRPLAY_CRYPTO_TEST",
            str(SOURCE),
            f"/Fe:{dll}",
        ]
    vcvars = pathlib.Path(
        r"C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    )
    if vcvars.exists():
        batch = output_dir / "build_crypto_test.cmd"
        batch.write_text(
            f'@call "{vcvars}" >nul\n{subprocess.list2cmdline(compile_args)}\n',
            encoding="utf-8",
        )
        compile_args = ["cmd.exe", "/d", "/c", str(batch)]
    elif shutil.which("cl") is None:
        raise RuntimeError("Visual C++ compiler was not found")
    subprocess.run(
        compile_args,
        cwd=output_dir,
        check=True,
    )
    return dll


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="airplay-crypto-") as tmp:
        lib = ctypes.CDLL(str(build_library(pathlib.Path(tmp))))

        u8p = ctypes.POINTER(ctypes.c_uint8)
        lib.airplay_sha1.argtypes = [u8p, ctypes.c_size_t, u8p]
        lib.airplay_rsa_pkcs1_sign_raw.argtypes = [u8p, ctypes.c_size_t, u8p]
        lib.airplay_rsa_oaep_decrypt.argtypes = [u8p, u8p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        lib.airplay_aes128_cbc_decrypt.argtypes = [u8p, u8p, u8p, u8p, ctypes.c_size_t]

        abc = (ctypes.c_uint8 * 3)(*b"abc")
        digest = (ctypes.c_uint8 * 20)()
        lib.airplay_sha1(abc, 3, digest)
        assert bytes(digest) == hashlib.sha1(b"abc").digest()

        key = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
        iv = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
        cipher = bytes.fromhex("7649abac8119b246cee98e9b12e9197d")
        expected = bytes.fromhex("6bc1bee22e409f96e93d7e117393172a")
        plain = (ctypes.c_uint8 * 16)()
        lib.airplay_aes128_cbc_decrypt(
            (ctypes.c_uint8 * 16)(*key),
            (ctypes.c_uint8 * 16)(*iv),
            (ctypes.c_uint8 * 16)(*cipher),
            plain,
            16,
        )
        assert bytes(plain) == expected

        modulus = parse_modulus()
        exponent = 65537
        challenge = bytes(range(32))
        signature = (ctypes.c_uint8 * 256)()
        assert lib.airplay_rsa_pkcs1_sign_raw(
            (ctypes.c_uint8 * len(challenge))(*challenge), len(challenge), signature
        ) == 1
        encoded = pow(int.from_bytes(bytes(signature), "big"), exponent, modulus).to_bytes(256, "big")
        assert encoded == b"\x00\x01" + b"\xff" * 221 + b"\x00" + challenge

        message = bytes.fromhex("00112233445566778899aabbccddeeff")
        label_hash = hashlib.sha1(b"").digest()
        db = label_hash + b"\x00" * (256 - len(message) - 2 * 20 - 2) + b"\x01" + message
        seed = bytes(range(20))
        masked_db = bytes(a ^ b for a, b in zip(db, mgf1(seed, len(db))))
        masked_seed = bytes(a ^ b for a, b in zip(seed, mgf1(masked_db, 20)))
        em = b"\x00" + masked_seed + masked_db
        encrypted = pow(int.from_bytes(em, "big"), exponent, modulus).to_bytes(256, "big")
        decrypted = (ctypes.c_uint8 * 64)()
        decrypted_len = ctypes.c_size_t()
        assert lib.airplay_rsa_oaep_decrypt(
            (ctypes.c_uint8 * 256)(*encrypted), decrypted, len(decrypted), ctypes.byref(decrypted_len)
        ) == 1
        assert bytes(decrypted[: decrypted_len.value]) == message

        # Windows keeps loaded DLLs locked until FreeLibrary is called.
        handle = lib._handle
        del lib
        free_library = ctypes.windll.kernel32.FreeLibrary
        free_library.argtypes = [ctypes.c_void_p]
        free_library(ctypes.c_void_p(handle))

    print("airplay crypto host tests: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

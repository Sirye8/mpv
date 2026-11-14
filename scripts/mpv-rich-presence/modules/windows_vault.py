# SPDX-License-Identifier: AGPL-3.0-or-later
"""Generic credentials scoped to the current Windows user."""

import ctypes as c
from ctypes import wintypes as w


class Credential(c.Structure):
    _fields_ = [
        ("Flags", w.DWORD),
        ("Type", w.DWORD),
        ("TargetName", w.LPWSTR),
        ("Comment", w.LPWSTR),
        ("LastWritten", w.FILETIME),
        ("CredentialBlobSize", w.DWORD),
        ("CredentialBlob", c.c_void_p),
        ("Persist", w.DWORD),
        ("AttributeCount", w.DWORD),
        ("Attributes", c.c_void_p),
        ("TargetAlias", w.LPWSTR),
        ("UserName", w.LPWSTR),
    ]


class WindowsVault:
    def __init__(self):
        self.api = c.WinDLL("advapi32", use_last_error=True)
        self.api.CredWriteW.argtypes = [c.POINTER(Credential), w.DWORD]
        self.api.CredReadW.argtypes = [
            w.LPCWSTR,
            w.DWORD,
            w.DWORD,
            c.POINTER(c.POINTER(Credential)),
        ]
        self.api.CredFree.argtypes = [c.c_void_p]
        self.api.CredDeleteW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD]

    def set_password(self, service, key, value):
        raw = value.encode()
        buf = c.create_string_buffer(raw)
        record = Credential(
            Type=1,
            TargetName=service + "/" + key,
            UserName=key,
            Persist=2,
            CredentialBlobSize=len(raw),
            CredentialBlob=c.cast(buf, c.c_void_p),
        )
        if not self.api.CredWriteW(c.byref(record), 0):
            raise c.WinError(c.get_last_error())

    def get_password(self, service, key):
        ptr = c.POINTER(Credential)()
        if not self.api.CredReadW(service + "/" + key, 1, 0, c.byref(ptr)):
            if c.get_last_error() == 1168:
                return None
            raise c.WinError(c.get_last_error())
        try:
            record = ptr.contents
            return c.string_at(
                record.CredentialBlob, record.CredentialBlobSize
            ).decode()
        finally:
            self.api.CredFree(ptr)

    def delete_password(self, service, key):
        if (
            not self.api.CredDeleteW(service + "/" + key, 1, 0)
            and c.get_last_error() != 1168
        ):
            raise c.WinError(c.get_last_error())

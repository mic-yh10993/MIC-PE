#!/usr/bin/env python3
"""Extract the minimal .reg patches for the MIC-PE clean rebuild from the
Ramos 22621.1105 reference PE hives.

This is a LOCAL extraction tool (not run in CI). It reads the reference
hives from ~/workspace/micpe-ref/hives/ and writes UTF-16LE+BOM .reg files
into src/build/reg/ (the clean build imports them at CI mount time via
Registry.ps1 Mount-RegistryHive / Import-RegFile, using the PE-SYS /
PE-SOFT / PE-DEF mount aliases).

What is extracted (and only this -- no whole-hive copies):
  10-clean-boot.reg   SYSTEM\\Setup boot chain (SetupType, CmdLine,
                      SystemSetupInProgress) + SOFTWARE Winlogon (Shell,
                      AutoRestartShell, Userinit) + SystemRoot=X:\\Windows
                      (the official install.wim says C:\\Windows; a PE
                      must be X:\\Windows, as in the reference).
  20-clean-start11.reg
                      DEFAULT hive Start11 settings under
                      Software\\Stardock\\Start8\\Start8.ini\\, subkeys
                      Right / Search / Start8 (recursively). The pinned-item
                      groups (Groups, Groups11, GroupContents,
                      GroupContents11) are EXCLUDED per the user's
                      "clean the Start menu pinned items" decision.
                      Two path/value rewrites are applied:
                      - Start8\\Image is repointed from
                        X:\\Program Files (x86)\\Stardock\\Start11\\... to
                        X:\\Windows\\System32\\MICPE\\Start11\\... (the new
                        install location).
                      - CreatedPinned10 / CreatedPinned11 are reset to '0'
                        so Start11 rebuilds its default pinned set from the
                        clean system's apps instead of referencing the
                        deleted third-party apps.
  30-clean-author.reg SOFTWARE CurrentVersion RegisteredOwner =
                      SYSTEM-Intel-MIC; RegisteredOrganization deleted
                      (the reference value is Ramos's motto, not a
                      Microsoft default).
  40-clean-startallback.reg
                      StartAllBack shell integration, extracted from the
                      Ramos reference PE. SOFTWARE Classes CLSIDs (9 GUIDs,
                      InprocServer32 -> StartAllBackLoaderX64.dll /
                      StartAllBackX64.dll), App Paths\\StartAllBackCfg.exe,
                      the two StartIsBack.* ProgIDs (context-menu verbs),
                      and DEFAULT Software\\StartIsBack (per-user settings,
                      full subtree). ALL file paths are repointed from
                      X:\\Program Files\\StartAllBack\\ to
                      X:\\Windows\\System32\\MICPE\\StartAllBack\\ (the new
                      install location). One dangling value is DROPPED:
                      CLSID {FCEA18FF...} LocalizedString points at
                      X:\\Program Files\\StartIsBack\\StartIsBack64.dll,
                      a file that does not exist in the reference (renamed
                      product leftover); dropping it lets the display name
                      fall back to the CLSID default 'StartAllBack'.
                      NOTE: the StartIsBack AlterStyle / TaskbarStyle values
                      reference Styles\\Plain10.msstyles and Styles\\Windows
                      10.msstyles, which exist in NEITHER the reference nor
                      shell.zip (only Plain8 / Windows 7 are shipped).
                      The rewritten paths are kept as-is so StartAllBack
                      falls back to its built-in default style, exactly as
                      it does in the reference PE.

Administrator RID 500 enable is NOT a .reg file: it is a bit-clear on the
SAM hive's F value (ACB DWORD at offset 0x38), which .reg cannot express
without copying the whole F value (including password hashes -- never
done). Build-CleanPe.ps1 does it at build time on the official image's
own SAM (see Enable-PeAdministrator).

Usage:
    python3 Extract-CleanReg.py [--hives DIR] [--out DIR]
Defaults: hives=~/workspace/micpe-ref/hives, out=<repo>/src/build/reg
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.expanduser("~/.local/lib/python3.12/site-packages"))
from regipy import RegistryHive  # noqa: E402

# Start11 install location in the clean PE (X: is the PE system drive).
MICPE_START11 = r"X:\Windows\System32\MICPE\Start11"
OLD_START11_PREFIX = r"X:\Program Files (x86)\Stardock\Start11"

# StartAllBack install location in the clean PE.
MICPE_SAB = r"X:\Windows\System32\MICPE\StartAllBack"
OLD_SAB_PREFIX = r"X:\Program Files\StartAllBack"

# StartAllBack CLSIDs (SOFTWARE\Classes\CLSID) -- the shell extension
# registrations that make Explorer load StartAllBack. Found by a byte
# search for "StartAllBack" in the SOFTWARE hive (30 hits) + a CLSID walk;
# the 9 GUIDs below are the live registrations (the rest of the byte hits
# are in slack space / MUI cache, not functional registrations).
SAB_CLSIDS = [
    "{117E3954-5034-453A-A18B-7B79493646E6}",  # StartAllBackLoaderX64.dll
    "{865e5e76-ad83-4dca-a109-50dc2113ce9b}",  # 'StartIsBack All Programs Folder'
    "{99E2B362-3E4E-4255-9B29-41A7F40777BA}",  # 'Settings Pages'
    "{99E2B362-3E4E-4255-9B29-41A7F40777BB}",  # 'God Mode'
    "{a2a9545d-a0c2-42b4-9708-a0b2badd77c9}",  # ImplementsVerbs startpin;startunpin
    "{ab0b37ec-56f6-4a0e-a8fd-7a8bf7c2da97}",
    "{AD1405D2-30CF-4877-8468-1EE1C52C759F}",  # '@twinui.dll,-4137'
    "{E5C31EC8-C5E6-4E07-957E-944DB4AAD85E}",
    "{FCEA18FF-BC55-4E63-94D7-1B2EFBFE706F}",  # 'StartAllBack' (Control Panel app)
]
# StartAllBack ProgIDs (SOFTWARE\Classes) -- context-menu verbs for the
# Start menu / modern apps. They only reference CLSID GUIDs and system
# DLLs, so no path rewrite is needed.
SAB_PROGIDS = ["StartIsBack.AppsFolder", "StartIsBack.ImmersiveApplication"]
# CLSID {FCEA18FF...} LocalizedString points at a file that does not exist
# (StartIsBack64.dll, renamed-product leftover); drop it on extraction.
SAB_DROP_LOCALIZED_STRING_CLSID = "{FCEA18FF-BC55-4E63-94D7-1B2EFBFE706F}"

# Start8.ini subkeys that ARE the pinned-item groups -- excluded.
PINNED_SUBKEYS = {"Groups", "Groups11", "GroupContents", "GroupContents11"}
# Start8.ini subkeys that are kept (recursively).
KEPT_SUBKEYS = {"Right", "Search", "Start8"}


def get_key(hive, parts):
    key = hive.root
    for part in parts:
        try:
            key = key.get_subkey(part)
        except Exception:
            return None
        if key is None:
            return None
    return key


def reg_escape_str(s):
    """Escape a REG_SZ value for .reg syntax: backslash and quote."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def reg_escape_name(name):
    return name.replace("\\", "\\\\").replace('"', '\\"')


def format_value(name, value_type, value):
    """Return one .reg value line (without trailing newline)."""
    ename = reg_escape_name(name)
    if value_type == "REG_DWORD":
        return '"%s"=dword:%08x' % (ename, int(value))
    if value_type == "REG_SZ":
        return '"%s"="%s"' % (ename, reg_escape_str(str(value)))
    if value_type == "REG_EXPAND_SZ":
        raw = str(value).encode("utf-16-le") + b"\x00\x00"
        return '"%s"=hex(2):%s' % (ename, ",".join("%02x" % b for b in raw))
    if value_type == "REG_BINARY":
        raw = value if isinstance(value, (bytes, bytearray)) else bytes(value)
        return '"%s"=hex:%s' % (ename, ",".join("%02x" % b for b in raw))
    if value_type == "REG_MULTI_SZ":
        parts = value if isinstance(value, list) else [str(value)]
        raw = b"".join(p.encode("utf-16-le") + b"\x00\x00" for p in parts) + b"\x00\x00"
        return '"%s"=hex(7):%s' % (ename, ",".join("%02x" % b for b in raw))
    raise ValueError("unsupported registry type %r for value %r" % (value_type, name))


def write_reg(path, header_comment, sections):
    """sections: list of (key_path, [value_line, ...]). Writes UTF-16LE+BOM."""
    lines = ["Windows Registry Editor Version 5.00", ""]
    for comment in header_comment:
        lines.append("; " + comment)
    if header_comment:
        lines.append("")
    for key_path, value_lines in sections:
        lines.append("[%s]" % key_path)
        lines.extend(value_lines)
        lines.append("")
    text = "\r\n".join(lines)
    with open(path, "wb") as f:
        f.write(b"\xff\xfe")
        f.write(text.encode("utf-16-le"))
    print("wrote %s (%d bytes, %d sections)" % (path, os.path.getsize(path), len(sections)))


def collect_key_values(hive, parts):
    """Return [(name, type, value)] for a key, or None if the key is missing."""
    key = get_key(hive, parts)
    if key is None:
        return None
    out = []
    for v in key.iter_values():
        out.append((v.name, str(v.value_type), v.value))
    return out


def collect_subtree(hive, base_parts, subkey):
    """Recursively collect (rel_path, [(name, type, value)]) under base/subkey."""
    key = get_key(hive, base_parts + [subkey])
    if key is None:
        return []
    results = []

    def walk(k, rel):
        vals = []
        for v in k.iter_values():
            vals.append((v.name, str(v.value_type), v.value))
        results.append((rel, vals))
        for sub in k.iter_subkeys():
            walk(sub, rel + "\\" + sub.name)

    walk(key, subkey)
    return results


def rewrite_sab_path(value):
    """Repoint a StartAllBack path from Program Files to the MICPE folder."""
    if isinstance(value, str):
        return value.replace(OLD_SAB_PREFIX, MICPE_SAB)
    return value


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hives", default=os.path.expanduser("~/workspace/micpe-ref/hives"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    repo = os.path.expanduser("~/workspace/MIC-PE")
    out_dir = args.out or os.path.join(repo, "src", "build", "reg")
    os.makedirs(out_dir, exist_ok=True)

    system = RegistryHive(os.path.join(args.hives, "SYSTEM"))
    software = RegistryHive(os.path.join(args.hives, "SOFTWARE"))
    default = RegistryHive(os.path.join(args.hives, "DEFAULT"))

    # ---- 10-clean-boot.reg ----
    setup_vals = collect_key_values(system, ["Setup"])
    assert setup_vals is not None, "SYSTEM\\Setup not found in reference hive"
    setup_map = {n: (t, v) for n, t, v in setup_vals}
    winlogon_vals = collect_key_values(
        software, ["Microsoft", "Windows NT", "CurrentVersion", "Winlogon"])
    assert winlogon_vals is not None, "SOFTWARE Winlogon not found"
    winlogon_map = {n: (t, v) for n, t, v in winlogon_vals}

    boot_sections = [
        (r"HKEY_LOCAL_MACHINE\PE-SYS\Setup", [
            format_value("SetupType", *setup_map["SetupType"]),
            format_value("CmdLine", *setup_map["CmdLine"]),
            format_value("SystemSetupInProgress", *setup_map["SystemSetupInProgress"]),
        ]),
        (r"HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows NT\CurrentVersion\Winlogon", [
            format_value("Shell", *winlogon_map["Shell"]),
            format_value("AutoRestartShell", *winlogon_map["AutoRestartShell"]),
            format_value("Userinit", *winlogon_map["Userinit"]),
        ]),
        (r"HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows NT\CurrentVersion", [
            # The official install.wim says C:\Windows; a PE must be X:\Windows.
            '"SystemRoot"="X:\\\\Windows"',
        ]),
    ]
    write_reg(
        os.path.join(out_dir, "10-clean-boot.reg"),
        [
            "MICPE clean rebuild (22621.1105): boot chain, extracted from the",
            "Ramos reference PE. Imported at CI mount time into the official",
            "install.wim-derived image (PE-SYS = SYSTEM, PE-SOFT = SOFTWARE).",
            "Only the values the boot chain needs; nothing else is copied.",
            "SetupType=2 + CmdLine=LogonUI: native LogonUI login (no winpeshl,",
            "no startnet, no PECMD shell). Userinit is the reference value",
            "('Userinit.exe,'); Shell/AutoRestartShell are the reference values.",
        ],
        boot_sections,
    )

    # ---- 20-clean-start11.reg ----
    start11_base = ["Software", "Stardock", "Start8", "Start8.ini"]
    start11_sections = []
    for sub in sorted(KEPT_SUBKEYS):
        for rel, vals in collect_subtree(default, start11_base, sub):
            key_path = ("HKEY_LOCAL_MACHINE\\PE-DEF\\Software\\Stardock\\"
                        "Start8\\Start8.ini\\" + rel)
            value_lines = []
            for name, vtype, value in vals:
                # Repoint the Start button image to the new MICPE location.
                if rel == "Start8" and name == "Image" and isinstance(value, str):
                    value = value.replace(OLD_START11_PREFIX, MICPE_START11)
                # Reset the pinned-item creation flags so Start11 rebuilds
                # its default pinned set from the clean system's apps.
                if rel == "Start8" and name in ("CreatedPinned10", "CreatedPinned11"):
                    value = "0"
                value_lines.append(format_value(name, vtype, value))
            start11_sections.append((key_path, value_lines))
    write_reg(
        os.path.join(out_dir, "20-clean-start11.reg"),
        [
            "MICPE clean rebuild (22621.1105): Start11 settings, extracted",
            "from the Ramos reference PE DEFAULT hive (HKCU). Imported at CI",
            "mount time into config\\DEFAULT (PE-DEF).",
            "EXCLUDED on purpose: Groups / Groups11 / GroupContents /",
            "GroupContents11 -- those ARE the Start menu pinned items the",
            "user asked to clean. Start11's Image path is repointed to the",
            "new X:\\Windows\\System32\\MICPE\\Start11 location, and the",
            "CreatedPinned flags are reset so defaults are rebuilt clean.",
        ],
        start11_sections,
    )

    # ---- 30-clean-author.reg ----
    write_reg(
        os.path.join(out_dir, "30-clean-author.reg"),
        [
            "MICPE clean rebuild (22621.1105): author branding. The reference",
            "says RegisteredOwner='(c) SYSTEM-RAMOS-ZDY' and",
            "RegisteredOrganization=Ramos's motto; both are replaced here.",
            "RegisteredOrganization is deleted (\"name\"=-) because the",
            "official image has no such branding to restore.",
        ],
        [
            (r"HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows NT\CurrentVersion", [
                '"RegisteredOwner"="SYSTEM-Intel-MIC"',
                '"RegisteredOrganization"=-',
            ]),
        ],
    )
    # ---- 40-clean-startallback.reg ----
    sab_sections = []
    # (a) The 9 CLSIDs (SOFTWARE\Classes\CLSID), full subtrees, paths rewritten.
    for guid in SAB_CLSIDS:
        for rel, vals in collect_subtree(software, ["Classes", "CLSID"], guid):
            key_path = ("HKEY_LOCAL_MACHINE\\PE-SOFT\\Classes\\CLSID\\" + rel)
            value_lines = []
            for name, vtype, value in vals:
                # Drop the dangling LocalizedString (renamed-product leftover).
                if (guid == SAB_DROP_LOCALIZED_STRING_CLSID
                        and rel == guid and name == "LocalizedString"):
                    continue
                value_lines.append(format_value(name, vtype, rewrite_sab_path(value)))
            sab_sections.append((key_path, value_lines))
    # (b) App Paths\StartAllBackCfg.exe (path rewritten).
    ap_vals = collect_key_values(
        software, ["Microsoft", "Windows", "CurrentVersion", "App Paths",
                   "StartAllBackCfg.exe"])
    assert ap_vals is not None, "App Paths\\StartAllBackCfg.exe not found"
    sab_sections.append((
        r"HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows\CurrentVersion\App Paths\StartAllBackCfg.exe",
        [format_value(n, t, rewrite_sab_path(v)) for n, t, v in ap_vals],
    ))
    # (c) The two StartIsBack.* ProgIDs (full subtrees; GUID refs only).
    for prog in SAB_PROGIDS:
        for rel, vals in collect_subtree(software, ["Classes"], prog):
            key_path = "HKEY_LOCAL_MACHINE\\PE-SOFT\\Classes\\" + rel
            value_lines = [format_value(n, t, v) for n, t, v in vals]
            sab_sections.append((key_path, value_lines))
    # (d) DEFAULT Software\StartIsBack (per-user settings, full subtree),
    #     paths rewritten to the MICPE location.
    for rel, vals in collect_subtree(default, ["Software"], "StartIsBack"):
        key_path = "HKEY_LOCAL_MACHINE\\PE-DEF\\Software\\" + rel
        value_lines = [
            format_value(n, t, rewrite_sab_path(v)) for n, t, v in vals
        ]
        sab_sections.append((key_path, value_lines))
    write_reg(
        os.path.join(out_dir, "40-clean-startallback.reg"),
        [
            "MICPE clean rebuild (22621.1105): StartAllBack shell",
            "integration, extracted from the Ramos reference PE.",
            "SOFTWARE Classes CLSIDs (9 GUIDs) + App Paths + the two",
            "StartIsBack.* ProgIDs go to PE-SOFT; DEFAULT",
            "Software\\StartIsBack (per-user settings) goes to PE-DEF.",
            "All file paths are repointed from X:\\Program",
            "Files\\StartAllBack\\ to X:\\Windows\\System32\\MICPE\\",
            "StartAllBack\\. The dangling LocalizedString in CLSID",
            "{FCEA18FF...} (points at nonexistent StartIsBack64.dll)",
            "is dropped; the display name falls back to 'StartAllBack'.",
            "The StartIsBack AlterStyle / TaskbarStyle values reference",
            "Plain10 / Windows 10 .msstyles, which exist in neither the",
            "reference nor shell.zip; the rewritten paths are kept so",
            "StartAllBack falls back to its built-in default style,",
            "exactly as in the reference PE.",
        ],
        sab_sections,
    )
    print("done.")


if __name__ == "__main__":
    main()

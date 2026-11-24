#!/usr/bin/env python3
"""Write the app .reg patches for the MIC-PE clean rebuild: Office 2016
(app/office/office.reg) and Chrome (app/chrome/chrome.reg).

These are HAND-AUTHORED, not extracted from a hive: the Ramos reference PE
carries Office 2010 (not 2016) and 360Chrome (not Chrome), and its
SOFTWARE hive has no Microsoft\\Office or Google keys at all, so there is
nothing to extract for these two apps. The entries below reproduce the
standard per-machine registration the vendors' own installers create,
re-pointed at the PE paths (X: is the PE system drive; Office lives at
Program Files\\Office2016, Chrome at Program Files\\Google\\Chrome).

Scope (only what the apps need to work in the PE):
  * App Paths -- so WINWORD.EXE / EXCEL.EXE / POWERPNT.EXE / chrome.exe
    launch by name (Run dialog, other programs).
  * File associations -- double-clicking a document / HTML file opens the
    right app (Office .doc/.docx/.xls/.xlsx/.ppt/.pptx via the standard
    Word.Document / Excel.Sheet / PowerPoint.Show ProgIDs; Chrome .html /
    .htm / .shtml / .xhtml / .xht via ChromeHTML).
  * URL protocols -- http/https open in Chrome (ChromeHTML).
  * Default browser / Default Programs -- Chrome's StartMenuInternet
    registration + Capabilities + RegisteredApplications, so it can be
    chosen as the default browser.
  * Office InstallRoot -- the standard key the Office installer writes so
    Office components can locate the install.

NOT included, on purpose:
  * Office COM / OLE registration (Word.Application, Excel.Application,
    ...). That is hundreds of CLSID entries; it is not feasible to
    hand-write, and the green Office opens documents without it. If full
    Office automation is ever needed, that is a separate (much larger)
    extraction effort from a live Office 2016 install -- not this file.
  * Per-user settings (HKCU). Those belong in DEFAULT (PE-DEF) and are
    created by the apps on first run; nothing here needs them.
  * Any Ramos / Office 2010 / 360Chrome entry. The reference's Office
    entries are Office14 (2010) at different paths; copying them for
    Office 2016 would be wrong. No entry below is copied from Ramos.

All sections address HKEY_LOCAL_MACHINE\\PE-SOFT (the mounted SOFTWARE
hive). The clean build imports these at CI mount time via
Invoke-RegistryScript, together with the clean patches -- never inside
the running PE.

Usage:
    python3 Write-AppReg.py [--out DIR]
Defaults: out=<repo>/app (writes office/office.reg, chrome/chrome.reg)
"""
import argparse
import os

# PE paths (X: is the PE system drive; vendor layouts, not MICPE).
OFFICE_DIR = r"X:\Program Files\Office2016\Office16"
CHROME_EXE = r"X:\Program Files\Google\Chrome\Application\chrome.exe"
CHROME_DIR = r"X:\Program Files\Google\Chrome\Application"


def reg_escape_str(s):
    """Escape a REG_SZ value for .reg syntax: backslash and quote."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def reg_escape_name(name):
    return name.replace("\\", "\\\\").replace('"', '\\"')


def format_value(name, value_type, value):
    """Return one .reg value line (without trailing newline)."""
    if name in ("", "@"):
        lhs = "@"
    else:
        lhs = '"%s"' % reg_escape_name(name)
    if value_type == "REG_DWORD":
        return "%s=dword:%08x" % (lhs, int(value))
    if value_type == "REG_SZ":
        return '%s="%s"' % (lhs, reg_escape_str(str(value)))
    raise ValueError("unsupported registry type %r for value %r" % (value_type, name))


def write_reg(path, header_comment, sections):
    """sections: list of (key_path, [(name, type, value), ...]).
    Writes UTF-16LE+BOM."""
    lines = ["Windows Registry Editor Version 5.00", ""]
    for comment in header_comment:
        lines.append("; " + comment)
    if header_comment:
        lines.append("")
    for key_path, values in sections:
        lines.append("[%s]" % key_path)
        for name, vtype, value in values:
            lines.append(format_value(name, vtype, value))
        lines.append("")
    text = "\r\n".join(lines)
    with open(path, "wb") as f:
        f.write(b"\xff\xfe")
        f.write(text.encode("utf-16-le"))
    print("wrote %s (%d bytes, %d sections)" % (path, os.path.getsize(path), len(sections)))


def office_sections():
    """Office 2016: App Paths, file associations, ProgIDs, InstallRoot."""
    s = []
    # App Paths -- launch WINWORD.EXE / EXCEL.EXE / POWERPNT.EXE by name.
    for exe in ("WINWORD.EXE", "EXCEL.EXE", "POWERPNT.EXE"):
        s.append((
            r"HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows\CurrentVersion\App Paths\%s" % exe,
            [
                ("@", "REG_SZ", OFFICE_DIR + "\\" + exe),
                ("Path", "REG_SZ", OFFICE_DIR),
            ],
        ))
    # File associations -- extension -> ProgID (standard Office mapping).
    for ext, progid in (
        (".doc", "Word.Document.8"),
        (".docx", "Word.Document.12"),
        (".xls", "Excel.Sheet.8"),
        (".xlsx", "Excel.Sheet.12"),
        (".ppt", "PowerPoint.Show.8"),
        (".pptx", "PowerPoint.Show.12"),
    ):
        s.append((
            r"HKEY_LOCAL_MACHINE\PE-SOFT\Classes\%s" % ext,
            [("@", "REG_SZ", progid)],
        ))
    # ProgIDs -- display name, icon, and the open command. The commands
    # are the standard vendor forms: Word /n (no blank document),
    # Excel /e (no startup screen), PowerPoint plain "%1".
    progids = (
        ("Word.Document.8", "Microsoft Word 97-2003 Document",
         "WINWORD.EXE", 1, '"' + OFFICE_DIR + r'\WINWORD.EXE" /n "%1"'),
        ("Word.Document.12", "Microsoft Word Document",
         "WINWORD.EXE", 1, '"' + OFFICE_DIR + r'\WINWORD.EXE" /n "%1"'),
        ("Excel.Sheet.8", "Microsoft Excel 97-2003 Worksheet",
         "EXCEL.EXE", 1, '"' + OFFICE_DIR + r'\EXCEL.EXE" /e "%1"'),
        ("Excel.Sheet.12", "Microsoft Excel Worksheet",
         "EXCEL.EXE", 1, '"' + OFFICE_DIR + r'\EXCEL.EXE" /e "%1"'),
        ("PowerPoint.Show.8", "Microsoft PowerPoint 97-2003 Presentation",
         "POWERPNT.EXE", 1, '"' + OFFICE_DIR + r'\POWERPNT.EXE" "%1"'),
        ("PowerPoint.Show.12", "Microsoft PowerPoint Presentation",
         "POWERPNT.EXE", 1, '"' + OFFICE_DIR + r'\POWERPNT.EXE" "%1"'),
    )
    for progid, display, exe, icon_idx, command in progids:
        base = r"HKEY_LOCAL_MACHINE\PE-SOFT\Classes\%s" % progid
        s.append((base, [("@", "REG_SZ", display)]))
        s.append((base + r"\DefaultIcon",
                  [("@", "REG_SZ", OFFICE_DIR + "\\" + exe + ",%d" % icon_idx)]))
        s.append((base + r"\shell\Open\command",
                  [("@", "REG_SZ", command)]))
    # InstallRoot -- the standard key the Office installer writes so
    # Office components can locate the install. The green Office runs
    # from its own folder, but this is the canonical lookup path.
    s.append((
        r"HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Office\16.0\Common\InstallRoot",
        [("Path", "REG_SZ", OFFICE_DIR + "\\")],
    ))
    return s


def chrome_sections():
    """Chrome: App Paths, ChromeHTML ProgID, file associations, URL
    protocols, StartMenuInternet + Capabilities + RegisteredApplications."""
    s = []
    # App Paths -- launch chrome.exe by name.
    s.append((
        r"HKEY_LOCAL_MACHINE\PE-SOFT\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        [
            ("@", "REG_SZ", CHROME_EXE),
            ("Path", "REG_SZ", CHROME_DIR),
        ],
    ))
    # ChromeHTML ProgID -- what .html/.htm and http/https resolve to.
    s.append((
        r"HKEY_LOCAL_MACHINE\PE-SOFT\Classes\ChromeHTML",
        [
            ("@", "REG_SZ", "Chrome HTML Document"),
            ("URL Protocol", "REG_SZ", ""),
        ],
    ))
    s.append((
        r"HKEY_LOCAL_MACHINE\PE-SOFT\Classes\ChromeHTML\DefaultIcon",
        [("@", "REG_SZ", CHROME_EXE + ",0")],
    ))
    s.append((
        r"HKEY_LOCAL_MACHINE\PE-SOFT\Classes\ChromeHTML\shell\open\command",
        [("@", "REG_SZ", '"' + CHROME_EXE + '" -- "%1"')],
    ))
    # File associations -- HTML extensions -> ChromeHTML.
    for ext in (".html", ".htm", ".shtml", ".xhtml", ".xht"):
        s.append((
            r"HKEY_LOCAL_MACHINE\PE-SOFT\Classes\%s" % ext,
            [("@", "REG_SZ", "ChromeHTML")],
        ))
    # URL protocols -- http / https -> ChromeHTML.
    for scheme, display in (
        ("http", "URL:HyperText Transfer Protocol"),
        ("https", "URL:HyperText Transfer Protocol with Privacy"),
    ):
        base = r"HKEY_LOCAL_MACHINE\PE-SOFT\Classes\%s" % scheme
        s.append((base, [
            ("@", "REG_SZ", display),
            ("URL Protocol", "REG_SZ", ""),
        ]))
        s.append((base + r"\DefaultIcon",
                  [("@", "REG_SZ", CHROME_EXE + ",0")]))
        s.append((base + r"\shell\open\command",
                  [("@", "REG_SZ", '"' + CHROME_EXE + '" -- "%1"')]))
    # StartMenuInternet + Capabilities -- Default Programs / default
    # browser. This is the standard per-machine Chrome registration.
    base = r"HKEY_LOCAL_MACHINE\PE-SOFT\Clients\StartMenuInternet\Google Chrome"
    s.append((base, [("@", "REG_SZ", "Google Chrome")]))
    s.append((base + r"\DefaultIcon",
              [("@", "REG_SZ", CHROME_EXE + ",0")]))
    s.append((base + r"\shell\open\command",
              [("@", "REG_SZ", '"' + CHROME_EXE + '"')]))
    s.append((base + r"\Capabilities", [
        ("ApplicationDescription", "REG_SZ",
         "Google Chrome is a web browser that runs webpages and applications "
         "with lightning speed. It's fast, stable, and easy to use."),
        ("ApplicationIcon", "REG_SZ", CHROME_EXE + ",0"),
        ("ApplicationName", "REG_SZ", "Google Chrome"),
    ]))
    s.append((base + r"\Capabilities\FileAssociations", [
        (ext, "REG_SZ", "ChromeHTML")
        for ext in (".html", ".htm", ".shtml", ".xhtml", ".xht")
    ]))
    s.append((base + r"\Capabilities\URLAssociations", [
        ("http", "REG_SZ", "ChromeHTML"),
        ("https", "REG_SZ", "ChromeHTML"),
    ]))
    s.append((base + r"\InstallInfo", [
        ("HideIconsCommand", "REG_SZ", '"' + CHROME_EXE + '" --hide-icons'),
        ("ShowIconsCommand", "REG_SZ", '"' + CHROME_EXE + '" --show-icons'),
        ("ReinstallCommand", "REG_SZ", '"' + CHROME_EXE + '" --make-default-browser'),
        ("IconsVisible", "REG_DWORD", 1),
    ]))
    # RegisteredApplications -- makes Chrome show up in Default Programs.
    s.append((
        r"HKEY_LOCAL_MACHINE\PE-SOFT\RegisteredApplications",
        [("Google Chrome", "REG_SZ",
          r"Software\Clients\StartMenuInternet\Google Chrome\Capabilities")],
    ))
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    repo = os.path.expanduser("~/workspace/MIC-PE")
    out_dir = args.out or os.path.join(repo, "app")
    office_dir = os.path.join(out_dir, "office")
    chrome_dir = os.path.join(out_dir, "chrome")
    os.makedirs(office_dir, exist_ok=True)
    os.makedirs(chrome_dir, exist_ok=True)

    write_reg(
        os.path.join(office_dir, "office.reg"),
        [
            "MICPE clean rebuild (22621.1105): Office 2016 registration.",
            "Hand-authored from the standard per-machine Office layout",
            "(App Paths, file associations, ProgID open commands,",
            "InstallRoot) -- NOT copied from the Ramos reference, whose",
            "Office entries are Office 2010 (Office14) at different",
            "paths. The reference SOFTWARE hive has no Microsoft\\Office",
            "key at all. Imported at CI mount time into the staging",
            "SOFTWARE hive (PE-SOFT), together with the clean patches.",
            "NOT included: Office COM / OLE registration (hundreds of",
            "CLSIDs, not hand-writable; the green Office opens documents",
            "without it). If full automation is ever needed, that is a",
            "separate extraction from a live Office 2016 install.",
            "Paths use X: (the PE system drive) and the vendor layout",
            "Program Files\\Office2016\\Office16 (see app/office/README.md).",
        ],
        office_sections(),
    )

    write_reg(
        os.path.join(chrome_dir, "chrome.reg"),
        [
            "MICPE clean rebuild (22621.1105): Chrome registration.",
            "Hand-authored from the standard per-machine Chrome layout",
            "the Chrome Enterprise MSI creates (App Paths, ChromeHTML",
            "ProgID, .html/.htm associations, http/https protocols,",
            "StartMenuInternet + Capabilities + RegisteredApplications)",
            "-- NOT copied from the Ramos reference, whose SOFTWARE hive",
            "has no Google key and no ChromeHTML at all. Imported at CI",
            "mount time into the staging SOFTWARE hive (PE-SOFT),",
            "together with the clean patches. Paths use X: (the PE",
            "system drive) and the vendor layout Program Files\\Google\\",
            "Chrome\\Application (see app/chrome/README.md).",
        ],
        chrome_sections(),
    )
    print("done.")


if __name__ == "__main__":
    main()

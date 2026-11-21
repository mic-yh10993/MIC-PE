# Native WinPE logon feasibility and implementation gates

**Status: investigation / gate definition only.** This document does not claim that native interactive logon works in the current MICPE image. No runtime logon implementation is enabled by this change.

## Target

On the x64 Windows 11 26H2 / 26300 WinPE image:

1. Winlogon, not `startnet.cmd`, PECMD, or a helper process, owns the interactive logon sequence.
2. Winlogon displays the genuine Windows LogonUI on the secure Winlogon desktop.
3. The built-in local Administrator account is authenticated by the image's local security authority and SAM. The intended account has RID 500 and an empty password, with the image's local-account and blank-password policies explicitly verified.
4. After successful authentication, the interactive token belongs to the built-in Administrator (`S-1-5-21-...-500`), never LocalSystem (`S-1-5-18`).
5. User initialization, profile loading, Explorer, input methods, and the requested AppX/WinRT applications work inside that authenticated user session.
6. The boot path does not invoke PECMD.

## Current branch facts

The current implementation must not be mistaken for the target:

- `src/shell/startnet.cmd` invokes `wpeinit`, then attempts to launch `PECMD.EXE`, falls back to `probe.cmd`, and finally runs `cmd.exe`.
- `src/registry/10-pe-base.reg` sets Winlogon's `Shell` to `PECMD.EXE`.
- `src/registry/20-explorer.reg` later changes `Shell` to `explorer.exe`, but explicitly sets `Userinit` to an empty string.
- `src/build/lib/Shell.ps1::Set-BootShell` copies PECMD assets when present.
- `src/filelists/70-logon.txt` lists candidate logon-related files, but the current build orchestration does not yet integrate this list as a complete Winlogon/Credential Provider/SAM implementation.
- Copying `LogonUI.exe` or starting it with `CreateProcess` does not create a secure logon session. A real logon requires the Winlogon, LogonUI, Credential Provider, LSA/authentication package, SAM, profile and user-init path to work together.

## Hard gates

Do not implement a “looks like logon” workaround. Each gate requires evidence from the exact 26300 source image and a booted VMware guest.

### Gate A — donor-image and file-set integrity

- Confirm every required binary, DLL, MUI, PRI, manifest, service, and registry dependency exists in the exact selected `install.wim` index.
- Record file version, architecture, hash, and source path for each extracted item.
- Do not reuse a 1909/22H2/25H2 file list as proof of 26300 compatibility.
- Fail the build on any missing required item; do not silently skip it.

### Gate B — actual WinPE logon path

In the booted guest, prove that:

- Winlogon is running and owns the interactive session.
- `WinSta0\\Winlogon` and `WinSta0\\Default` have the expected security-desktop relationship.
- LogonUI is started by the expected Winlogon path, not by `startnet.cmd`, PECMD, a scheduled task, or a service wrapper.
- A credential submission is handled by a supported credential provider and authentication package.
- Failed credentials remain at the logon screen and do not expose the user desktop.

A visible LogonUI process alone is insufficient evidence.

### Gate C — Administrator authentication and token

After a successful logon, capture at least:

```powershell
whoami
whoami /user
whoami /groups
whoami /priv
```

The user SID must end in `-500` and begin with the local machine SID. It must not equal `S-1-5-18`. Verify the local account is enabled, that the blank-password policy permits the intended local-console logon, and that a failed/non-empty password attempt is rejected as expected.

Do not assume `net user Administrator ""` is sufficient: first prove that the WinPE SAM contains the built-in account and that the account is enabled. Do not enable remote blank-password logon.

### Gate D — user initialization, Explorer, and UWP

Verify all of the following in the authenticated Administrator session:

- The expected user profile is loaded and `USERPROFILE` points to it.
- The normal Userinit path completes; it is not an empty registry value.
- Explorer is the user's shell, not a SYSTEM process running on the interactive desktop.
- Start menu, taskbar, desktop, and shell experience components initialize without third-party shell replacement.
- Calculator and Photos activate through AppX/WinRT in the same user session.
- The Microsoft Pinyin input method can switch layouts and accept both English and Chinese input.

### Gate E — VMware input and stability regression

On the user's 8 GB VMware test VM:

- Test English text input in Explorer search, Run, Notepad, and the Start menu.
- Test Microsoft Pinyin composition, candidate selection, commit, and switching back to English.
- Confirm mouse movement/clicks remain responsive while typing.
- Capture guest logs and crash dumps for any input freeze.
- Repeat cold boots; a single successful boot is not sufficient.

## Safe implementation order

1. Keep the current boot path unchanged while collecting Gate A/B evidence.
2. Build a disposable test image from the exact 26300 donor. Do not replace the current working image until Gate B passes.
3. Only after Gate B passes, implement and test the local Administrator account and authentication policy (Gate C).
4. Only after Gate C passes, enable normal user initialization and Explorer in the authenticated session (Gate D).
5. Run the VMware input regression (Gate E).
6. Remove PECMD from the boot path only in the tested implementation, then add static tests proving there are no PECMD launch references in the native-logon boot path.
7. Preserve a known-good rollback image and report each gate as PASS, FAIL, or BLOCKED with logs.

## Stop conditions and fallback

Stop and do not claim native logon if any of these are true:

- WinPE does not create a supported local interactive Winlogon session.
- The required Credential Provider or authentication package cannot operate in the WinPE configuration.
- The built-in Administrator account is absent or cannot be authenticated locally.
- The session token is SYSTEM rather than the RID-500 Administrator.
- Userinit/profile/AppX initialization only works by bypassing the normal authenticated logon path.

If the exact WinPE build cannot support the required logon semantics, the honest alternatives are:

1. Keep WinPE as a SYSTEM-based maintenance environment and clearly label any front-end as a custom UI, not a Windows user logon; or
2. Use a full Windows-derived RAM-boot environment with a supported interactive logon stack.

Do not disguise either fallback as native WinPE Administrator authentication.

# Mac Pro 5,1 SATA Hot-Plug Fix for macOS Sequoia

Fix for SATA drives (especially newer models like WD Red Plus) that disappear after a **soft reboot** on Mac Pro 5,1 (and potentially other systems using the Intel ICH10 AHCI controller) running macOS Sequoia via OpenCore Legacy Patcher.

## The Problem

After a soft reboot (`sudo reboot`), certain SATA drives connected to the **ICH10 AHCI controller** (PCI `00:1F.2`, device-id `0x3a22`) fail to appear in macOS. The drive only works after a full shutdown + power-on or an SMC reset.

This affects drives in the Mac Pro's optical bay and potentially other ICH10 ports. The issue does **not** affect drives on the secondary AHCI controller (`0B:00.0`) which has native hot-plug support.

## Root Cause

The failure is a three-link chain in Apple's `AppleAHCIPort` kext:

### 1. No Hot-Plug Threads on ICH10 Ports

The ICH10 controller's AHCI ports lack the `AHCI Port Hot Plug` capability flag. Without this, `AppleAHCIPort` never creates background hot-plug monitoring threads for these ports.

### 2. Stale SATA Link After Soft Reboot

The Mac Pro 5,1 does not fully cut SATA bus power during a soft reboot. The SATA PHY link remains established (PxSSTS DET=3) from the previous boot session. The drive is technically "connected" at the physical layer but hasn't completed a fresh initialization handshake.

### 3. Driver Skips COMRESET When Link Is Present

In `EnablePortOperation`, the driver enables FIS Receive (`SetFRE(true)`) then checks `WaitForLinkPresent()`. If a link is already present (DET=3), it **skips** `HandleComReset()` and goes directly to `ScanForDevices()`. But since the link is stale:

- **PxSIG** (Port Signature) contains garbage/stale data from the previous session
- `ScanForDevices` checks PxSIG — if it's not `0x00000101` (ATA) or `0xEB140101` (ATAPI), it silently skips device creation
- No `IOAHCIDevice` is published → no disk visible to macOS

After a full power cycle, the drive sends a fresh **D2H Register FIS** during link-up, populating PxSIG correctly. That's why cold boot always works.

## The Fix

Three components, all configured via OpenCore:

### Component 1: SSDT — Break Stale SATA Link

An ACPI SSDT that runs at early boot (`_INI` method) and takes ICH10 Port 1 offline:

1. Reads the AHCI Base Address Register (ABAR) from PCI config space
2. Checks if a stale link is present (DET=3)
3. Stops the command engine (clears CMD.ST, waits for CMD.CR to clear)
4. Takes the port offline (SCTL.DET=4), waits 100ms
5. Returns to listen mode (SCTL.DET=0)

This breaks the stale link so the driver finds DET=0, triggering its own `HandleComReset()` with FIS Receive properly enabled.

**Source:** [`ACPI/SSDT-COMRESET.dsl`](ACPI/SSDT-COMRESET.dsl)  
**Compiled:** [`ACPI/SSDT-COMRESET.aml`](ACPI/SSDT-COMRESET.aml)

### Component 2: Kernel Patch — Force Hot-Plug Threads

Patches `AppleAHCIPort` to create hot-plug monitoring threads on all AHCI ports, regardless of the controller's Hot Plug capability flag.

| Field | Value |
|-------|-------|
| **Identifier** | `com.apple.driver.AppleAHCIPort` |
| **Comment** | Force SATA Hot-Plug thread creation (Sequoia) |
| **Find** | `F6836D010000 44 7446` |
| **Replace** | `F6836D010000 44 9090` |
| **Find (Base64)** | `9oNtAQAARHRG` |
| **Replace (Base64)** | `9oNtAQAARJCQ` |
| **MinKernel** | `24.0.0` |
| **Count** | `1` |

**What it does:** NOPs a `je` (jump-if-equal) instruction that skips hot-plug thread creation when the port lacks the Hot Plug capability bit. After patching, all ports get threads.

### Component 3: Kernel Patch — Force HandleComReset

Patches `AppleAHCIPort` to always call `HandleComReset()` during port initialization, even when a SATA link is already present.

| Field | Value |
|-------|-------|
| **Identifier** | `com.apple.driver.AppleAHCIPort` |
| **Comment** | Force HandleComReset on all AHCI ports (Sequoia) |
| **Find** | `A801 7433 8BB388000000` |
| **Replace** | `A801 9090 8BB388000000` |
| **Find (Base64)** | `qAF0M4uziAAAAA==` |
| **Replace (Base64)** | `qAGQkIuziAAAAA==` |
| **MinKernel** | `24.0.0` |
| **Count** | `1` |

**What it does:** NOPs a `je` instruction in `EnablePortOperation` that normally skips `HandleComReset()` when `WaitForLinkPresent()` succeeds. After patching, `HandleComReset()` always runs, ensuring a fresh COMRESET + D2H FIS exchange with FRE enabled.

## Installation

### Prerequisites

- Mac Pro 5,1 (or similar system with ICH10 AHCI controller)
- macOS Sequoia (kernel 24.x) via [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/)
- [iasl](https://github.com/acpica/acpica) (only if recompiling the SSDT)

### Steps

1. **Mount your EFI partition:**
   ```bash
   sudo diskutil mount disk<N>s1  # your boot disk's EFI partition
   ```

2. **Copy the SSDT:**
   ```bash
   cp ACPI/SSDT-COMRESET.aml /Volumes/EFI/EFI/OC/ACPI/
   ```

3. **Register the SSDT** in `config.plist` under `ACPI → Add`:
   ```xml
   <dict>
       <key>Comment</key>
       <string>COMRESET ICH10 Port 1 - break stale SATA link</string>
       <key>Enabled</key>
       <true/>
       <key>Path</key>
       <string>SSDT-COMRESET.aml</string>
   </dict>
   ```

4. **Add the kernel patches** in `config.plist` under `Kernel → Patch`. See [`config-sample.plist`](config-sample.plist) for the full XML snippets.

5. **Validate and reboot:**
   ```bash
   plutil -lint /Volumes/EFI/EFI/OC/config.plist
   sudo reboot
   ```

### Verification

After reboot, check that the drive appeared:
```bash
diskutil list | grep -i "WD\|backup"
```

Check kernel logs for COMRESET activity on the port:
```bash
log show --last boot --predicate 'sender == "AppleAHCIPort"' --info | grep "001F0210"
```

You should see `HandleComReset` activity and `IOAHCIDevice` creation for the port.

## Customizing for Different Ports

The SSDT targets **Port 1** (AHCI offset `0x180`). To target a different ICH10 port, modify the `OperationRegion` offset in the DSL:

| Port | Offset |
|------|--------|
| 0 | `0x100` |
| 1 | `0x180` |
| 2 | `0x200` |
| 3 | `0x280` |
| 4 | `0x300` |
| 5 | `0x380` |

Recompile with: `iasl ACPI/SSDT-COMRESET.dsl`

## Compatibility

- **Tested on:** Mac Pro 5,1, macOS 15.x Sequoia, OpenCore Legacy Patcher
- **Kernel:** Darwin 24.x (set `MinKernel` accordingly for other versions)
- **Controller:** Intel ICH10 AHCI (device-id `0x3a22`) — may work with other Intel AHCI controllers lacking native hot-plug

> **Note:** The kernel patch byte sequences are specific to macOS Sequoia (kernel 24.x). Other macOS versions will have different byte patterns and require re-analysis of the `AppleAHCIPort` binary.

## Adapting This to Ventura / Other AHCI Controllers

Warm-reboot-only AHCI failures, including repeated `IOAHCIBlockStorage` `CommandTimeout`/`WatchdogTimeout` errors on probe commands like `0xEC` and `0xF5`, are not specific to a stale link or a skipped `HandleComReset()`; power, cabling, device, and controller faults can produce similar symptoms. Treat the stale-link path as a hypothesis, and confirm mechanism-specific evidence (such as DET=3 with stale PxSIG and the driver skipping `HandleComReset()`) before attempting invasive kernel patches.

### Re-deriving `AppleAHCIPort` Patch Offsets (per macOS build)

Use the exact `AppleAHCIPort` binary from the target OS (for example Ventura 13.7.x), then re-derive offsets in disassembly:

1. Copy the target binary:
   ```bash
   cp /System/Library/Extensions/AppleAHCIPort.kext/Contents/MacOS/AppleAHCIPort ~/Desktop/AppleAHCIPort-target
   ```
2. Open in Hopper/Ghidra/IDA and find `EnablePortOperation` (or the block that calls `WaitForLinkPresent()` and `HandleComReset()`).
3. If analysis confirms that this conditional jump skips `HandleComReset()` in the affected case, patch only that jump (typically to `NOP NOP`).
4. Locate the hot-plug capability gate (`AHCI Port Hot Plug` bit test) in the port-init path, and patch the jump that skips hot-plug thread creation.
5. Only after confirming the relevant mechanism and target-build control flow, build OpenCore `Find/Replace` signatures using surrounding bytes (not absolute offsets), with `Count=1` and kernel-range limits (`MinKernel`/`MaxKernel`) for that OS version.

Practical safety checks:

- Ensure each `Find` pattern matches exactly once.
- If a pattern matches multiple locations, include more neighboring bytes until unique.
- Bring patches up one at a time to isolate regressions.

### What Usually Generalizes vs What Is Platform-Specific

The PHY-level stale-link break (`PxSCTL.DET = 4` then `0`) is AHCI-spec behavior and often portable across Intel AHCI controllers.

Platform-specific parts that must be revalidated:

- ACPI device path (`_SB.PCI0.SATA` vs `SAT0`, etc.)
- PCI BAR/ABAR access method in ACPI
- Actual port base offset (verify whether the `0x100 + port * 0x80` formula applies)
- Timing margins (`Sleep()` values)

Avoid whole-device `_PS0`/`_PS3` power-cycling unless validated on your board/firmware, since that path is much more platform-dependent and can boot-loop.

## Technical Deep Dive

### Why Earlier SSDT Versions Failed

| Version | Approach | Failure |
|---------|----------|---------|
| v1–v3 | COMRESET from ACPI with various delays | PxSIG never updated (FRE was off) |
| v4 | COMRESET + early exit if DET=3 | Skipped on soft reboot — DET was always 3 |
| v5 | Full SUD power cycle + COMRESET + long waits | FRE was off → D2H FIS lost → PxSIG remained stale |
| **v6** | **Break stale link only (DET=4→0)** | **Works — driver handles COMRESET with FRE enabled** |

The key insight: ACPI runs before the driver enables FIS Receive. Any COMRESET done from ACPI will succeed at the PHY layer (link re-established, DET=3), but the drive's D2H Register FIS response is silently dropped because there's no FIS receive buffer to catch it. The driver then sees DET=3, assumes the existing link is valid, and reads stale PxSIG.

The solution is to **not** do COMRESET from ACPI. Instead, break the stale link and let the driver do its own COMRESET through `HandleComReset()`, which properly enables FRE first.

### AHCI Register Flow (Working Case)

```
SSDT _INI:          DET=4 (offline) → DET=0 (listen)
                         ↓
Driver EnablePortOperation:
  SetFRE(true)      ← FIS Receive now enabled
  WaitForLinkPresent → DET=0, no link
  HandleComReset:
    CMD.ST=0        ← Stop command engine
    SCTL.DET=1      ← Issue COMRESET
    sleep 1ms
    SCTL.DET=0      ← Return to normal
    WaitForLinkPresent → Drive re-links → DET=3
    WritePxSERR(0xFFFFFFFF)  ← Clear errors
                         ↓
  ScanForDevices:
    PxSIG = 0x101   ← Fresh D2H FIS received (FRE was on!)
    → CreateDevice  ← IOAHCIDevice published
                         ↓
  IOAHCIBlockStorage → disk appears in macOS
```

## License

MIT

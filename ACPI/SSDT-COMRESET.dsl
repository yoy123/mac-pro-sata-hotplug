/*
 * SSDT-COMRESET v6 — Break stale SATA link for driver-managed COMRESET
 *
 * Problem: During soft reboot, Mac Pro 5,1 doesn't cut SATA power.
 * The SATA link stays up (DET=3) from the previous session. When
 * AppleAHCI finds DET=3, it skips HandleComReset and goes straight
 * to ScanForDevices. But PxSIG is stale → no IOAHCIDevice created.
 *
 * v4-v5 tried to COMRESET from ACPI, but since FRE (FIS Receive
 * Enable) was off, the drive's D2H Register FIS was lost and PxSIG
 * remained stale.
 *
 * v6 fix: Simply take the port offline (DET=4) to break the stale
 * link, then return to listen mode (DET=0). When the driver starts,
 * it finds DET=0, calls HandleComReset() with proper FRE already
 * enabled, and the drive sends a fresh D2H FIS → PxSIG = 0x101 →
 * CreateDevice succeeds.
 *
 * Diagnostic result codes in XRES:
 *  0x01 = Port was taken offline (stale link broken)
 *  0x02 = Port had no link initially (nothing to do)
 *  0xE1 = ABAR is zero
 */
DefinitionBlock ("", "SSDT", 2, "CUSTOM", "COMRESET", 0x00006000)
{
    External (_SB_, DeviceObj)
    External (_SB_.PCI0.SATA, DeviceObj)

    Scope (\_SB.PCI0.SATA)
    {
        OperationRegion (PCFG, PCI_Config, 0x24, 0x04)
        Field (PCFG, DWordAcc, NoLock, Preserve)
        {
            APTS,   32
        }

        Method (CRST, 0, Serialized)
        {
            Local0 = APTS
            Local0 &= 0xFFFFFFF0
            If ((Local0 == Zero))
            {
                \_SB.PRST.XRES = 0xE1
                Return (Zero)
            }

            \_SB.PRST.XBAR = Local0

            /*
             * Port 1 registers at ABAR + 0x180
             * PxCMD  = offset 0x18
             * PxTFD  = offset 0x20
             * PxSIG  = offset 0x24
             * PxSSTS = offset 0x28
             * PxSCTL = offset 0x2C
             * PxSERR = offset 0x30
             */
            OperationRegion (AHC1, SystemMemory, (Local0 + 0x0180), 0x34)
            Field (AHC1, DWordAcc, NoLock, Preserve)
            {
                Offset (0x18),
                PCMD,   32,
                Offset (0x20),
                PTFD,   32,
                PSIG,   32,
                PSST,   32,
                PCTL,   32,
                PERR,   32
            }

            /* Record initial state */
            \_SB.PRST.XCM0 = PCMD
            \_SB.PRST.XSS0 = PSST
            \_SB.PRST.XTF0 = PTFD
            \_SB.PRST.XSG0 = PSIG

            /* If no link present (DET != 3), nothing to clear */
            If (((PSST & 0x0F) != 0x03))
            {
                \_SB.PRST.XRES = 0x02
                Return (Zero)
            }

            /* ============================================
             * Take the port offline to break the stale link.
             * The driver's EnablePortOperation will then find
             * DET=0 and call HandleComReset() with proper FRE.
             * ============================================ */

            /* Stop command engine: clear ST (bit 0) */
            PCMD &= 0xFFFFFFFE
            Sleep (10)

            /* Wait for CR (bit 15) to clear */
            Local1 = Zero
            While ((Local1 < 50))
            {
                If (((PCMD & 0x8000) == Zero))
                {
                    Break
                }
                Sleep (10)
                Local1++
            }

            /* Clear all errors */
            PERR = 0xFFFFFFFF

            /* Take interface offline: DET = 4 */
            Local3 = (PCTL & 0xFFFFFFF0)
            PCTL = (Local3 | 0x04)
            Sleep (100)   /* 100ms for PHY to go down */

            /* Return to listen mode: DET = 0  */
            /* Drive will NOT re-establish link without COMRESET */
            PCTL = Local3
            Sleep (50)

            /* Record final state */
            \_SB.PRST.XCM1 = PCMD
            \_SB.PRST.XSS1 = PSST
            \_SB.PRST.XSG1 = PSIG

            \_SB.PRST.XRES = 0x01
            Return (One)
        }
    }

    Scope (\_SB)
    {
        Device (PRST)
        {
            Name (_HID, "PRST0001")
            Name (_STA, 0x0B)
            Name (XBAR, Zero)
            /* Initial state */
            Name (XCM0, Zero)
            Name (XSS0, Zero)
            Name (XTF0, Zero)
            Name (XSG0, Zero)
            /* After offline */
            Name (XCM1, Zero)
            Name (XSS1, Zero)
            Name (XSG1, Zero)
            /* Result */
            Name (XRES, Zero)

            Method (_INI, 0, NotSerialized)
            {
                \_SB.PCI0.SATA.CRST ()
            }
        }
    }
}

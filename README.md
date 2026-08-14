Get-AutopilotHash-Hardened-v3.ps1 — the improved collector. New -PreferIPv4 switch writes DisabledComponents = 0x20 (idempotent, checks current value first, flags the reboot). -Prep now means -FixTime -PreferIPv4. The old hard unbind is still there under -DisableIPv6 if you ever need it. New -Upload -UploadTarget SharePoint|ServiceNow at the tail, both PS 5.1-safe, both reading secrets from AP_SP_* / AP_SNOW_* env vars.

Remove-DeviceObjects.ps1 — the reformat cleanup, run from your admin box. Dry-run by default; add -Commit to actually delete. Handles on-prem AD, Entra, and optionally the Intune record. The device-side dsregcmd /leave note is at the bottom for the pre-wipe case.

Two things to sort before you run the upload path:

For ServiceNow, don't point AP_SNOW_TABLE at cmdb_ci_computer directly — write to a small staging table (u_autopilot_import or similar) and let a flow/business rule reconcile into the CMDB. Writing raw hashes straight onto CI records gets messy and you lose the audit trail. The attachment goes on whatever table you name.

For SharePoint, I scoped the comment toward Sites.Selected rather than Sites.ReadWrite.All — for a behavioral-health shop that tenant-wide write scope is the kind of thing that shows up in an audit finding. Sites.Selected grants the app only to the one asset library, which is the posture you'd want to defend. Worth the extra five minutes in the app registration.

On the reboot for 0x20: since it needs a restart to take effect, decide whether you want this applied during your image build (bake it into the reference image / provisioning package so every machine ships with it) versus applying it at OOBE where the timing is fiddlier. Baking it in is cleaner if you control the image.

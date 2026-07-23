# Privacy Policy

**Effective date:** 2026-07-12
**Applies to:** LumiVault for macOS (bundle identifier `app.lumivault`), including the Mac App Store release

LumiVault is a local-first photo archiving app. It is designed so that your photos, metadata, and credentials stay on your own devices and inside services you yourself control. This document describes exactly what the app does and does not do with your data.

## Short version

- LumiVault does not collect, transmit, or share any personal information with the developer.
- There is no analytics, no telemetry, no crash reporting, no advertising, and no third-party SDKs of any kind.
- Your photos and catalog stay on your Mac, on external drives you choose, and — only if you opt in — in your own iCloud Drive and your own Backblaze B2 bucket.
- The developer never sees your photos, your catalog, your B2 credentials, or your payment information.

## Data the app handles

### Photos and metadata
When you import an album, LumiVault reads photos and videos and their metadata (EXIF, file dates, perceptual hashes, SHA-256 hashes) from your Apple Photos library or from files you drag in. Originals in Apple Photos are never modified.

Imported photos and videos are written to:

- The local library folder at `~/Pictures/LumiVault` on your Mac.
- The external volumes you have added in **Settings → Volumes**.
- Your Backblaze B2 bucket, only if you have enabled B2 in **Settings → B2**.

A `catalog.json` index describing your archive is written to `~/Pictures/LumiVault` (or a custom location you configure in **Settings → General**) and, if iCloud sync is enabled, mirrored through your own iCloud Drive container (`iCloud.app.lumivault`). A copy of `catalog.json` is also distributed to every volume and to B2 as a backup. Catalogs created by earlier versions in the app sandbox container are migrated to `~/Pictures/LumiVault` automatically on launch.

### Settings sync (iCloud)
If iCloud sync is enabled, a `settings.json` document is synced through the same iCloud container alongside the catalog so your preferences follow you across Macs. It contains only configuration: import preferences (format, JPEG quality, maximum dimension, PAR2 and near-duplicate options, redundancy percentage), whether B2 is enabled and the bucket name, whether encryption is enabled plus the PBKDF2 salt and a key identifier (see below), and the names and identifiers of the volumes registered on each Mac. It never contains photos, thumbnails, your B2 application key, or your encryption passphrase.

### Backblaze B2 credentials
If you enable B2 cloud upload, your B2 application key ID and application key are stored in the macOS Keychain. By default the Keychain item is device-only — it never leaves your Mac. You can optionally enable **Sync credentials via iCloud Keychain** in **Settings → B2** (off by default) to store the item in iCloud Keychain so your other Macs can use B2 without re-entering the key; iCloud Keychain sync is handled entirely by Apple. Credentials saved by versions prior to v1.0.0, which used `UserDefaults`, are migrated into the Keychain on first launch and the old plaintext copy is removed.

The credentials are sent only to `api.backblazeb2.com` and the upload endpoints Backblaze returns to the app. The developer cannot read these credentials.

### Encryption keys
If you enable per-file encryption, the passphrase you enter is used to derive an AES-256-GCM key via PBKDF2. The passphrase is held in memory for the duration of the operation. LumiVault does not transmit it anywhere.

If iCloud sync is enabled, the PBKDF2 salt and a key identifier are included in the synced `settings.json` so the same passphrase derives the same key on your other Macs. The salt is not a secret — neither it nor the key identifier reveals your passphrase or your encryption key, and neither the passphrase nor the derived key is ever synced or transmitted.

### Apple Photos library access
LumiVault requests read-only access to your Apple Photos library so it can enumerate albums and export assets. This access is mediated by macOS and can be revoked at any time in **System Settings → Privacy & Security → Photos**.

### Tip jar (in-app purchases)
The optional tip jar uses Apple StoreKit. Payment is handled entirely by Apple. LumiVault receives only a signed transaction receipt confirming the purchase; it never sees your Apple ID, payment method, billing address, or any other purchase detail.

## Network connections the app makes

LumiVault makes outbound network requests only to:

| Destination | When | Purpose |
| --- | --- | --- |
| Backblaze B2 API (`*.backblazeb2.com`) | Only if you enable B2 | Upload, list, download, and delete files in **your** bucket using **your** credentials (including re-downloading files to regenerate thumbnails on a second Mac) |
| Apple iCloud Drive | Only if iCloud sync is enabled on your Mac | Sync `catalog.json` and `settings.json` through **your** iCloud account |
| Apple iCloud Keychain | Only if you enable **Sync credentials via iCloud Keychain** | Sync your B2 credentials to your other Macs through Apple's Keychain sync |
| Apple StoreKit | Only when you tap a tip jar item | Process the purchase through Apple |

LumiVault does not contact any developer-controlled server. There is no analytics endpoint, no update server, no "phone home" of any kind.

## Data the developer collects

**None.** The developer of LumiVault does not operate any backend service that receives data from the app. The developer cannot see what you import, which volumes you use, whether you enable B2, or whether you make a tip jar purchase.

If you installed LumiVault from the Mac App Store, Apple may share aggregated, anonymized App Store analytics (downloads, crashes) with the developer — but only if you have opted in to sharing analytics with app developers in your Apple account settings. This is governed by Apple's privacy policy, not by anything the app itself does.

## Permissions LumiVault requests

The app is sandboxed and requests only the permissions it strictly needs:

- **Photos Library** — to import albums you choose.
- **Pictures folder access** — to store the local library and `catalog.json` at `~/Pictures/LumiVault`.
- **User-selected file access** — to read files you drag in and write to volumes you add.
- **App-scoped bookmarks** — to remember the external volumes you have added so you do not have to reselect them on every launch.
- **Outgoing network connections** — for Backblaze B2 uploads (only when enabled).
- **iCloud container** (`iCloud.app.lumivault`) — for catalog and settings sync (only when iCloud Drive is enabled on your Mac).

## Children

LumiVault is a general-purpose archiving tool. It is not directed at children under 13 and does not knowingly collect any data from anyone.

## Your control

Because nothing leaves your devices to the developer, you do not need to ask anyone to delete your data. To remove LumiVault data from your systems:

- **From your Mac** — delete the LumiVault app and the library folder at `~/Pictures/LumiVault`. The sandbox container at `~/Library/Containers/app.lumivault` can also be removed. B2 credentials can be removed by deleting the `app.lumivault.credentials` item in Keychain Access (if iCloud Keychain sync was enabled, deleting the item removes it from all synced devices).
- **From iCloud Drive** — delete the `iCloud.app.lumivault` container from iCloud Drive in Finder, or from another signed-in device.
- **From a volume** — delete the photo files and accompanying `.par2` files, plus any `catalog.json` copy on that volume.
- **From Backblaze B2** — delete files directly through the Backblaze console, or use the in-app deletion and reconciliation tools.

## Changes to this policy

If this policy changes in a way that materially affects you, the updated version will be published in this repository and a summary will appear in the app's release notes. The **Effective date** at the top of this document indicates the latest revision.

## Contact

Questions about this policy or LumiVault's privacy practices: open an issue at <https://github.com/wpowiertowski/lumivault.app/issues>.

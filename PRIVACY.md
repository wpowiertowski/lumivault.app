# Privacy Policy

**Effective date:** 2026-05-25
**Applies to:** LumiVault for macOS (bundle identifier `app.lumivault`)

LumiVault is a local-first photo archiving app. It is designed so that your photos, metadata, and credentials stay on your own devices and inside services you yourself control. This document describes exactly what the app does and does not do with your data.

## Short version

- LumiVault does not collect, transmit, or share any personal information with the developer.
- There is no analytics, no telemetry, no crash reporting, no advertising, and no third-party SDKs of any kind.
- Your photos and catalog stay on your Mac, on external drives you choose, and — only if you opt in — in your own iCloud Drive and your own Backblaze B2 bucket.
- The developer never sees your photos, your catalog, your B2 credentials, or your payment information.

## Data the app handles

### Photos and metadata
When you import an album, LumiVault reads photos and their metadata (EXIF, file dates, perceptual hashes, SHA-256 hashes) from your Apple Photos library or from files you drag in. Originals in Apple Photos are never modified.

Imported photos are written to:

- The external volumes you have added in **Settings → Volumes**.
- Your Backblaze B2 bucket, only if you have enabled B2 in **Settings → B2**.

A `catalog.json` index describing your archive is written to your app sandbox container and, if iCloud sync is enabled, mirrored through your own iCloud Drive container (`iCloud.app.lumivault`). A copy of `catalog.json` is also distributed to every volume and to B2 as a backup.

### Backblaze B2 credentials
If you enable B2 cloud upload, your B2 application key ID and application key are stored locally in `UserDefaults` inside the app sandbox. They are sent only to `api.backblazeb2.com` and the upload endpoints Backblaze returns to the app. The developer cannot read these credentials.

### Encryption keys
If you enable per-file encryption, the passphrase you enter is used to derive an AES-256-GCM key via PBKDF2. The passphrase is held in memory for the duration of the operation. LumiVault does not transmit it anywhere.

### Apple Photos library access
LumiVault requests read-only access to your Apple Photos library so it can enumerate albums and export assets. This access is mediated by macOS and can be revoked at any time in **System Settings → Privacy & Security → Photos**.

### Tip jar (in-app purchases)
The optional tip jar uses Apple StoreKit. Payment is handled entirely by Apple. LumiVault receives only a signed transaction receipt confirming the purchase; it never sees your Apple ID, payment method, billing address, or any other purchase detail.

## Network connections the app makes

LumiVault makes outbound network requests only to:

| Destination | When | Purpose |
| --- | --- | --- |
| Backblaze B2 API (`*.backblazeb2.com`) | Only if you enable B2 | Upload, list, download, and delete files in **your** bucket using **your** credentials |
| Apple iCloud Drive | Only if iCloud sync is enabled on your Mac | Sync `catalog.json` through **your** iCloud account |
| Apple StoreKit | Only when you tap a tip jar item | Process the purchase through Apple |

LumiVault does not contact any developer-controlled server. There is no analytics endpoint, no update server, no "phone home" of any kind.

## Data the developer collects

**None.** The developer of LumiVault does not operate any backend service that receives data from the app. The developer cannot see what you import, which volumes you use, whether you enable B2, or whether you make a tip jar purchase.

## Permissions LumiVault requests

The app is sandboxed and requests only the permissions it strictly needs:

- **Photos Library** — to import albums you choose.
- **User-selected file access** — to read files you drag in and write to volumes you add.
- **App-scoped bookmarks** — to remember the external volumes you have added so you do not have to reselect them on every launch.
- **Outgoing network connections** — for Backblaze B2 uploads (only when enabled).
- **iCloud container** (`iCloud.app.lumivault`) — for catalog sync (only when iCloud Drive is enabled on your Mac).

## Children

LumiVault is a general-purpose archiving tool. It is not directed at children under 13 and does not knowingly collect any data from anyone.

## Your control

Because nothing leaves your devices to the developer, you do not need to ask anyone to delete your data. To remove LumiVault data from your systems:

- **From your Mac** — delete the LumiVault app. The sandbox container at `~/Library/Containers/app.lumivault` can also be removed.
- **From iCloud Drive** — delete the `iCloud.app.lumivault` container from iCloud Drive in Finder, or from another signed-in device.
- **From a volume** — delete the photo files and accompanying `.par2` files, plus any `catalog.json` copy on that volume.
- **From Backblaze B2** — delete files directly through the Backblaze console, or use the in-app deletion and reconciliation tools.

## Changes to this policy

If this policy changes in a way that materially affects you, the updated version will be published in this repository and a summary will appear in the app's release notes. The **Effective date** at the top of this document indicates the latest revision.

## Contact

Questions about this policy or LumiVault's privacy practices: open an issue at <https://github.com/wpowiertowski/lumivault.app/issues>.

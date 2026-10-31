# Totality — Module Contracts

Modules never import each other. They meet through `ContentRef` and `ModuleRegistry` in `TotalityCore`.
A new contract is recorded here before it is implemented.

| From | To | Contract | State |
|---|---|---|---|
| any | Messages | attach a `ContentRef` to a message | not built |
| Reader | Player | Listen plays through the shared player | **changed, see below** |
| Calendar | Reader | an event may attach a Reader item through `ContentProvider` | built |
| Calendar | Calls | an event may attach a call ref | not built |
| AI | Reader, Calendar, Money | read `ContentRef` lists under a grant | not built |
| Social | Messages | social DMs are Messages threads | not built |

## Reader

`ReaderModule` handles `note` and `file` content. It does not claim `doc` until rich documents exist
(proposal §11-M), so a `doc` ref draws its preview chip.

The proposal had Listen hand an audio `ContentRef` to the player. On-device speech produces no audio
file, so there is nothing to refer to. Listen lives in `TotalityReader` as `ListenController` for now.
When the Player module starts, the transport (play, pause, skip, speed, queue) moves behind a protocol
in `TotalityCore`, and Listen and music both play through it.

## Attaching across modules

A module offers content through `ContentProvider`, and `ModuleRegistry.providers(for:)` lists what a module can attach, which is everything except its own. Only a `ContentRef` crosses over, so Calendar never imports the Reader. A ref's preview title lives inside the sealed event. `current(_:)` re-reads it, so a renamed item shows its new title and a deleted one says it's gone instead of leaving a dead link. The app opens a ref by handing its ID to the owning module.

## Calendar

Spec: issue #12. An event is one sealed blob with its times inside, so storage shows only an ID. Events use their own key purpose, so a Reader blob can't open as an event, and the ID inside must match the one outside.

- All-day events are midnight GMT on their first and last days, so they're plain dates in any zone. Timed events repeat in their own zone, so 3 PM at home stays 3 PM at home while the person travels.
- Repeats that don't exist, like the 31st of a short month, are skipped rather than moved. Editing one occurrence adds it to `skipped` and makes a standalone event.
- Device calendars are read through EventKit, held in memory, and never written to Totality's storage. Totality doesn't encrypt them, and the UI says so. Only opaque calendar IDs are kept, in `UserDefaults`, to remember which are hidden.
- A reminder gives the operating system the title and time only, outside Totality's encryption. Locations and notes never go with it.
- Reader and Calendar share one root key, so `ContentRootKey.loadOrCreate(in:sealedIn:)` has to count every module's storage. A key is only created when nothing anywhere is sealed under a missing one.
- Sync waits for key backup, because each device still has its own key. Reminders are also planned per device.
- Sealed events go into device backups as ciphertext, but the key doesn't, so a restore lands on the missing-key screen until key backup exists. That's why the screen doesn't say events stay on this device.
- App-switcher snapshots can hold event text, the same as the Reader. Both need a privacy screen before Phase 3.

## Key backup

Spec: issue #17. A device's content key is locked by a recovery key in Matrix's secret storage format, `m.secret_storage.v1.aes-hmac-sha2`, and stored as Matrix account data and in `key_backups`. Both copies are the same ciphertext. Only the recovery key opens them, and it's never written anywhere.

- `supabase/functions/matrix-login` turns a Supabase sign-in into a one-minute pass with the person's handle, because Supabase identifies people by ID and Matrix by name. Its private key is in Supabase's secrets, and the public half is in `server/tuwunel.toml`. The pass is signed for `matrix.usetotality.com`.
- A Matrix session lasts for one job and then signs out, so no Matrix token is stored on a device.
- `key_backups` allows no client update or delete, so a stolen session can't replace or erase a backup. Replacing a recovery key will need a server-side flow.
- `ContentKeyRing` is the only code that moves content between keys. The old key is saved, then the new key, and only then does any blob change, so a crash at any point resumes on the next launch. Each moved blob is read back before going on. A blob neither key opens is left alone, and the old key stays on the device.
- Any new sealed module must declare its blobs in `sealedPurposes`, be added to `ContentSetup.keyRing()`, and close its vault in the app's `willMove`, or a key move will leave it behind. A vault closes before the move lists blobs, because anything written after that under the old key would be lost.
- A device's key belongs to the first account that claims it, in `content-key-owner`. Content isn't kept per account yet, so without this a second person signing in could lock the first person's key into their own backup. Per-account storage replaces this when sync lands.
- A joined device remembers the backup's fingerprint, not its ID, so a server can't swap the contents behind the same ID. A backup is never written over a different one on Matrix.
- `fetchBackup` returns nil only when both servers answer that there's nothing. An outage must never read as "no backup", because that invites a second recovery key.
- A handle is retired for good when its profile is deleted, because Matrix finds accounts by name and the next owner would inherit the old account.

## Sharing an item

A `ReaderShare` is a snapshot: a sealed copy of the body and a sealed header under a random key made for
that one share, plus that key wrapped to the grantee. The header holds title, kind, and MIME type only.
Collection names and Listen position stay in the owner's metadata blob.

The wrapped key is never derived from the root key. Per-object keys never change, so wrapping one would
give the grantee every past and future revision for good, leaving revocation enforced only by the
server, and would let a former grantee forge a body the owner accepts. Security review found this.

**Sync needs a schema change.** A snapshot is its own blob, but `content_shares` has no column for it and
Storage reads follow `content_objects.storage_key`. Add that before Reader sharing reaches the server.
Documents that stay live for several people belong in a Matrix room (proposal §6.3), which rotates keys.

A wrapped key is an anonymous sealed box, so it does not prove who shared the item. The sharer's name
comes from the server. Any UI that shows it must not imply otherwise until shares are signed.

## Profile

Agreed with the owner on 2026-10-30. The account page becomes the signed-in person's profile: photo, display name, `@handle`, bio, and an edit screen. Sign-out and device status move to a settings page.

- Everything on a profile is public and unencrypted, and the edit screen says so. It lives in Supabase, per proposal §4's public directory.
- The handle is the username. The profile row is made the first time it's needed, so nobody picks a handle twice.
- Photos are rebuilt on the device as a 512-pixel square JPEG, which drops location, time, and camera details. Files go to the public `avatars` bucket under the owner's folder, and each change gets a new name.
- Followers, posts, and viewing other people's profiles are not here. Follows and posts wait for Phase 2, and viewing others waits for search.
- Before showing other people's photos: treat `avatars` as hostile input. The bucket's JPEG rule checks the declared type, not the bytes, and a client can skip the device's rebuild.
- Before adding profile visibility controls: a photo stays readable by anyone holding its URL, so a block or a move to private has to change the file's name.

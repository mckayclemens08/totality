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

`ReaderModule` handles `note` and `file` content. Notes became docs in the Reader upgrade, and they
kept the `note` content kind and their IDs so that existing items, refs, and sync rows carry on. Nothing
uses the `doc` kind yet, so a `doc` ref draws its preview chip.

A doc's body is a small Markdown subset inside the sealed blob: headings, bold, italic, bullet and
numbered lists, and links. `DocText` reads and writes it, and an old plain note opens as it always did.
Only `http`, `https`, and `mailto` links open. Anything else stays as text.

Folders are sealed items, travelling as `note` rows, so the server can't tell a folder from a doc or
see a name. An item names its parent inside its sealed details. A missing parent or a loop puts an item
at the top level, because a sync can deliver them in any order. The old collections became folders
with an ID derived from the name and the root key, so two devices migrating alone land on one folder
and the same name gives a different ID on every account. The brief's Speechify Library import was
removed on 2026-10-31 at the owner's request ("I don't want it anymore"): it only ever filled a folder,
and any file can go in any folder.

Deleted items stay sealed in Recently Deleted for 30 days, then they're removed the next time the
Reader loads or syncs. A deleted folder takes what's inside it, and restoring it brings them back,
including anything deleted from that folder earlier. Each device keeps its own Recently Deleted:
"Delete now" clears this device's copy, and a copy still waiting on another device can be restored
from there and sync back. The screen says so.

PDFs show their real pages, decrypted into memory only, and their links pass `DocText.isOpenable` like
a doc's. EPUB and Word files show extracted text. Their parsers take hostile files, so `ZipArchive`
bounds every read and the total size, and `SafeXML` hands the XML parser UTF-8 with no declaration
and no doctype, which rules out external entities, entity expansion, and declared-encoding tricks.
Parsing stays linear in the file's size, because a file that freezes the vault freezes every device
it syncs to.

The proposal had Listen hand an audio `ContentRef` to the player. On-device speech produces no audio
file, so there is nothing to refer to. Listen lives in `TotalityReader` as `ListenController` for now.
When the Player module starts, the transport (play, pause, skip, speed, queue) moves behind a protocol
in `TotalityCore`, and Listen and music both play through it.

### The natural voice

Listen has one voice, Michael, and no voice menu (owner, 2026-10-31). `ListenVoices` is the `SpeechEngine` the app uses: it sends speech to `NaturalSpeechEngine`, and the system voice is the backup, so `ListenController` doesn't know which is speaking. Michael is Kokoro-82M's `am_michael`, run on the device through FluidAudio 0.18.0, pinned exactly, on iOS 18 and macOS 15 only. iOS 17 and macOS 14 use the system voice, and their apps still carry the pack. Text stays on the device.

Michael ships in the app (owner, 2026-10-31), so Listen needs no download and works offline. The app is about 235 MB, of which the voice is 205 MB.

- The pack holds the compiled models, the two voice packs FluidAudio loads, the Apache-2.0 licence, and a notice. Its source models are left out.
- It's too big for the repo, so it's the `voice-pack-1` asset of a GitHub release on this private repo. `scripts/embed-voice-pack.sh` runs in the Xcode build, checks it against one hash, and caches it. A new Mac needs `gh` signed in for its first build.
- Being inside the app, the voice is covered by the app's code signature.
- FluidAudio writes beside its models and the app is read-only, so `KokoroSynthesizer.link` builds a folder in Application Support made of links into the app, and the voice isn't stored twice. It's rebuilt each launch, because the app's path changes with every update.
- FluidAudio's network address is set to a dead one, so a missing file fails instead of fetching. It always loads its default voice, Heart, which is why that's in the pack.
- When the FluidAudio pin moves, rebuild the pack with `scripts/build-voice-pack.sh`, publish a new release, and update the tag and hash.

- A voice that fails to load falls back to the system voice until the app restarts, and the bar says so. Below 1 GB free, the bar names storage as the reason.
- Core ML finishes compiling each model the first time it runs, and that wait reached 18.8 s mid-chapter on the iPhone. `KokoroSynthesizer.prepare` runs three lines that between them use every model, so the wait comes during the load. A failure there ends the voice only when storage is short, because a locked screen may refuse it for the moment.
- Core ML writes those compiled models to disk. On the iPhone with 263 MB free it failed with "No space left on device", and iOS had already cleared the app's cache, so each launch compiled again. 1 GB is a working figure, not a measured need.
- Text with nothing to say is skipped. A sentence that fails for another reason goes to the system voice and Michael tries the next one. After two in a row the bar says so, until Michael speaks again.
- `ListenScript` undoes a PDF's line wrapping, keeps abbreviations inside their sentence, and drops lines with no letters. `SpokenText` rewrites what reads badly aloud (a URL becomes its host, citation marks go, "Fig." becomes "Figure") and respells words that change sound with their use, like "read" and "present". `SpokenAudio` trims the second of silence the model leaves around each sentence.
- The model gives no word timing, so the bar moves with the share of the audio played.
- The next sentence is made ahead of time, one at a time, and the voice loads once however many calls wait on it.
- FluidAudio can log a word it can't pronounce, so `KokoroSynthesizer` turns off its stderr copy. The system log keeps the text private.
- FluidAudio warns of an uncatchable crash in Apple's audio library on iOS 26.4 and later, reported after 8 to 20 calls on some devices and 54 minutes into one listen. None appeared here, but it can't be ruled out, and the app can't catch it to fall back.

Measured on 2026-10-31 with the Heart voice, since removed, on an iPhone 14 on iOS 26.7.1 and a Release build:

| Measure | Result |
|---|---|
| Voice load, after the download | 42 to 65 s |
| Speed once warm | 8× real time |
| Peak memory | 1,232 MB with Heart, 1,310 MB with Michael |
| Longest run | 1,000 sentences, 129 minutes of audio, no crash |
| Heat | Reached "fair" with the model running flat out, never "serious" |
| Cold sentences | Slower than real time: 15.3 s of audio took 30.5 s |
| Unexplained stall | One 13 s sentence took 324 s, then one took 35 s. Heat fell during it, so the app may have been in the background |

On the iPhone reading aloud with Michael for 2 minutes, with the next sentence made ahead: first audio 57 s, including the load, and worst gap between sentences 0.03 s. The voice loads again after every launch, so that first wait happens each time, not just once.

On a Mac, reading aloud for 7 minutes with Heart: first audio 54 s, worst later gap 1.17 s, three gaps over a second, peak memory 2,604 MB.

With a screen locked, generating speech may be refused. If so, each sentence goes to the system voice and Michael returns when the app is back in front. That reasoning hasn't been tried on a device.

Not measured: battery use, a locked screen, and a real long PDF. The model did read 30 kinds of awkward text, from URLs to a 3,000-character run, with a bullet, emoji, and blank text as the only failures.

## Attaching across modules

A module offers content through `ContentProvider`, and `ModuleRegistry.providers(for:)` lists what a module can attach, which is everything except its own. Only a `ContentRef` crosses over, so Calendar never imports the Reader. A ref's preview title lives inside the sealed event. `current(_:)` re-reads it, so a renamed item shows its new title and a deleted one says it's gone instead of leaving a dead link. The app opens a ref by handing its ID to the owning module.

## Calendar

Spec: issue #12. An event is one sealed blob with its times inside, so storage shows only an ID. Events use their own key purpose, so a Reader blob can't open as an event, and the ID inside must match the one outside.

- All-day events are midnight GMT on their first and last days, so they're plain dates in any zone. Timed events repeat in their own zone, so 3 PM at home stays 3 PM at home while the person travels.
- Repeats that don't exist, like the 31st of a short month, are skipped rather than moved. Editing one occurrence adds it to `skipped` and makes a standalone event.
- Device calendars are read through EventKit, held in memory, and never written to Totality's storage. Totality doesn't encrypt them, and the UI says so. Only opaque calendar IDs are kept, in `UserDefaults`, to remember which are hidden.
- A reminder gives the operating system the title and time only, outside Totality's encryption. Locations and notes never go with it.
- Reader and Calendar share one root key, so `ContentRootKey.loadOrCreate(in:sealedIn:)` has to count every module's storage. A key is only created when nothing anywhere is sealed under a missing one.
- Reminders are planned per device. Events sync, and each device schedules its own reminders from what it has.
- Sealed events go into device backups as ciphertext, but the key doesn't, so a restore lands on the missing-key screen until key backup exists. That's why the screen doesn't say events stay on this device.
- App-switcher snapshots can hold event text, the same as the Reader. Both need a privacy screen before Phase 3.

## Key backup

Spec: issue #17. A device's content key is locked by a recovery key in Matrix's secret storage format, `m.secret_storage.v1.aes-hmac-sha2`, and stored as Matrix account data and in `key_backups`. Both copies are the same ciphertext. Only the recovery key opens them, and it's never written anywhere.

- `supabase/functions/matrix-login` turns a Supabase sign-in into a one-minute pass with the person's handle, because Supabase identifies people by ID and Matrix by name. Its private key is in Supabase's secrets, and the public half is in `server/tuwunel.toml`. The pass is signed for `matrix.usetotality.com`.
- A Matrix session lasts for one job and then signs out, so no Matrix token is stored on a device.
- `key_backups` allows no client update or delete, so a stolen session can't replace or erase a backup. Replacing a recovery key will need a server-side flow.
- `ContentKeyRing` is the only code that moves content between keys. The old key is saved, then the new key, and only then does any blob change, so a crash at any point resumes on the next launch. Each moved blob is read back before going on. A blob neither key opens is left alone, and the old key stays on the device.
- Any new sealed module must declare its blobs in `sealedPurposes`, be added to `ContentSetup.keyRing()`, and close its vault in the app's `willMove`, or a key move will leave it behind. A vault closes before the move lists blobs, because anything written after that under the old key would be lost.
- A device's key belongs to one account, in `content-key-owner`. Content isn't kept per account, so without this a second person signing in could lock the first person's key into their own backup. A device still holds one person's content, and sync doesn't change that.
  - **Getting an owner:** an install from before this existed takes its signed-in account once at launch. An empty device takes whoever signs in. A device with content asks, but a yes only continues the screen: the claim is written when setup or joining succeeds, because an answer proves nothing.
  - **Changing owner:** an empty device passes to the next account with a new key. With content, a recovery key that opens it proves ownership. The owning account can release a device it never joined to a backup.
  - **Known gap:** with content and no recovery key, the owner's password is the only way back in. The server owner can reset it from the Supabase dashboard, and account deletion will need its own release.
- A joined device remembers the backup's fingerprint, not its ID, so a server can't swap the contents behind the same ID. A backup is never written over a different one on Matrix.
- `fetchBackup` returns nil only when both servers answer that there's nothing. An outage must never read as "no backup", because that invites a second recovery key.
- A handle is retired for good when its profile is deleted, because Matrix finds accounts by name and the next owner would inherit the old account.

## Encrypted sync

Notes, files, and events move between one person's devices as sealed bytes. A row in `content_objects` is one item, with its sealed details in `meta_cipher`. A body goes to the `content` Storage bucket at `<owner>/<id>/<bodyHash>.body`. A deleted item keeps a row with `deleted_at` and nothing else. The server sees each item's ID, kind, size, and times, and never what's in it.

- `SyncEngine` compares three things for each item: this device, the server, and the hash they last agreed on, saved after every item. That's how it tells "I changed this" from "they changed this".
- Every write names the version it expects, on both sides. The server takes `content_hash` as the check. A vault's `store` and `removeObject` take `ifLocalHash`, so a save that lands during a sync is never overwritten. The next sync sorts it out.
- Only an explicit `.deleted` record here deletes from the server. A missing file comes back from the server instead of spreading.
- Only a row with `deleted_at` counts as deleted there. A live row with no valid hash is skipped, because broken isn't gone.
- What the server says is deleted moves to a local trash for 30 days, because that claim can't be proved. `removeObject` writes `<id>.trashed` first, so a crash can't strand trash.
- More than 5 removals, and more than a fifth of what's here, in one sync waits for the person to agree in Settings.
- Nothing leaves without opening. `verifiedObject` proves every part opens under this device's key, so a damaged file can't replace the good copy. If the server has a copy, the damaged one is repaired from it. If not, it stays here and is counted as rejected.
- Nothing arrives without opening, and what's fetched must match the hash the list gave.
- If both sides changed, the newest stays and the older is kept as a conflict copy, unless nothing a person would notice differs. The copy's ID comes from the two hashes, so a retry can't double it.
- An edit against a delete keeps the edit, because a lost edit can't be undone.
- An open editor saves against the version it loaded, one save at a time. A note that changed meanwhile keeps what was typed as a conflict copy, which opens so typing carries on there. A stale calendar edit is refused in the vault, in one step, and the screen reloads.
- A delete writes its `.deleted` record first. A crash partway is finished the next time sync lists the vault.
- A sync stays in one account: the remote is tied to the account at the start of the run, and signing out cancels the run and clears what `SyncModel` knows.
- Numbers from the server are distrusted: sizes are saturated, an oversized row is refused, and a list that never ends stops.
- Screens may only say content is backed up once `SyncModel.isProtected` is true, which takes a sync that really finished cleanly.
- The Reader caps imports at 49 MB, so anything that gets in fits under the bucket's 50 MB ceiling once sealed.
- New sealed files need to be in `sealedPurposes`, including their `.trash` names, or a key move leaves them behind.

**Known limits, not yet closed:**

- **Rollback and splicing.** A server can't read or forge an item, but it can replay an old sealed version, or pair one version's details with another's body. Hashes only prove the bytes match the list, and the list comes from the same server. Closing this takes a rising version number and the body's hash inside the sealed details, which goes in before Phase 2.
- **Key moves leave sync state stale.** After a move every item looks edited, so the next run would re-upload everything and revive tombstoned items. It can't happen today, because moves only happen while joining, before a device has any state. Hashes must be remapped before key rotation exists.
- **Listen position counts as an edit.** It lives in the sealed details, so a file deleted elsewhere comes back from a device that only listened to it. Nothing is lost. Moving positions out of the details fixes this.
- **Blob and row races.** Storage and the row can't change in one step, so two devices racing on the same body can leave a row with no blob, and failed uploads can leave orphaned blobs that nothing counts or collects. Closing it takes a server-side swap.
- **Deletes aren't authenticated.** A server can claim anything is deleted. The trash and the 5-removal hold limit the damage, and they don't prevent it.

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

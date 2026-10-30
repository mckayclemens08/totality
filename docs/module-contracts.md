# Totality — Module Contracts

Modules never import each other. They meet through `ContentRef` and `ModuleRegistry` in `TotalityCore`.
A new contract is recorded here before it is implemented.

| From | To | Contract | State |
|---|---|---|---|
| any | Messages | attach a `ContentRef` to a message | not built |
| Reader | Player | Listen plays through the shared player | **changed, see below** |
| Calendar | Reader, Calls | an event may attach a doc ref and a call ref | not built |
| AI | Reader, Calendar, Money | read `ContentRef` lists under a grant | not built |
| Social | Messages | social DMs are Messages threads | not built |

## Reader

`ReaderModule` handles `note` and `file` content. It does not claim `doc` until rich documents exist
(proposal §11-M), so a `doc` ref draws its preview chip.

The proposal had Listen hand an audio `ContentRef` to the player. On-device speech produces no audio
file, so there is nothing to refer to. Listen lives in `TotalityReader` as `ListenController` for now.
When the Player module starts, the transport (play, pause, skip, speed, queue) moves behind a protocol
in `TotalityCore`, and Listen and music both play through it.

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

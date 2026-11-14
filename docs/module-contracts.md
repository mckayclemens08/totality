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

A doc's body is Pandoc-flavoured Markdown inside the sealed blob, stored exactly as typed, with the mime
`text/markdown; variant=pandoc` (RFC 7763). Issue 104 is the spec. The writing page is a `WKWebView`
running CodeMirror 6, bundled from `web/reader-editor` by `scripts/build-reader-editor.sh` from a pinned
lockfile, with the built files committed so the app builds without Node. The page is shut in: it's one
inline document whose policy lets only the bundled script run (by hash) and loads nothing, a compiled
rule list blocks every request, its data store keeps nothing, its proxy goes nowhere, and every
navigation but its own first load is cancelled. Its one message handler, `editor`, carries only
`ready`, `changed`, `text`, `format`, `link` and `open`; `WritingMessage.parse` drops anything else,
and `open` passes only `http`, `https` and `mailto`. Swift sends text and commands in through
`callAsyncJavaScript` arguments, never by building script. `MarkdownText` reads the Markdown for
Listen, search and headings.

The writing tools (issue 104, step 2) work on the Markdown itself. Find and replace is a native bar that
drives CodeMirror's search, with its own panel kept empty. Counts, the outline and find results come back
as `stats`, `outline`, `find` and `matches` messages, parsed and clamped like the rest. Folding a section
from the outline only hides lines on the page. Focus mode, typewriter scrolling, smart quotes and dashes,
and serif or sans are settings on the device (`reader.writing.*`). A doc's word target is `wordTarget`,
sealed in its details, and setting it leaves the date alone. The daily goal counts words added on this
device, in any doc, and keeps only a date and two numbers in the device's settings, never any words.

A doc from before the writing editor (the older Markdown subset that `DocText` reads, or a plain note)
converts once, the first time it opens. Its date stays, because tidying up isn't an edit. Its old body is
kept beside it as a read-only `file` item, "(before the new editor)", whose ID derives from the doc's and
the root key, so two devices converting alone land on one copy. The doc names that copy in
`keptOriginalID` until the person taps Looks right, which moves the copy to Recently Deleted.

Folders are sealed items, travelling as `note` rows, so the server can't tell a folder from a doc or
see a name. An item names its parent inside its sealed details. A missing parent or a loop puts an item
at the top level, because a sync can deliver them in any order. The old collections became folders
with an ID derived from the name and the root key, so two devices migrating alone land on one folder
and the same name gives a different ID on every account. The brief's Speechify Library import was
removed on 2026-10-31 at the owner's request ("I don't want it anymore"): it only ever filled a folder,
and any file can go in any folder.

The library opens on most recently opened (owner, 2026-10-31), with recently added, recently edited,
name, and type a menu away. When something was opened lives in a sealed `.opened` file of its own on
each device, and sync never sees it. In the item's sealed details it would re-upload the whole body on
every open, turn each read into a possible conflict, and show the server when someone reads. So each
device has its own order. A change from another device still moves an item up, and anything never
opened here goes by its last change. The file goes when the item does, because a stray one would make
an empty device look like it has content.

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
- Core ML writes those compiled models to disk. On the iPhone with 263 MB free it failed with "No space left on device", and iOS had already cleared the app's cache, so each launch compiled again. Compiling added 282 MB to the cache and took 488 MB of free space in all, so the 1 GB line leaves some room.
- Text with nothing to say is skipped. A sentence that fails for another reason goes to the system voice and Michael tries the next one. After two in a row the bar says so, until Michael speaks again.
- `ListenScript` undoes a PDF's line wrapping, keeps abbreviations inside their sentence, and drops lines with no letters. `SpokenText` rewrites what reads badly aloud (a URL becomes its host, citation marks go, "Fig." becomes "Figure") and respells words that change sound with their use, like "read" and "present". `SpokenAudio` trims the second of silence the model leaves around each sentence.
- The bar moves with the share of the audio played. Word places come from the model's own timing, under Read along below.
- The next sentence is made ahead of time, one at a time, and the voice loads once however many calls wait on it.
- FluidAudio can log a word it can't pronounce, so `KokoroSynthesizer` turns off its stderr copy. The system log keeps the text private.
- FluidAudio warns of an uncatchable crash in Apple's audio library on iOS 26.4 and later, reported after 8 to 20 calls on some devices and 54 minutes into one listen. None appeared here, but it can't be ruled out, and the app can't catch it to fall back.

Measured on 2026-10-31 with the Heart voice, since removed, on an iPhone 14 on iOS 26.7.1 and a Release build:

| Measure | Result |
|---|---|
| First word, normal launch | 4.5 s |
| First word, first launch after an install | 25 s |
| Speed once warm | 8× real time |
| Peak memory | 1,428 MB with Michael |
| Longest run | 1,000 sentences, 129 minutes of audio, no crash |
| Heat | Reached "fair" with the model running flat out, never "serious" |
| Cold sentences | Slower than real time: 15.3 s of audio took 30.5 s |
| Unexplained stall | One 13 s sentence took 324 s, then one took 35 s. Heat fell during it, so the app may have been in the background |

On the iPhone with 18 GB free, reading PDF-style text aloud with the warm-up in place: worst gap between sentences 0.03 s on both launches, no failures, and peak memory 1,428 MB. The same phone with 263 MB free waited 38 to 69 s for the first word, paused up to 18.8 s, and peaked at 2,644 MB, because nothing compiled could be kept.

On a Mac, reading aloud for 7 minutes with Heart: first audio 54 s, worst later gap 1.17 s, three gaps over a second, peak memory 2,604 MB.

With a screen locked, generating speech may be refused. If so, each sentence goes to the system voice and Michael returns when the app is back in front. That reasoning hasn't been tried on a device.

Not measured: battery use, a locked screen, and a real long PDF. The model did read 30 kinds of awkward text, from URLs to a 3,000-character run, with a bullet, emoji, and blank text as the only failures.

### Read along

Read along follows Listen on the page and lets a tap on a sentence move Listen there (owner, 2026-11-01). The spec is issue 30. It's a button on the Listen bar (owner, 2026-11-01), off until it's turned on, and `reader.readAlong` remembers it on that device for every document. It only applies while the bar is showing, because a note left in Read along couldn't be edited and nothing on the page could turn it off. It holds only on or off, and nothing here touches the network or stores any content.

- Notes, Word, EPUB, Markdown, and plain text open as `ReadAlongView` while it's on. A tap means "go here", so nothing can be edited or selected there, and a note saves as it switches. Its paragraphs and headings come from `ReadAlongPage`, cut up off the main thread because a long book takes seconds.
- PDFs keep their real pages, with the marks drawn as `highlightedSelections`. Listen reads `PDFDocument.string`, which is the pages joined by a newline, so `PDFPageMap` finds each page in it in order and turns places in the text into places on a page and back. All 16 pages of the founding brief lined up. A PDF with no text says so on the page.
- Every sentence is a link to `totality-read-along://sentence/N`, and `ReadAlongView` handles that scheme itself, so nothing opens outside the app. Sentence text is plain, so a document's own links can't reach this. On iOS 17 the links never received a tap in that scroll view until the text also had a tap gesture of its own, which is why `ReadAlongParagraph` has an empty one.
- `ListenScript` keeps each sentence's place in the document's own text, so a place survives the tidying `ListenScript` and `SpokenText` do for speech. `range(ofSentence:)` and `range(ofWordIn:spoken:)` give the marks.
- The marks show only when the `ListenScript.fingerprint` of what's playing matches this page. So a document that isn't playing stays unmarked, and so does a note edited since Listen started. A tap then starts Listen on this text. The fingerprint is `hashValue`, which changes every launch, and it's never stored.
- `ScrollWatch` tells the person scrolling from the page following Listen, and "Back to reading" appears once they've scrolled.
- The Listen bar is stacked below the navigation stack. It used to be a safe area inset, which never reached a pushed page, so the end of a document stayed behind the bar.

Sentences are exact with both voices, because Listen speaks one sentence at a time. The system voice reports each word as it speaks. Michael doesn't, but the model reports how many frames it gives each sound (600 samples a frame, or 25 ms at 24 kHz). `VoiceTiming` finds where each word starts from the spaces in the phonemes, and lines up the words the model said with the words on the page, because the text was rewritten for speech. `NaturalSpeechEngine` reports the place every 50 ms. A rewritten word shares its place with its neighbours, so the word mark waits there, and a sentence of over about 510 sounds is split by the model and has no marks, so it moves with the share of the audio played instead.

Measured on 2026-11-01 on a Mac, on 60 sentences of the founding brief (162 commas), by comparing where the timing puts each comma with the quietest point of the audio within 400 ms of it:

| Timing | Speed | Median miss | Within 100 ms |
|---|---|---|---|
| Michael's timing | 1× | 75 ms | 60% |
| Counting letters, the plan before this | 1× | 375 ms | 12% |

The misses over 100 ms aren't all timing errors, because a comma isn't always the quietest point nearby: the search reaches other gaps, and the worst results sit at its 400 ms limit. 59 of the 60 sentences got marks, and the other was too long. 1,377 of 1,472 written words got a mark of their own. Whether it looks right on a real document on the iPhone is still the owner's call.

Speed happens in playback, through `AVAudioUnitTimePitch`, and Michael is always made at the model's own pace. The model's speed setting squeezes every sound, so at 2× Michael slurred his words (owner, 2026-11-01). That setting is now always 1, so the marks above hold at every speed, each miss shrinks with the speed, and a speed change keeps the sentence made ahead. At 1× the unit is bypassed, so that audio is exactly what the model made. The player's clock follows the speed: on a Mac and in the iOS simulator, a 3 s buffer at 0.75× to 2× reported its progress at the right pace and finished within 0.2 s of the expected time, the same margin as 1×. The system voice keeps its own rate.

## Home page

- `HomeLayout` is the tiles' order and sizes and the optional big square, saved on the device under `home.layout`. It holds module names and sizes, never content, and it isn't synced. Tiles for modules that no longer exist drop out and new modules join the end, so an update can't lose a tile.
- A module's tile content is a `ModuleGlance` in `TotalityCore`: short lines, most important first. `ReaderModel` and `CalendarModel` each build one, and `RootView` hands them to `HomeView`, so `TotalityUI` imports no module. A bigger tile shows more of the lines because it shows as many as fit. Glances come from private content, so they stay in memory.
- A tap opens what's under it, and only blank space on a tile opens the module. The grid takes every touch itself so a hold can turn into a drag, which means a button inside a tile would never hear a tap. So a tile's content marks each item with `.tileLink(name) { ... }`, the grid checks those first, and `lineLink` does the same for a glance's lines. Each one also gets an invisible button for VoiceOver and a keyboard, and on a Mac for the mouse. A module asks for the item on its own model (`requestedItem`, `request(_:)`, `requestedPanel`) and then calls `onOpen`, which keeps `TotalityUI` out of what the items are.
- A medium tile, a large tile, or the big square can show a view of the module's own instead of its lines. `RootView` hands `HomeView` a closure that builds it, so `TotalityUI` still imports no module, and a module that has nothing to show yet keeps its lines. The Calendar shows this week on a medium tile and this month on the larger two, and it keeps today's month and week loaded wherever the Calendar was left, so the tile can't lose its events. The Reader shows what's playing or what was opened last, then a shelf of the next three on the larger two. A module that isn't built yet keeps its plain tile until it has content of its own.
- A glance is nil until the module has opened, so a tile can't claim it's empty while it's loading. A module that can't open shows its icon and title, and opening it reports the key problem.
- Content now opens with the home page, after the device is settled. It's the same step as opening a module, under the same key rules, and it writes nothing, so a fresh install still reads as empty when an account signs in.
- On iPhone, one plain UIKit view on top of the tiles takes every tap and hold, because how a recognizer around a SwiftUI button competes with it changes between releases of iOS. A long press on the enclosing scroll view did nothing on iOS 26, `UIGestureRecognizerRepresentable` let the button win on iOS 18, and SwiftUI's hold-then-drag gesture stopped the page scrolling on iOS 17. The tile menus sit in a layer above it and leave while a tile is carried, or they'd show through it. The tiles' own buttons remain for VoiceOver and a keyboard. The Mac uses the SwiftUI gesture, because a mouse drag doesn't scroll.
- `HomeStyle.defaultKey` holds the default home page on this device. The home page's own button lasts until the app restarts.

## Search inside Totality

Spec: issue #14. The magnifying glass on the home page opens one screen that asks every module at once.

- A module joins by conforming to `ModuleSearcher` in `TotalityCore`. `ModuleRegistry.searchers` lists them and `UniversalSearch` runs them side by side. One that fails is named on screen and the others still show. Modules never import each other, and `TotalityUI` knows only `SearchHit`.
- `SearchText` is the one definition of a match: every word has to appear, in any order and across any of the fields, ignoring case and accents. The Reader's search moved onto it.
- `SearchHit.itemID` means something only to the module that found it. `RootView` hands a tapped hit back to that module: the Reader takes a `requestedItem`, and the Calendar takes a `requestedHit` and goes to that day. A result is only as fresh as the moment it was found, so the Calendar says so if the event has gone.
- The Calendar searches titles, locations, notes, and the names of attachments. A repeating event shows once, at its next occurrence within a year, then its latest in the past year, then its first ever. Device events are read for a year either side of today, from the calendars turned on in Calendar, and repeats fold by title, location, and calendar. `CalendarEntry.id` is the item ID, so a result opens the same occurrence it showed.
- Searching happens on the device. `SearchModel` lives in the sheet and writes nothing, so there is no history, and the box has autocorrect off. There is no index, because a plain-text one would break the encryption rule. Each search decrypts in memory, the same as reading does.
- A search caches each item's text in the Reader's `textCache`, as the Reader's own search always has, so one search leaves the library's text in memory until the app quits or the key moves. A results screen can also land in the app-switcher snapshot, which is the privacy screen already owed before Phase 3.
- Speed, without an index: 1,000 notes of about 2,700 characters took 0.83 s the first time and 0.44 s after that, in a debug build on the Mac, reading sealed files from disk. `ReaderSearchModuleTests.speed` fails past 10 s. Not measured on a phone. If it gets slow, the fix is an encrypted index on the device, as its own piece of work.

## Attaching across modules

A module offers content through `ContentProvider`, and `ModuleRegistry.providers(for:)` lists what a module can attach, which is everything except its own. Only a `ContentRef` crosses over, so Calendar never imports the Reader. A ref's preview title lives inside the sealed event. `current(_:)` re-reads it, so a renamed item shows its new title and a deleted one says it's gone instead of leaving a dead link. The app opens a ref by handing its ID to the owning module.

## Google sign-in

Spec: issue #76, decision 8 (owner, 2026-11-08: "i shouldn't have to sign in to google more than once"). `GoogleSignIn` in `TotalityCore` is the one Google sign-in, for Mail, Calendar, and Photos, so no module imports another to reach Google.

- It knows no module's scopes. Each module passes only its own. A module turned on later for a Google account that's already connected asks with `include_granted_scopes` and that account as `login_hint`, which is one consent tap, not a second sign-in.
- It's the installed-app flow (RFC 8252): Google's own page, PKCE with S256, no client secret, and the answer has to come back on the client's own scheme with this request's state. The verifier and state stay in memory and never print, and nor do tokens.
- `finish` hands back what Google granted, as Google said it. The person can untick any scope, so each module checks for its own. Mail still revokes when an account being added didn't get everything Mail needs.
- Revoking at Google takes back every scope that Google account gave Totality, so disconnecting one Google account disconnects every module using it, and the screen has to say so first.
- Errors from the network pass through unchanged, so each module says them its own way. Mail turns them into `OutsideMailProblem`.
- Step 1b, still to come: one connection per Google account, with one refresh token in the Keychain, shared by every module. Mail's existing Gmail grants move to it without signing in again.

## Calendar

Spec: issue #12, and issue #23 for the redesign. An event is one sealed blob with its times inside, so storage shows only an ID. Events use their own key purpose, so a Reader blob can't open as an event, and the ID inside must match the one outside.

- Google Calendar (issue 76, step 2) is read-only, on the shared Google sign-in, with the scope `calendar.readonly`. The Google Cloud project behind `TotalityGoogleClientID` must have the **Google Calendar API** enabled. Without it, Google answers 403 `accessNotConfigured` / `SERVICE_DISABLED`, which the Calendar shows as Totality's setup problem, not the person's permission. Events are kept sealed per device under `googleCalendar`, in their own folder, and never sync. Only changes are read after the first time, using Google's sync tokens.
- Changing Google events (issue 88, step 3) asks for one more scope, `calendar.events.owned`, as incremental consent on the same connection, so it reaches only calendars the person owns. Every create, edit and delete stops for the person's press on a confirm sheet, or on a delete question that names the event, and nothing is queued for later. Every change sends `sendUpdates=none` and never touches guests, and every edit or delete sends Google's ETag in `If-Match`, so a newer version on Google is never overwritten. Nothing new is stored: the next sync brings the saved event into the sealed cache.
- All-day events are midnight GMT on their first and last days, so they're plain dates in any zone. Timed events repeat in their own zone, so 3 PM at home stays 3 PM at home while the person travels.
- Repeats that don't exist, like the 31st of a short month, are skipped rather than moved. Editing one occurrence adds it to `skipped` and makes a standalone event.
- Device calendars are read through EventKit, held in memory, and never written to Totality's storage. Totality doesn't encrypt them, and the UI says so. Only opaque calendar IDs are kept, in `UserDefaults`, to remember which are hidden.
- The Calendar always opens on Month and today, with that day's events below (owner, 2026-10-31). Day, Week, and Schedule are one menu away. Week is seven days on Mac and three on iPhone.
- `TimelineLayout` places timed events by clock minutes, so 9 AM lines up with 9 AM on a day the clocks change. Overlapping events share the width.
- Anything a swipe can cross uses `tappable`, not a Button. A Button also fires when a swipe ends on it, which opened a new event on the simulator.
- A reminder gives the operating system the title and time only, outside Totality's encryption. Locations and notes never go with it.
- Reader and Calendar share one root key, so `ContentRootKey.loadOrCreate(in:sealedIn:)` has to count every module's storage. A key is only created when nothing anywhere is sealed under a missing one.
- Reminders are planned per device. Events sync, and each device schedules its own reminders from what it has.
- Sealed events go into device backups as ciphertext, but the key doesn't, so a restore lands on the missing-key screen until key backup exists. That's why the screen doesn't say events stay on this device.
- App-switcher snapshots can hold event text, the same as the Reader. Both need a privacy screen before Phase 3.

## Web

Spec: issue #15, agreed 2026-11-01. A browser on WebKit, with search through the owner's own SearXNG behind a small gateway.

**The trial, 2026-11-01.** Twenty test searches chosen by the builder, not the owner, from the Oracle box: every one returned 30 to 50 results, 18 in about a second and two in about five, with relevant top hits. Results came from Brave (457), Google's CSE engine (400), and Bing (197), and Google's CSE engine ranked first most often (13 of 20). DuckDuckGo showed CAPTCHAs, and Google and Qwant refused, on all 20, so those three are off. Images gave 345 results, Videos 148, and News 24, the thinnest. A cloud server's address can be blocked at any time, so the fallback below stays.

- The server runs SearXNG with no public path. `server/gateway/gateway.py` is the only way in: `POST /web/search` and `POST /web/image` on `usetotality.com`, each checking the Totality sign-in. The limits are 30 a minute and 1,000 a day per account, held in memory. SearXNG's log driver is `none`, because a failed engine logs a URL with the search in it.
- Search goes in the request body, so it never appears in an address. Image thumbnails come through the gateway, signed by SearXNG, so image sites don't see the person's address.
- When search can't answer, the screen offers the same search on DuckDuckGo's own site, in a tab, and says that site sees the person's address.
- **Pages get no route into Totality.** There's no message handler or injected script. `WebPage` has one script, and it runs only on Save to Reader, in `WKContentWorld.defaultClient`, where a page's scripts can't see or change it. It reads shown text and never form fields or editable areas. The tests run this in real WebKit, with typed text and a hostile page.
- Bookmarks are one sealed blob each and sync through `SyncArea`, newest wins, with no conflict copy. History, open tabs, and settings are sealed too, stay on the device, and have no kind, so sync can't see them. Blob names hold only IDs.
- A device has one content key, so that key can't keep two accounts apart. The app does: history, tabs, settings, the `WKWebsiteDataStore` of cookies, and the downloads folder are all named by an ID hashed from the account, and nothing is shown or written for anyone else. Only the account that owns the device's key keeps anything, because its bookmarks sync under that key. Signed out, or signed in as anyone else, the browser works and keeps nothing, with a store that's dropped when they leave. Signing out closes every tab, and everything kept stays sealed on the device until that account returns.
- Nothing is written until there's something to keep, and an empty list leaves no blob. Local browsing still counts as sealed content, so once someone has browsed, the device can't pass to a new account without them agreeing, the same as a note.
- The box and dialog titles name the page really on screen. `webView.url` moves as a load starts, before the new site has answered, so `WebPage` takes it only at commit or when nothing is loading. The one exception is an address the person typed or chose, which shows at once, and dialogs still use the committed page.
- Cookies and site data are Apple's to protect, not the content key's, and Web Settings says so. Downloads stay on the device, out of its backups, and aren't sealed. Opening one in the Reader is what seals it.
- Private tabs each get a non-persistent store, keep no history, and aren't saved. A link opened from one stays private.
- `blocklist.json` comes from `scripts/build-web-blocklist.py`: 91,539 whole-site rules from EasyList and EasyPrivacy, about 9.7 MB, which WebKit compiles in about 2 s on a Mac the first time and never again. It's adapted under CC BY-SA 3.0, credited in Web Settings, and only changes with an app update. The list of sites turned off is sealed, because site names count as content.
- Rules are applied in the navigation decision, before the page starts, because WebKit fixes them as a load begins.
- A download asks first, because a site can start one by itself. A site's suggested name can't reach outside the folder.
- Save to Reader and Open in Reader go through `ContentReceiver` in `ModuleRegistry`, so Web doesn't know how the Reader keeps things.
- Find uses Apple's bar on iPhone, because a selection doesn't show while the keyboard is in a field of ours. The Mac uses a bar of ours.
- Camera, microphone, and location are WebKit's own prompts. Totality stores no answer, so closing the tab undoes it.
- The big home tile shows bookmarks on a wall, a running download, and a count of open tabs, and never history. A bookmark's first letter stands in for the site's icon, because fetching one would tell the site. A bookmark opens in a normal tab of its own, so it can't replace a page left open or land in a private tab. The tabs line opens Tabs, and a running download opens Downloads.
- A running download shows Safari's ring in the toolbar, and a finished one keeps a solid marker until the list has been looked at.
- Open in Reader hands the file over through `ContentReceiver` and then opens the document. Opening it again in the same run goes back to the same document, unless `current` says it's gone. Save to Reader only saves.
- `content_kind_t` gained `bookmark`, so the enum changed on the live database even though no table did. Older apps skip kinds they don't know.

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
- Some names are retired from the start, because every username is also a mail address: `abuse@`, `postmaster@`, `admin@`, and the others in `20261102000001_reserved_usernames.sql`. Mail to them goes to the owner, at `mckayclemens@`. The app's `Username.reserved` holds the same list so sign-up can answer clearly, and a test keeps the two equal.

## Encrypted sync

Notes, files, and events move between one person's devices as sealed bytes. A row in `content_objects` is one item, with its sealed details in `meta_cipher`. A body goes to the sealed blob store on the Oracle server, named `<owner>/sealed/<blob>`, where the blob ID comes from the owner, the item, and the body's hash, so one body is never stored twice (issue 54). Bodies from before that are still in the `content` Storage bucket at `<owner>/<id>/<bodyHash>.body`, and are read from there until they move. A deleted item keeps a row with `deleted_at` and nothing else. The server sees each item's ID, kind, size, and times, and never what's in it.

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

## Sealed blob store

Agreed with the owner on 2026-11-05, in issue 54. Photos keep their bytes here, and Reader files move here
from Supabase Storage, until the home server exists. It lives in `TotalityCore` and `server/blobs/`, so
neither module imports the other. Like mail, the Oracle server has no backup yet, which the owner accepted.

- **What it holds.** Bytes a device already sealed with the content key, under random IDs, one folder per
  account. The account always comes from the sign-in, never from the request, so user 2 asking for user 1's
  ID only ever reaches user 2's own folder. The server sees each blob's size and when it was stored, and
  logs nothing. It can't check that what it's given is sealed: that's the device's job (non-negotiable 2).
- **The target is configuration** (proposal §11-H). The app reads `TotalitySealedStoreURL`, set in
  `App/Backend.xcconfig` and overridable in `Local.xcconfig`. A row names a blob as `<owner>/sealed/<id>`
  (`SealedBlobKey`), never by server, so moving to the home server is copying the folder and changing the
  setting.
- **Uploads come in pieces** of 8 MiB, under Cloudflare's 100 MB per request. `PATCH /blobs/<id>` with
  `Upload-Offset` adds a piece exactly where the upload got to, or answers 409 with where it really is.
  `HEAD` says `uploading` with the offset, or `done` with the size. `POST /blobs/<id>` with `{size, sha256}`
  finishes it, only if both match, so nothing damaged on the way takes a real name. A finished blob never
  changes. A piece cut off partway is taken back out. Unfinished uploads are cleared after 7 days.
- **Reading** is `GET /blobs/<id>`, with one `Range` for video and resumed downloads. `DELETE` is harmless
  twice. `GET /blobs/usage` and `GET /blobs/list` give `used`, `limit`, and IDs with sizes.
- **Limits.** 20 GB for the usernames in `BLOB_LARGE_ACCOUNTS` on the server (the owner), 2 GB for anyone
  else, counting unfinished uploads. Whatever the limits add up to, uploads stop while the disk has under
  8 GB free, so mail and Matrix keep room: 507 either way. At most 8 pieces are written at once.
- **Sign-ins** are checked with Supabase and remembered for a minute by a hash of the token, so a screen of
  thumbnails doesn't ask once each. A signed-out token can still reach its own blobs for up to that minute.
- **Moving Reader files.** After each sync that finishes, `BodyMove` moves up to 25 bodies from the
  bucket, in an order that loses nothing wherever it stops: read the bucket's copy and check it against
  the row's hash; store it; read it back and compare; point the row at it, only if the row hasn't changed;
  and only then remove the bucket's copy. If the Oracle server can't be reached, the row still names the
  bucket's copy, and the next sync tries again. A row that changed meanwhile keeps its bucket copy.
- **Two-user cases** are in `server/blobs/blobs.test.mjs`, through real HTTP the way anyone with a sign-in
  could ask, and the client's half in `SealedStoreTests`.

## Photos

Spec agreed with the owner on 2026-11-05, in issue 54. Step 2 is adding and viewing, and step 3 is
albums, favourites, captions, Recently Deleted, and saving back to Photos. Step 4 is video, Live Photos,
and uploads that carry on. Step 5 is the home tile, the empty and error states, and sharing.

- **Everything is sealed on the device first** (non-negotiable 2). Each photo has three parts, each sealed
  with its own key from the content key: the original exactly as added (`.photo`), a 480-pixel thumbnail
  with no metadata (`.photoThumbnail`), and the details (`.photoDetails`): owner, date taken, size, and type.
  The original and thumbnail go to the sealed blob store under random IDs. A `content_objects` row of kind
  `photo` holds the sealed details, the original's key, and the size, and nothing readable. The date and
  place inside the photo stay inside the sealed original and details.
- **Adding** seals all three parts into the device's photo store before anything uploads, so a photo
  added offline, or one whose upload stops, isn't lost. Uploads go original, thumbnail, then row, so the
  server never names a photo whose files aren't there. Trying again is always safe. A full account stops
  the upload and says so, and the photo waits on the device.
- **Viewing.** The library lists the rows, opens each one's details, and shows only photos whose details
  name this account. Thumbnails and details are kept sealed on the device, so the library opens offline.
  Originals are fetched only when a photo is opened. Photos don't go through encrypted sync, which would
  copy every original to every device. A second device sees them once it has joined the key backup.
- **Who gets a library.** Only the account that owns this device's key, once the device has joined the
  backup. Anyone else signed in sees the reason, not someone else's photos. Rows refuse to work under any
  sign-in but the account they were made for.
- **The UI says** "End-to-end encrypted", which is literally true: the server holds only ciphertext and
  the key never leaves the owner's devices and recovery key.
- **Favourites, captions, albums, and Recently Deleted** (step 3) are fields in each photo's sealed
  details. A change seals new details on the device and replaces the row's only if its `content_hash` is
  still what this device last saw. If another device changed it first, the change is made again on top
  of theirs, up to three times. An album is a row of kind `photo_album` holding only its sealed name
  (`.photoAlbum`), so the server sees how many albums there are and nothing else. Deleting an album keeps
  its photos.
- **Every change raises a revision** inside the sealed details or album, so a server that hands back an
  older copy is not believed: the device keeps the newer one, and refuses to change on top of the older.
  A server can still bring back an album that was deleted, since there's nothing left to compare with.
  Changing or deleting a photo while it uploads waits for the upload, so neither is lost.
- **Recently Deleted** keeps a photo for 30 days, then whichever device lists the library next deletes it
  for good. One wrong clock can't do that: the date it was put there must be after it was added and not
  ahead of the device, the server's own time of that change (`updated_at`) must agree with it to a day,
  and the server's clock now, from the sealed store's `Date` header, must say 30 days have passed. Deleting for good writes a sealed note on the device first, then removes the row, then both
  files, so a delete that stops partway is finished on the next upload and the photo never shows again.
- **Videos and Live Photos** (step 4). A video up to 10 minutes and 4 GB, or a Live Photo's movement, is
  sealed from its file in 1 MiB chunks (`ChunkedCipher`, purpose `.photoVideo`), so it's never held in
  memory whole. Each chunk's associated data names the photo, its place, the chunk size and the whole
  length, and a file is refused at once if its length doesn't match its header, so a server can't swap,
  cut, or extend chunks. A video's `original` is the sealed movie. A Live Photo keeps its still as
  `original` and its movement as `motion`. Both upload and download in 8 MiB pieces, and carry on from
  where they stopped (`putFile`, `download`). Playback reads the sealed file a piece at a time through an
  `AVAssetResourceLoader`, so nothing is written out in plain form. The newest 3 downloaded movies stay
  on the device, still sealed, and every chunk of a download is checked once before it's kept. A key
  move re-seals movies a chunk at a time into a side file, reads the new copy back in full, and only
  then replaces the old one (`ChunkedCipher.reseal`). Plain copies made for a moment (a picked video, a
  Live Photo's parts, a video being saved to Photos) are removed when done, and any left by a launch
  that was stopped are removed the next time Photos opens.
- **Uploads in the background** ask iOS for time to finish when Totality leaves the screen. iOS decides
  how long, and an upload it stops carries on from the same piece next time.
- **Save to Photos** asks iOS for add-only access, so Totality can't read the device's library, and says
  first that the copy there isn't sealed. **Info** reads the camera and place from the original on the
  device, and shows the place as coordinates, never looked up by name.
- **The home tile** (step 5) shows the newest photos, four to a row, one to three rows by the tile's
  size, and never Recently Deleted. Thumbnails are opened on the device the same way the library opens
  them. A photo picked there opens in the viewer only if it's still in that account's library, so a
  request can't reach another account's photos or one deleted since. The tile shows only when Photos has
  a library, so a device that can't open one shows the plain module tile.
- **Empty and error states.** Each reason Photos can't open says so and what to do: signed out, this
  device not yet joined to the recovery key, the device's key belonging to another account (each with a
  button to the account), and a library that couldn't be read (Try again).
- **Sharing** (decided 2026-11-08, issue 54, option b) sends a copy into an end-to-end encrypted
  Messages chat with the person, found or started by username. The blob store never serves another
  account's folder, and no grant table is needed: Matrix carries the key and the membership. Photos opens
  the sealed original on the device and hands it through `PersonSender` in core. The app's
  `MessagesSender` passes it to Messages, which re-encodes it and drops where, when and on what it was
  taken. Photos go at up to 2048 pixels, videos up to a minute, and a Live Photo as its still. An album
  goes as a snapshot: its name as a message, then up to 50 photos. Recently Deleted is never shared.
  Nothing goes until Send is pressed, and the sheet says that deleting the message stops new opens but
  can't take back a copy already seen or saved. Share shows only where Messages runs (the iPhone app).
- **iPhone sync** (issue 77, agreed 2026-11-08). Off until the person turns it on, and turning it on is
  the first time Totality reads the device's library (`NSPhotoLibraryUsageDescription`). Full or Limited
  access both work. Limited syncs only what was chosen. From the day it's turned on, new photos and Live
  Photos come in, plus any earlier months chosen. Videos have their own switch, off at first. Each item
  is read with PhotoKit into a plain temporary copy, readable only while unlocked, sealed through the
  same `add`, `addLive` and `addVideo` as a picked photo, and then uploaded before the next is read. A
  sealed record per account (`<account>.iphone-sync`, purpose `.photoSync`, on the device only) keeps
  the settings and the iPhone IDs already brought in or skipped. So nothing comes in twice, something
  deleted in Totality never comes back, and something deleted on the iPhone stays in Totality. Totality
  never writes to or deletes from the device's library. The version synced is the item as it is then,
  and later edits don't sync. It runs when Photos opens and in iOS background processing time while
  charging (`app.totality.photos.sync`), on Wi-Fi only unless mobile data is turned on. Originals kept
  only in iCloud come down only on Wi-Fi. A full account stops sync and says how much is left on the
  iPhone only. The limit stays 20 GB, with no paid storage. Not covered: a reinstall loses the record,
  so photos still in Totality could come in again.
- **Google Photos import** (issue 77, agreed 2026-11-08). It uses Google's Photos Picker API, because no
  app can read a whole Google Photos library any more: the person picks photos, videos or albums in
  Google Photos, up to 2,000 at a time, and Totality gets only those. It runs on the shared Google
  connection in `TotalityCore`, adding the scope `photospicker.mediaitems.readonly` with one consent
  tap, so a Google account already connected for Mail or Calendar needs no second sign-in. The Google
  Cloud project behind `TotalityGoogleClientID` must have the **Photos Picker API** enabled, or Google
  answers `SERVICE_DISABLED` and Photos says it's Totality's setup. Each item comes from Google's photo
  hosts (`*.googleusercontent.com` only, HTTPS, redirects elsewhere refused so the token stays with
  Google) straight to this device, stops at the size limit while downloading, and is sealed and uploaded
  before the next. Photos come at full resolution with Google's location removed (`=d`), and videos as
  Google's re-encoded copy (`=dv`). Videos Google is still preparing wait for another pick. Google gives
  no album names, so an optional "Put them in an album" field puts everything from one pick into one new
  album (G3, changed and agreed 2026-11-09). A sealed record per account (`<account>.google-import`,
  `.photoSync`, on the device only) keeps the Google IDs already brought in, so nothing comes twice, and
  the session and album of an import that stopped. Links last about an hour: when they run out the
  import stops, says so, and picking again carries on. Google Photos itself is never changed.

## Mail

Agreed with the owner on 2026-11-02, in issue 37, which holds the full spec. Mail stands apart from Supabase and Matrix: mailboxes and public keys live on the Oracle server, and arrival never calls an outside service, so nobody else learns when someone receives mail.

**Arrivals.** Cloudflare Email Routing hands every message to the Worker in `server/mail-worker/`, which streams it to `POST /mail/arrive` with a secret. `server/mail/mail.mjs` checks the address, asks Rspamd, seals, and writes. The order is what keeps the promise: nothing reaches the disk until it's sealed.

- **Bounce or wait.** Only three answers bounce: 410 no such address, 413 too big, and 507 mailbox full. Every other answer makes the Worker throw, which Cloudflare passes on as a temporary failure, and the sender's server tries again. The trial proved this with Gmail on 2026-11-02. Unknown addresses are 410 and not 404, because a tunnel with the wrong path answers 404 by itself, and that must never bounce mail.
- **Memory.** Readable mail exists only in the `mail` and `rspamd` containers, which have no swap, no core files, and no logs. The server has no swap at all. The core limit is 1 and not 0, because this server pipes crashes to Ubuntu's crash reporter, and a limit of 0 doesn't stop that: a test crash on 2026-11-02 wrote a report to `/var/crash`. A limit of 1 wrote nothing. At most four messages are held at once, and the rest wait at the sender. Buffers are wiped after sealing, which is best effort in a garbage-collected language, so the guarantee is "never on disk", not "gone from memory at once".
- **Spam.** Rspamd sits on a network with no way out, so nothing about a message can leave the server, and that's enforced by Docker, not by settings. It means no blocklists, so it judges by content alone. Cloudflare checks SPF, DKIM, and DMARC and writes the results into the message's headers. A failed spam check stores the message with no verdict, because losing mail is worse than missing spam.

**Sealing.** HPKE (RFC 9180) in base mode with X25519, HKDF-SHA256, and ChaCha20-Poly1305, because CryptoKit can open it, and the RFC's test vector runs against the server's code. A sealed file is version (1), encapsulated key (32), then ciphertext and tag. The info string is `totality/mail/v1`, and the mailbox and message IDs are authenticated, so a file can't be moved. Inside is one line of JSON with what the device can't work out, which is when it arrived and the spam verdict, then the message exactly as it came. `MailKeyTests` opens a file the server really sealed.

**Keys.** `MailKey` comes from the content key, so every device has it and the recovery key restores it. A device publishes the public half to `POST /mail/key`, signed in. The account comes from the sign-in and never from the request. There's one key per mailbox for good, and a different one gets a 409, so once a key is published a stolen session can't swap in its own and read what arrives afterwards.

- Before a key is published, whoever publishes first holds the mailbox for good, so a stolen password could claim an account with no key yet. The real owner would get a 409 and could only be recovered by hand on the server. So the app publishes as soon as the device's key is settled, and shows a 409 it didn't expect as a problem with the account.
- Before publishing from the app: a device that later joins a key backup adopts a different content key, and the published key can't be replaced. So publish only once the device's backup is settled.
- Public keys don't need to be secret, so step 5 can hand them to senders. Nobody can tell from a sealed file who sealed it, because anyone can seal to a public key, the server and a stolen sign-in included. So nothing in the standard seal is ever taken for a Sent copy, and a sender named in it counts only once the inner seal proves it.

**Between accounts (step 5).** Mail from one Totality account to another never touches Cloudflare. All three paths need a sign-in, and the sender is always the signed-in account, never anything in the request.

- **Sealing.** The sender's device fetches the recipient's public key from `GET /mail/recipient/<name>`, which answers with the key alone and never the mailbox, or 404. It writes the message with `MailWriter` and seals it with `MailKey.sealDirect`: HPKE in **auth mode**, authenticated by the sender's own `MailKey` private key, under the info string `totality/mail-direct/v2`, with the info, the sender's name, 0x00, the recipient's name, 0x00, and a fresh message ID as AAD, names lowercased. So the server can't mint a message from anyone, pass one person's message off as another's, or move it to someone else.
- **Pinned keys.** `MailPins` maps each lowercased Totality name to the public key first seen for it and when it was pinned. It isn't part of the settings: it's its own sealed object, kind `mail_keys` (meta only, ID derived from the account), so a settings conflict, rollback, or delete can't reach it. It only ever grows. Every pin goes through `MailVault.pin`, which reads, merges, and writes with no wait in between, so `send` and `open` running at once can't overwrite each other's pins. Sync merges rather than replaces: whatever arrives (newer, older, or a conflict, which always resolves to `store`'s merge) joins the pins already here as a union, and a server-side delete is ignored, so the next sync uploads the union again. Two different keys for one name keep the earlier pin (ties by key bytes, so every device settles on the same one) and mark the name disputed for good; nothing from a disputed name is proved, and nothing is sent to it (`keyChanged`). Pins that older builds kept in `MailSettings.knownKeys` are moved over the first time the vault reads them. On send, a recipient's key is pinned the first time; a different key later is refused for that person and reported as `MailSendResult.Outcome.keyChanged` ("This person's key changed"), and they stay on the draft. Reserved names pin the owner's key, which is what they resolve to.
- **`POST /mail/deliver`** takes `{to, id, sealed}`. The server wraps what the device sealed in the recipient's standard outer seal, with a facts line naming `from`, taken from the sign-in, and `to`, the name it was delivered to. `to` matters for reserved names like `abuse`, which deliver to the owner's mailbox: the inner seal names the reserved name, so the device needs it to open the message. The answers are 201 delivered, 409 already there (an earlier try whose answer was lost, so it counts as delivered), 404 no such address, 413 too big, and 507 their mailbox is full. Sending to yourself is allowed.
- **Proof.** When it downloads the message, the receiving device fetches the sender's key with `GET /mail/recipient/<from>` and opens the inner seal with `openDirect` in auth mode, using the facts line's `from` and `to`. With a pin, the pin is tried first; if the server now gives a different key, or only that different key opens it, the message is never proved and `MailWording.keyChanged` says the sender's key changed or couldn't be checked. Without a pin, the fetched key is pinned once it opens the message. What no key opens (base mode, or auth with someone else's key) is unreadable, never proved. Which key opened it, and whether it matched the pin, are kept with the message in the vault. It's proved only when that all checked out and the message's one From address is that sender. Otherwise it says who really sent it, with `MailWording.claimsSomeoneElse`. Only a proved message whose sender's key matched the pin carries the line "Sealed by the sender's device"; any other received message says "Totality couldn't confirm who sealed this." beside its warning. A server that names the wrong sender gets a message that won't open.
- **The remaining limit.** Pinning is trust on first use. A server that's compromised at someone's first contact with a person could hand out its own key for them then, read what's sent, and mint mail in their name, and the pin would hold its key from the start. Closing that needs people to verify each other's keys, which is Phase 2. Until then nothing says end-to-end encrypted.
- **`POST /mail/keep`** takes `{id, sealed}`: a Sent copy, Bcc included, kept exactly as it came, only in the caller's own mailbox, and only once that mailbox has a key. 201 or 409 means kept. Sent copies have their own format, version 2, sealed by `MailSentKey`: ChaCha20-Poly1305 under a key derived from the content root key with HKDF (info `totality/mail-sent/v1`), with the info, the account UUID, and the message UUID as AAD. Layout: version (2), nonce (12), ciphertext and tag (16). A session holder can't make one without the content key. The server takes only version 2 (first byte 2, longer than 29 bytes), and 400s anything else, version 1 included; `deliver` and arrivals still write version 1. The device opens version 1 with `MailKey.open` and never honours `"sent"` there, so it's Inbox or Spam; it opens version 2 only with `MailSentKey` and never honours `"from"` there.
- **Arrivals and devices share the cap** of four messages held at once, because it's what bounds the memory mail can use.
- **`POST /mail/send`** is outside mail (step 6). The device sends `{id, to, cc, bcc, subject, text, inReplyTo?, references?, attachments}` as JSON, readable, because outside mail can't be sealed: this is the other half of the agreed exception. There's no From in it. The server sets `username@usetotality.com` from the sign-in, checks every field (outside addresses only, no repeats, at most 10, no line breaks in headers, strict base64, 25 MiB), and hands it to the `totality-send` Worker (`server/send-worker/`) with `MAIL_SEND_SECRET`. The Worker calls Cloudflare's `send_email` binding with structured fields, keeps no logs (`observability` off), and returns only Cloudflare's error code. Limits: accounts under 7 days old get 403 `new`; each account gets 20 outside recipients a UTC day (429 `daily`); the whole server stops at 2,900 in any 31 days in a row (429 `monthly`), short of the 3,000 a month Workers Paid includes. Cloudflare counts by billing cycle, which can start on any day and is never longer than 31 days, so no cycle can hold more and sending never adds a charge. Counts live in `sending/` beside the mailboxes and hold numbers, dates, and message IDs only; a count that can't be read counts as full. Places come back only for Cloudflare codes that mean nothing was sent (validation, suppressed, rate or daily limit, size, header, and the Worker's own refusals). A failed delivery, an unknown code, no code, or a timeout keeps its places, since it may have gone and may count (422 `refused` or 504 `unknown`). An ID can't be used twice (409 `again`). With `MAIL_SEND_URL` or the secret unset, it answers 503 `off` without reading anything. The outside copy lists only the outside people, in their To, Cc, and Bcc places, because Totality people get their own sealed copy and listing them would send a second, unsealed one; so an outside person's Reply All won't include them. Cloudflare sets the outside copy's `Message-ID`, so it differs from the one in the Sent copy. A bounce later arrives as ordinary mail.
- **Drafts** sync as the `mail_draft` content kind, sealed like marks and settings: words, recipients, subject, and file names in `meta_cipher`, the files in the sealed body. The row's ID is derived on the device, so the sync server can't link a draft to the message it becomes.

**On the disk.** `~/totality/mailboxes` holds `boxes/<account>/public.key` and `<message>.sealed`, and `names/<username>`, which holds the account an address belongs to. An address exists once its name file does, and that's written last. Reserved names like `abuse` are name files added by hand on the server when mail goes live, pointing at the owner's account, so no account ID enters the repo. A name held by another mailbox gets a 409, so an account that somehow holds a reserved name can't take the address. The name files answer "no such address" until the owner's key exists.

**Not built yet.**

- A bounce is shown as the notice it arrives as, not yet as "Couldn't be delivered" on the Sent copy.
- Account deletion: the app has none yet, so a mailbox outlives an account deleted by hand and keeps accepting mail, sealed to the old key. A new account with that name gets a 409, so it can't inherit that mail, but it can't receive at the address either. Whatever deletes an account has to remove its folder and name file too.
- No backup, as the owner accepted.

## Mail screens

Issue 37, steps 4 and 5. The screens are in `Sources/TotalityMail`, and the app runs them on the real mailbox. `SampleMailStore` and `SampleMail` stay for previews and tests only, and `MailSampleNote` shows only on a sample store, so the app never shows it. Only a press on Send sends.

**The real store.** The screens only know `MailStore`: open, save marks, save settings, erase, and read an attachment. `ServerMailStore` is the real one. On open it publishes `MailKey.publicKey()` once per store (the server answers 200 for the same key), lists the server's messages, downloads only those the vault doesn't have, with progress, opens each with `MailKey` using the account's ID as the mailbox and the server's message ID, and keeps what opened in `MailVault`. It parses with `MailParser` each time it builds the `Mailbox`, so attachments live inside the kept message and are read back out when asked for. Marks and settings come from the vault, which syncs them.

- **The key gate.** A mailbox's key can never be replaced, so the store publishes, and contacts the server at all, only while `BackupModel.deviceCanSync()` is true: this device's key is the signed-in account's and has joined the key backup. Until then Mail says mail starts once the recovery key is set up, and shows the address. A 409 shows as a problem with the account, and the store remembers it, so it never asks again until the app starts over.
- **A seal that won't open** is kept with no contents and shown as "Can't be opened", and isn't fetched again. A message that won't parse is the parser's unreadable message.
- **Offline**, or a sign-in token that can't refresh, returns what the vault has, marked offline. Any other server failure is "Your mail didn't open", with Try again, even when the vault has mail. Treating an unreachable server like offline would need its own wording.
- **Mailbox full** is the list's `used >= limit`, shown on the list.
- **Erase** deletes from the server first, then the vault, so a message can't come back on the next download. Offline, it waits in the model.
- **Deleted on another device.** When publishing answers 200, the mailbox is the one the vault came from, so a message the server no longer lists was deleted on purpose, and it goes from the vault too. When it answers 201, the server made the mailbox afresh, perhaps after losing its disk, and the device keeps everything. If another device republished after such a loss first, this device would see 200 and drop mail the new server doesn't have. That's the no-backup risk the owner accepted, made a little wider.
- **In the app.** Mail's files are in Application Support/Totality/Mail, in the key ring as a `SealedArea`, so a key move reaches them. `MailWiring` in `ContentSetup.swift` opens one `MailVault` for the key's owner once the content key is open and the owner is known, and closes it when either changes. Sync takes that vault alongside the Reader's, Calendar's, and Web's, only while it's the syncing account's. The server client uses the same sign-in token as Web.
- **Your address** is `<username>@usetotality.com` (`MailDomain`), shown with Copy and Share in Mail's mailbox list, in the waiting state, and on the profile screen.

- **One account, one key.** `MailAccountModel` makes the store, and it starts a new `MailModel` on a new store whenever the device's owner changes or the content key moves, the same moments Web is told of. Nothing of one person's mail stays on screen, in memory, or waiting to be saved for the next. The real store is made in that closure, for the account it's given.
- **A fetch is older than the screen.** Mail fetches each time it appears. Anything changed on the device while a fetch was out, including marks, erasures, and settings, goes on top of what comes back, so a slow fetch can't undo a change that already saved.
- **Undo** takes back only the parts an action changed, and only while they're still as it left them. A folder added or a message read in the meantime stays.

- **What the real store has to work out.** `MailRoute` comes from how a message travelled and never from its address, because anyone can write a Totality address in a From line. `MailProof` comes from the checks Cloudflare writes into the headers. `.unreadable` is for a seal that won't open, where nothing but the date is known.
- **Block Sender** moves what's already here to Spam and adds to the blocked list. The server can't read a sender, so `ServerMailStore` puts a blocked sender's mail that has no marks of its own in Spam as it builds the mailbox.
- **Trash** empties when Mail opens, from `MailMarks.trashedAt`, through the store's erase, so it leaves the server too. Anything offline waits in the model and says how many changes are waiting.
- **Inline images.** `cid:` images in HTML mail aren't drawn yet, because that needs a parsed message. They should become `data:` URLs in `MailHTML.document`, which the page's policy already allows.

**Writing (step 5).** `MailComposer` holds one message being written, and `MailComposeView` is its sheet.

- **Where it starts.** New Message in the mailbox list's toolbar. Reply, Reply All, and Forward under a conversation's newest message, with Reply All only when it reaches more people than Reply. Forward reads the original's files first, and leaves off any that won't read. A draft in Drafts, listed above anything else there, resumes as it was left, and swipes or right-clicks to Discard with a confirm.
- **Addresses.** To, Cc, and Bcc as chips. Typing a comma, semicolon, or Return makes a chip, and `Name <address>` keeps the name. A chip that isn't an address shows in the warning colour and stops Send. Suggestions come only from the mail in this `Mailbox`, outside Spam and never the person themselves, most frequent first. Nothing typed leaves the device. At most ten people, as issue 37 agreed.
- **Files and signature.** Attachments from Files, and on iPhone from Photos, up to 25 MB written out. The signature is `MailSettings.signature`, edited from Signature in the Mailboxes list, sealed and synced like other settings. It goes under a new message, reply, or forward, above anything quoted.
- **Drafts.** The sheet saves through `MailModel.save` two seconds (`MailTiming.autosave`) after writing pauses, and again on close. A new message's signature alone isn't saved, and an empty draft is deleted. Discard asks first, then deletes it everywhere.
- **Send takes a press**, then waits `MailTiming.undo`, the same six seconds as Mail's other Undo, with Undo on screen. The draft is saved at the press, so a quit inside the window can't lose it. Only after the window does `MailModel.send` run. No one at all, or something that isn't an address, is caught before the window, and says why.
- **The outcome**, from `MailSendResult`, is shown per person in plain words (`MailWording.outcome`). Whoever didn't get it stays on the draft with everything written, and Back to the Draft returns to it. If nobody got it, there's no Sent copy and the draft is whole. A failed start (`MailWording.notSent`) keeps the draft and says why.
- **The labels.** Between accounts the sheet and the outcome say `MailWording.betweenAccounts`: "Sealed by your device. Totality's servers can't read it." The same line is under a Sent copy. Under a message received from another account, `MailWording.route(for:)` says `MailWording.betweenAccountsReceived`: "Sealed by the sender's device. Totality's servers carry it but can't open it." With only outside people on it, the sheet says `MailWording.outsideSending`, and with both, `MailWording.mixedSending`: each says outside email isn't end-to-end encrypted, that Totality's server and Cloudflare handle it, and that Cloudflare's log keeps the subject and addresses. A Sent copy that went to anyone outside says `MailWording.outside`. A message's warning strip shows `MailWording.warning(for:)`, which names a changed key when there is one. Nothing says end-to-end encrypted.
- **No lost Sent copy.** If `/mail/keep` fails, the copy is kept in the vault marked unkept (`keptCopy == false`), shows in Sent, and says it's only on this device for now. Every open sends unkept copies to `/mail/keep` first, and a copy still waiting isn't pruned though the server doesn't list it. `MailSendTests.unkeptCopyIsRetried` covers it.

**HTML mail is hostile.** `MailHTML` and `MailPage` show it, and `MailPageSafetyTests` loads a page of hostile tags in a real web view with a listener standing in for the sender's server. Scripts are off, `<link>` elements are renamed before loading, the page's policy refuses every load, a compiled rule list refuses them again, every navigation is cancelled, and a web link tap leaves for Web. While images are off, the web view's only way out is a SOCKS proxy that isn't there.

- `<link rel="preconnect">` opened a connection to the sender's server with the policy and the rule list both on, and only the view staying alive showed it. So a test has to keep the web view for as long as it waits.
- Local addresses skip proxies, so the tests can't catch the proxy with `127.0.0.1`. They point the proxy at a listener and load real hostnames instead.
- The rule lists live in their own store, because `WebBlocker` removes everything else from the shared one.
- Load Images asks for HTTPS images only. "Always load" only counts for a message that proves its sender and isn't in Spam, or anyone could borrow that sender's address.
- Attachments are read into memory and drawn only for kinds that can't run anything. HTML and SVG can be saved, never drawn.

**Home tiles.** The small tile shows `MailModel.glance`: the Inbox's unread count, then who wrote last, and its second line opens that conversation. The big tile, `MailHomeTile`, shows the count under a plain envelope, then the Inbox's newest conversations (1, 3, or 5 by size), each marked unread with the one accent dot and each opening itself through `requestFromHome`, which moves Mail to the Inbox. Only the Inbox reaches the home page, never Spam or Trash. Until Mail has opened with its key, both say only "Open to check your mail", because the home page is no place to report a key problem.

**Not built yet.** There's no outbox: a send that finds the device offline fails at once and stays a draft that says so, and nothing sends later on its own. Attachments from the Reader aren't offered yet, only Files and Photos. Downloads run one at a time, and Mail fetches only when it appears, since there's no push. Search stays inside Mail, and the home page's magnifying glass doesn't reach it. The Mac's selecting uses the same check marks as iPhone, not Shift or Command clicks.

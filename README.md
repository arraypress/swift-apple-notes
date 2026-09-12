# Swift Apple Notes

Read Apple Notes from Swift — folders, notes, bodies, attachments — by reading the store,
not by driving Notes.app.

```swift
import AppleNotes

let store = try NoteStore()
for note in try store.notes(inFolder: "Quick Notes") {
    print(note.title, note.modified ?? .distantPast)
}

let full = try store.note(id: 718)
print(full.markdown)
```

```
# A second note for testing
[drawing · “Text”]
- [ ] Check list
- [x] Check list 2
`monotype`
- Bullet 1
1. Numbered
[png · Screenshot.png · “A second note for testing …”]
```

## Read-only, and verified so

It never writes. Notes.app owns the CloudKit sync state, and editing that database behind
its back is how a syncing library gets corrupted.

Checked rather than claimed: after a batch of queries the database, its `-wal` and its
`-shm` are **byte-identical**. The `-shm` is the one worth testing — WAL readers ordinarily
need to write to it.

## `mode=ro`, never `immutable=1`

This is the correctness trap at the centre of the library. `immutable=1` looks safer — it
promises SQLite the file cannot change, so nothing locks and nothing is written — and it
**silently ignores the write-ahead log**. Measured on a live library:

| | notes found |
|---|---|
| `immutable=1` | 4 |
| `mode=ro` | **5** |

The missing one had been written seconds earlier and was sitting in a 1.8 MB uncheckpointed
WAL. Read-only reads the WAL; immutable reads yesterday.

## Why not AppleScript

Every other tool in this space drives Notes.app. That inherits its limits — the best-known
one documents "only notes in top-level folders are accessible", plus stripped tags and
ignored attachments — and it is slow:

| | |
|---|---|
| AppleScript, count 2 notes | **3.48 s** |
| this, full listing with folders | **0.008 s** |

Reading the store sees nested folders, tags, tables, drawings and Recently Deleted. None of
those reach AppleScript.

## A note row is not a note

Core Data leaves tombstones. One real library held **597 note rows, of which 593** had no
title, no body and no folder. A count of rows is not a count of notes, and the gap is big
enough to make a tool look broken. A live note needs a folder *and* a body.

Entity ids are looked up by name from `Z_PRIMARYKEY`, never hardcoded — Core Data assigns
`Z_ENT` when it builds the model and there is no promise it stays put across a macOS release.

## The body format

gzip over protobuf. Apple publishes no schema, so the field numbers here were established by
decoding real notes and checking that the **attribute-run lengths sum exactly to the
character count** — that reconciliation is what distinguishes a correct reading from a
plausible one.

Two things that are easy to get wrong:

- **Runs are not paragraphs.** A run is a span sharing attributes: a real note split
  "My Test Note" into runs of 1, 7 and 5 characters, and one run can also cover several
  lines. Paragraphs live in the newlines inside the text.
- **Lengths are UTF-16 units.** Apple stores an attributed string and attributed strings
  count UTF-16, so one emoji is two units. Counting characters slides every style after the
  first emoji.

## Confirmed against Apple's own code

The field numbers were worked out from decoded notes. They were then **checked against
`NotesShared.framework`**, which is a better oracle than any sample: `ICTTParagraphStyle`
is a live Objective-C class, and the runtime will list its properties.

| inferred | Apple's name |
|---|---|
| field 1 | `style` |
| field 4 | `indent` |
| field 5 | `todo` (`uuid`, `done`) |
| field 7 | `startingItemNumber` |
| field 8 | `blockQuoteLevel` |
| field 9 | `uuid` |

Every inference held, and two things improved. **`blockQuoteLevel` is a level**, not the
boolean it looked like — quotes nest. And the class answers questions about itself: setting
`style` and asking `isHeader` / `isList` / `isChecklist` settles every code without needing a
note that uses one. Codes 0, 1, 2 are headers; 100, 101, 102 are lists; 103 is a list *and* a
checklist and creates its own `ICTTTodo`.

That found a real bug: **code 3 is an explicit Body style** and was being kept as an unknown.
Notes writes no paragraph style for text it never styled, and code 3 for text set back to Body
from the format menu — both mean body, and only one was read that way.

Style codes, all confirmed: title (0), heading (1), subheading (2), body (3 or absent),
monospaced (4), bulleted (100), dashed (101), numbered (102), checklist (103, both tick
states). Code 5 exists in the runtime, matches nothing in the format menu, and is kept as
`.other(5)` rather than guessed at.

**Block quote is not a style code at all** — it is `blockQuoteLevel`, so a quoted bulleted
list is a real thing and reading `style` alone misses quoting entirely.
An unrecognised code is kept as `.other(code)` rather than flattened to body text, because
Apple adds paragraph styles and silently rendering a new one as plain text is how a tool
starts quietly misreporting someone's notes.

## Tables are a CRDT, and the grid is reconstructed

Notes writes a flattened reading of every table into the same summary column it uses for OCR.
It is free and it is lossy: **it drops empty cells**, so a 3×2 table with a blank last row
arrives as four cells with no hint that two are missing. A real table in a real library did
exactly that.

So the grid comes from the CRDT in `ZMERGEABLEDATA1` instead — a flat array of objects
referring to one another by index, with side tables holding every string once. The root is an
`ICTable` with `crRows` and `crColumns` (ordered sets) and `cellColumns`, a dictionary keyed
by column holding one dictionary per column keyed by row. Cells are reached **column first**
and transposed on the way out.

Two things make it harder than it sounds, and both cost a working decode:

- **An ordered set's elements are not the objects the cells key on.** The ordering names each
  element by UUID; the ordering's contents map that element to a *second* object with a
  *different* UUID, and that is what the cell dictionaries use. Matching the obvious one
  gives a table of the right shape with every cell empty.
- **Each column allocates its own copy of every row key.** The third column of a 2×3 table
  referred to both rows by objects the first two columns never mention, so rows are matched
  by UUID and never by object index.

Deleted rows take care of themselves: a CRDT keeps tombstones in the contents, and the order
holds only the live ones.

**A cell is not a string.** Its text is an attributed string carrying the same character
styling a note body does — bold, italic, underline, strikethrough, colour, and a link URL. The
first version read only the plain text, so a cell holding a link came back with the words and
without the address: the same loss that created `Span`, and invisible, because the cell still
rendered as words. A cell carries spans.

What a cell does *not* carry is a paragraph style. Field 2 on a cell's run is a CRDT
identifier where on a body's run it is the paragraph style, so reading it the same way would
invent headings and checklists inside table cells.

Verified against three real tables — 2×2, 2×3, and a 3×2 whose last row is empty. Row-major
is *measured*, from a table reading `A1 B1 C1 / A2 B2 C2`, not assumed. Column direction is
read and **reported rather than applied**: no right-to-left table was available to establish
whether Apple stores those columns reversed or renders them reversed, and guessing wrong
would silently mirror somebody's table.

## A drawing is not in the notes database

Every other attachment keeps something in `NoteStore.sqlite`. A `com.apple.paper` drawing
keeps **nothing** — its `ZMERGEABLEDATA1` is NULL and a reader that stops at the database
concludes it is empty. The contents are in a SQLite store of their own, one per drawing, at
`Accounts/<account>/Paper/Bundles/<identifier>.bundle/Database/data.sqlite3`: a
content-addressed table of objects, each a small CRDT, and **a different format from the one
tables use** — properties are named inline rather than through side tables.

What is read out of it: the canvas size, which inks were used and in what colour, and any
signature. Stroke geometry is not — it is readable and it is a lot of work for something no
caller can do much with, and the rendered PNG is already on disk.

**Colours are stored two ways.** An ink's is four protobuf `fixed32` fields, which the wire
format makes *little*-endian. A shape's, a text box's and a signature's is a bare sixteen-byte
blob of four *big*-endian floats. Read either with the other's byte order and you get numbers
near zero — which is still a valid colour, black — so the mistake renders instead of failing.

Verified against two real drawings, and verified *visually*: the decoded ink was
`com.apple.ink.marker` at `#FF6A00` and the shape `#C2C2C2` bordered `#F6CE46`, and the
rendered PNG contains exactly those colours in exactly those places.

## Signatures are a path, not a picture

A signature is a `CGPath` inside a keyed archive inside the drawing's object store: a stream
of `(element kind, point count, points…)`. The reconciliation that says this is understood
rather than plausible is that it **consumes exactly** — a real signature parsed to 59 elements
and 1,792 of 1,792 bytes, with no remainder. Anything that does not consume exactly, or names
an element kind above four, or disagrees with itself about how many points a curve has, is
rejected outright: a partial parse produces a signature-shaped nothing no caller can tell from
the real thing.

Being a path, it scales, and `Signature.svg` writes it straight out.

**Fill it, do not stroke it.** Every mark is a closed shape tracing *both sides* of the pen,
which is how a signature keeps its varying thickness. Stroking draws each mark as two thin
parallel lines with a hollow middle — which looks nearly right, and that is what makes it
worth saying.

## What a write can and cannot say

Writes go through AppleScript, which takes an HTML string — and that string is parsed by
`+[ICNote attributedStringFromHTMLString:]`, which is **a generic Cocoa HTML reader**. Calling
it directly settles what is possible without guessing at tags:

| given | it returns |
|---|---|
| `<h1>` | `NSFont`, bold 24pt — a font, not a style |
| `<blockquote>` | `NSPresentationIntent: BlockQuote` |
| any checklist markup | nothing |

It never produces an `ICTTParagraphStyle`. Notes' own paragraph styles are simply not
reachable **through this door** — and that qualifier matters, because there is another one. The ones that *do* survive survive because Notes infers them
afterwards from ordinary Cocoa attributes — an `NSTextList` becomes bulleted, dashed or
numbered, a Courier font becomes monospaced. Nothing infers a title, a heading, a checklist or
a quote; a checklist item needs an `ICTTTodo` carrying its own UUID, and an HTML reader has no
way to make one.

**The ceiling** — what Notes will accept from anybody through this door: bold, italic,
underline, strikethrough, links, text colour, `<ul>`, `<ol>`, nesting through nested lists,
`<tt>` for monospaced, and `<table><tr><td>`, which makes a real table attachment rather than a
picture of one. Not: checklists, block quotes, or real Title/Heading/Subheading styles. An
`<h1>` looks like a title in the app and is bold body text underneath.

**What this library actually writes is well under that ceiling: plain paragraphs.**
`NoteWriter` escapes its input, so `create` and `append` produce a title line and one `<div>`
per line and nothing else. None of the formatting above is exposed. That is a gap in this
code, not a limit of Notes — worth knowing before reaching for `append` to write a list.

The bridge is lossy in the other direction too, which corroborates it: export one of Notes' own
checklists through AppleScript and it comes back a plain bulleted list with the ticks gone.

### Markdown import does everything AppleScript cannot

Notes imports Markdown files, and that importer is **not** the HTML reader. Opening a `.md`
produced, in one pass:

| Markdown | what landed |
|---|---|
| `#` | style 0, a real Title |
| `##` | style 1, a real Heading |
| `- [ ]` / `- [x]` | style 103, **with the tick state** |
| `>` | a real `blockQuoteLevel` |
| a pipe table | a genuine table attachment |

So "Notes will not accept a checklist" was wrong, and it is worth being exact about what is
true instead: *AppleScript* cannot express one. Notes can be given one.

**It is not automatable, though.** The import is a Finder-level `open`, it raises Notes, it
**asks the user to confirm** before running, and it puts the note in an "Imported Notes" folder
of its own choosing. Markdown is not in the scripting dictionary either — the sdef exposes two
commands and nine note properties, and `body` is the only content door in it. So a script
still cannot write a checklist; a person with a `.md` file and one click can.

## A write takes a while to reach the database

Reads come from `NoteStore.sqlite`; writes go through Notes.app. Those are two views of the
same library that update at different times. Notes applies a change to its own model at once —
AppleScript sees it immediately — and writes the database on its own schedule.

Measured: a create or a rename showed up within a couple of seconds; a **delete took over a
minute** to move the note into Recently Deleted, and the note read back as live the whole time.
Nothing is lost and nothing needs retrying. A caller that needs certainty after a write has to
poll for it rather than assume.

**Do not retry a delete.** The first call moves a note to Recently Deleted, where it is
recoverable for thirty days. A second call on the same id **purges it**, with nothing to put
back — Notes' own interface makes you open the folder and confirm; AppleScript does it on the
second call with no ceremony.

That is easy to talk yourself into, because after a successful delete *everything looks like
nothing happened*: `osascript` exits 0, the database still lists the note where it was (it
lags, see above), and AppleScript still resolves the note by id — a note in Recently Deleted
is still a note. Measured: three notes deleted once each all reached Recently Deleted while
still resolving by id twenty seconds later.

An earlier version of this README said a delete can silently no-op and suggested issuing it
again. Both halves were wrong, and the advice destroyed the safety net it was trying to
protect.

## Highlighting is a code, not a colour

Notes stores a highlight as a small integer on the attribute run — 1 to 5 — rather than as a
colour value. That is why the palette is closed: the menu offers exactly five and there is no
way to write a sixth. Apple models it identically; the app's own method is
`updateHighlightColorPickerWithType:`. A *type*.

| code | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| | purple | pink | orange | mint | blue |

**The mapping is self-checking.** It came from a note holding five highlighted lines, each
line naming the colour it is highlighted in — so the text says "Mint" and the code says 4, and
no colour had to be recognised by eye. The names are Apple's, straight off the format menu.

Apple's RGB values for these are deliberately **not** recorded. The names are measured; the
pixels were not, and inventing five plausible hex codes would be a guess. Markdown gets
`<mark class="mint">`, which carries the name and asserts nothing about the colour.

Do not confuse it with **text colour**, which is a real colour on a different field. Notes has
no control that sets one, so it arrives with pasted rich text — but it was measured rather than
inferred, by writing known values through AppleScript: `color:#FF0000` comes back as exactly
`#FF0000`, `<font color>` the same, and `background-color` comes back as nothing at all,
because Notes does not store one. A colour is **discarded on a link**, which Notes always draws
in its own colour.

Text colour gets an inline style in the Markdown where a highlight gets a class, and the
difference is what is known: one is a measured RGB value, the other a name whose pixels never
were.

One field is still unread: **run field 16**, which is 1 on every run of a single note pasted in
from Safari and absent everywhere else. Not enough to name, so it is left alone.

## A placeholder names its own attachment

Notes marks an attachment's position in the text with U+FFFC, and the attribute run under it
carries the attachment's identifier — the same one the attachment row has.

Reading it matters more than it sounds. Placeholders come out in **document** order and
attachments come out in **database** order, and those are not the same order. Matching them by
counting along both lists is right until it is not: on a real note with a table, an image and a
drawing, it rendered the drawing where the table sits and slid the other two along behind it.
Every line still looked plausible, which is why it went unnoticed. Identity decides now, and
position is only the fallback.

## A recording carries what macOS heard

Word by word, each with the second it starts and how long it lasts — more than a transcript
usually gives you, because a caller can seek to a word rather than only read the sentence.

The reconciliation that says this is read correctly is that **the words join up**: sorted by
start, every word's end lands exactly on the next word's start across a real recording. Read
the timestamp from a neighbouring field and the sequence still sorts and still looks like a
transcript — it just stops joining up. `Transcript.isContiguous` is that check, kept as API
because it is worth having in a caller's hands too.

Two ways this differs from a table, in one library at the same time: a recording's blob is
**not gzipped** where a table's is, and its object graph sits at the **top level** where a
table's is two envelopes down. Neither is a version that will settle, so the reader looks for
the graph and tries inflating rather than assuming either.

An untranscribed recording carries the container with no segments in it, and reads back as
`nil` rather than an empty transcript — there is nothing to show either way, and `nil` does
not invite printing an empty quotation.

**Speakers are read and have always been empty.** Apple keeps a `speaker` on every segment;
a single-voice memo leaves it unset throughout. Whether a call recording fills it is untested.

## Where an attachment's bytes are

`Attachment.url` resolves the actual file. Media lives under the **media row's** identifier
rather than the attachment's — `ZMEDIA` is the link — inside a generation directory whose
name the database does not record, so that one directory is enumerated rather than guessed.
Drawings have no media file; they have a bundle and a rendered `previewURL`.

## What macOS already worked out

The system runs OCR and a classifier over attachments and leaves the results in the same
database, so a reader gets them free. **Verified** on a real note: a PNG's `ZOCRSUMMARY`
held the actual text from a screenshot, and its `ZSUMMARY` held a classifier's reading —
"Document Documents Papers Written Document".

**Handwriting is recognised**, and this took two goes to get right. The first drawing seen
had `ZHANDWRITINGSUMMARY` holding "Text" — and decoding that drawing showed a text box in
Helvetica containing the word "Text", so the summary proved only that the column reads. The
honest conclusion then was that stroke recognition was untested, and that is what the docs
said. Two later drawings settled it: pure freehand scribble, no text box in either, and the
column came back holding "③" and "}". Nonsense in, nonsense out — but nonsense that can only
have come from the strokes.

What is still untested is how well it reads *legible* handwriting, for want of anything
legibly handwritten to try it on.

## Locked notes

Listed, never opened. A password-protected body is encrypted with the user's passphrase,
which belongs nowhere near a library. Metadata reads; `isLocked` says so.

## Requirements

macOS 14+, Swift 6.2. **Full Disk Access** — the store is in a TCC-protected container, and
without it every call fails with an error naming the fix.

SQLite3 and Compression come from the OS. Nothing is vendored, nothing is fetched.

## Tested

144 tests over note bodies, tables, drawings and transcripts **assembled by hand** in the tests — a real note cannot
be a fixture here, since it belongs to whoever owns the Mac and changes when they edit it.
Building the gzip and protobuf independently of the reader means a passing test says the
format is understood, not that one function agrees with itself. That independence earned its
keep immediately: writing the table encoder surfaced a framing distinction the reader had
right and the writer had wrong.

Mutation-verified: counting characters instead of UTF-16, treating runs as paragraphs,
reading an absent style code as zero, dropping blank lines, or flattening an unknown style
each fails the suite. So does every table shortcut — transposing the grid, taking the order
from the contents dictionary instead of the ordering array, trusting the attachments'
emission order over their index numbers, or defaulting protobuf's omitted key index to
anything but zero. And every signature shortcut: not consuming the bytes exactly, not
checking a curve's point count against its kind, reading ink colour big-endian, or stroking
the path instead of filling it. And every transcript shortcut: leaving the words in graph
order, reading a double big-endian, or swapping timestamp for duration.

## Licence

MIT.

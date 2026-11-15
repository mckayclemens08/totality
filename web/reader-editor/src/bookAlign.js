// Lines up the text Listen reads with the text on a book's page. Both come from the same file in the same
// order, but not character for character: Listen's text has a line between blocks where the page has
// markup, and a few entities decode differently. So only the characters that aren't spaces are matched,
// in order, and a stretch that doesn't match is skipped past by looking a little ahead.
//
// Offsets are UTF-16 code units on both sides, as JavaScript strings and Swift's ListenScript count them.

/// How many characters must match to pick the thread up again after a difference.
const resync = 8;
/// How far ahead on the page a lost thread is looked for.
const window = 4000;

const isSpace = (code) => code === 32 || (code >= 9 && code <= 13) || code === 160 || code === 0x2028 || code === 0x2029 || code === 0xfeff;

/// The characters of `text` that aren't spaces, and where each sits.
function solid(text) {
  const chars = [];
  const offsets = [];
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (isSpace(code)) continue;
    chars.push(text[index]);
    offsets.push(index);
  }
  return { text: chars.join(""), offsets };
}

/// The page's text as one string, from its text pieces in order, with where each piece starts.
export function pageText(pieces) {
  const starts = [];
  let length = 0;
  for (const piece of pieces) {
    starts.push(length);
    length += piece.length;
  }
  return { text: pieces.join(""), starts };
}

/// `listen` is Listen's text for this page and `page` the page's own text. Returns a map that turns a
/// place in one into a place in the other.
export function align(listen, page) {
  const from = solid(listen);
  const to = solid(page);
  // For each solid character of Listen's text, the solid character of the page it matched, or -1.
  const match = new Int32Array(from.text.length).fill(-1);
  let i = 0;
  let j = 0;
  let matched = 0;
  while (i < from.text.length && j < to.text.length) {
    if (from.text[i] === to.text[j]) {
      match[i++] = j++;
      matched++;
      continue;
    }
    const probe = from.text.slice(i, i + resync);
    const found = probe.length === resync ? to.text.indexOf(probe, j) : -1;
    if (found !== -1 && found - j <= window) {
      j = found;
    } else {
      i++;
    }
  }
  return new BookMap(from, to, match, matched);
}

export class BookMap {
  constructor(from, to, match, matched) {
    this.from = from;
    this.to = to;
    // The matched pairs, both rising: Listen's solid character, and the page's.
    this.pairsFrom = new Int32Array(matched);
    this.pairsTo = new Int32Array(matched);
    let n = 0;
    for (let index = 0; index < match.length; index++) {
      if (match[index] === -1) continue;
      this.pairsFrom[n] = index;
      this.pairsTo[n++] = match[index];
    }
    /// How much of Listen's text was found on the page, from 0 to 1.
    this.coverage = from.text.length === 0 ? 0 : matched / from.text.length;
  }

  /// The page's text range for a range of Listen's text, or null when none of it is on the page.
  pageRange(start, end) {
    const first = lowerBound(this.from.offsets, start);
    const last = lowerBound(this.from.offsets, end) - 1;
    const a = lowerBound(this.pairsFrom, first);
    const b = lowerBound(this.pairsFrom, last + 1) - 1;
    if (a > b || a >= this.pairsFrom.length) return null;
    return [this.to.offsets[this.pairsTo[a]], this.to.offsets[this.pairsTo[b]] + 1];
  }

  /// The place in Listen's text of a place on the page, or null when nothing at or after it matched.
  listenOffset(pageOffset) {
    const target = lowerBound(this.to.offsets, pageOffset);
    const pair = lowerBound(this.pairsTo, target);
    if (pair >= this.pairsTo.length) return null;
    return this.from.offsets[this.pairsFrom[pair]];
  }
}

/// The first index whose value is at least `value`.
function lowerBound(values, value) {
  let low = 0;
  let high = values.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (values[mid] < value) low = mid + 1;
    else high = mid;
  }
  return low;
}

/// Which text piece holds a place in the page's joined text, and where in it.
export function locate(starts, offset) {
  let low = 0;
  let high = starts.length - 1;
  while (low < high) {
    const mid = (low + high + 1) >> 1;
    if (starts[mid] <= offset) low = mid;
    else high = mid - 1;
  }
  return { piece: low, offset: offset - (starts[low] || 0) };
}

/// Tags whose text the Reader never reads aloud, as its chapter parser skips them.
export const skippedTags = new Set(["head", "script", "style", "svg", "template", "nav", "noscript", "title"]);

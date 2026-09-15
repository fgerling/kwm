//! Line-framed reader for `bar.status.data`.
//!
//! The status source is a byte stream - a fifo, or stdin - so read boundaries
//! have nothing to do with line boundaries. Reading once into a fixed buffer
//! and drawing whatever came back does not truncate an over-long status line,
//! it *splits* it: the poll loop reads the remainder on its next iteration and
//! draws that on top, leaving the user looking at the tail of their own line.
//! A 259-byte line rendered as `52` - the last two digits of its clock.
//!
//! So: accumulate, cut on newlines, keep the *last* complete line. Last rather
//! than first because if we ever fall behind a fast writer, the newest status
//! is the only one worth drawing.

const Self = @This();

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const log = std.log.scoped(.status);

/// Room for a line of colour escapes (10 bytes each, plus 3 to reset) and
/// multi-byte glyphs, with enough headroom that nobody has to think about it.
/// The previous limit was 256, and was neither documented nor enforced.
pub const max_line = 4096;

/// Read, but not yet terminated by a newline.
pending: [max_line]u8 = undefined,
pending_len: usize = 0,
/// The last complete line. This is what the bar draws.
line: [max_line]u8 = undefined,
line_len: usize = 0,
/// Set when a writer overruns `pending` without a newline. Everything up to
/// the next newline is then a fragment of unknown provenance, so it is dropped
/// rather than drawn.
resyncing: bool = false,

pub fn text(self: *const Self) []const u8 {
    return self.line[0..self.line_len];
}

/// Feed one read()'s worth of bytes. True when a complete line arrived and the
/// bar needs redrawing.
pub fn feed(self: *Self, chunk: []const u8) bool {
    var rest = chunk;
    var updated = false;

    while (rest.len > 0) {
        if (self.resyncing) {
            const nl = mem.indexOfScalar(u8, rest, '\n') orelse return updated;
            self.resyncing = false;
            rest = rest[nl + 1 ..];
            continue;
        }

        const take = @min(self.pending.len - self.pending_len, rest.len);
        @memcpy(self.pending[self.pending_len..][0..take], rest[0..take]);
        self.pending_len += take;
        rest = rest[take..];

        if (mem.lastIndexOfScalar(u8, self.pending[0..self.pending_len], '\n')) |nl| {
            self.set(self.pending[0..nl]);
            updated = true;

            const keep = self.pending_len - (nl + 1);
            mem.copyForwards(u8, self.pending[0..keep], self.pending[nl + 1 .. self.pending_len]);
            self.pending_len = keep;
        } else if (self.pending_len == self.pending.len) {
            log.warn(
                "status line exceeds {} bytes with no newline; discarding to the next one",
                .{ self.pending.len },
            );
            self.pending_len = 0;
            self.resyncing = true;
        }
    }

    return updated;
}

/// A writer that closed mid-line still meant what it wrote. Only reachable for
/// stdin: the fifo is opened RDWR, so it always has a writer of its own and
/// never reports EOF.
pub fn flush(self: *Self) bool {
    if (self.pending_len == 0) return false;
    self.set(self.pending[0..self.pending_len]);
    self.pending_len = 0;
    return true;
}

fn set(self: *Self, complete: []const u8) void {
    // `complete` may hold several lines if a batch arrived at once; only the
    // last of them is current. A trailing empty line is a deliberate "clear the
    // status", not a reason to keep showing a stale one.
    const last = if (mem.lastIndexOfScalar(u8, complete, '\n')) |nl|
        complete[nl + 1 ..]
    else
        complete;

    self.line_len = @min(last.len, self.line.len);
    @memcpy(self.line[0..self.line_len], last[0..self.line_len]);
}


test "a whole line in one read" {
    var reader: Self = .{};
    try testing.expect(reader.feed("hello\n"));
    try testing.expectEqualStrings("hello", reader.text());
}

test "nothing is drawn until the line is complete" {
    var reader: Self = .{};
    try testing.expect(!reader.feed("hel"));
    try testing.expectEqualStrings("", reader.text());
    try testing.expect(!reader.feed("lo"));
    try testing.expectEqualStrings("", reader.text());
    try testing.expect(reader.feed("\n"));
    try testing.expectEqualStrings("hello", reader.text());
}

test "a batch of lines draws only the newest" {
    var reader: Self = .{};
    try testing.expect(reader.feed("first\nsecond\nthird\n"));
    try testing.expectEqualStrings("third", reader.text());
}

test "a trailing partial line is kept for the next read" {
    var reader: Self = .{};
    try testing.expect(reader.feed("done\npart"));
    try testing.expectEqualStrings("done", reader.text());
    try testing.expect(reader.feed("ial\n"));
    try testing.expectEqualStrings("partial", reader.text());
}

test "regression: a line longer than the old 256-byte buffer" {
    // The original failure. A 258-byte line plus its newline arrived as a
    // 256-byte read and then a 3-byte read, and the bar drew the 3 bytes.
    var long: [258]u8 = undefined;
    @memset(&long, 'x');
    @memcpy(long[248..258], "2026-09-15");

    var message: [259]u8 = undefined;
    @memcpy(message[0..258], &long);
    message[258] = '\n';

    var reader: Self = .{};
    // Split exactly where a 256-byte buffer would have split it.
    try testing.expect(!reader.feed(message[0..256]));
    try testing.expectEqualStrings("", reader.text()); // nothing drawn yet
    try testing.expect(reader.feed(message[256..259]));
    try testing.expectEqualStrings(&long, reader.text()); // the whole line
}

test "an empty line clears the status" {
    var reader: Self = .{};
    _ = reader.feed("something\n");
    try testing.expect(reader.feed("\n"));
    try testing.expectEqualStrings("", reader.text());
}

test "a writer that never sends a newline is discarded, not drawn" {
    var reader: Self = .{};

    var flood: [max_line]u8 = undefined;
    @memset(&flood, 'y');
    try testing.expect(!reader.feed(&flood)); // fills pending exactly
    try testing.expect(!reader.feed("more")); // now resyncing
    try testing.expectEqualStrings("", reader.text()); // no fragment drawn

    // Resynchronises on the next newline and behaves normally after it.
    try testing.expect(reader.feed("garbage\ngood\n"));
    try testing.expectEqualStrings("good", reader.text());
}

test "an over-long line does not leak into the next one" {
    var reader: Self = .{};

    var flood: [max_line + 100]u8 = undefined;
    @memset(&flood, 'z');
    _ = reader.feed(&flood);
    _ = reader.feed("\nclean\n");
    try testing.expectEqualStrings("clean", reader.text());
}

test "flush draws what a closing writer left behind" {
    var reader: Self = .{};
    try testing.expect(!reader.feed("no newline"));
    try testing.expect(reader.flush());
    try testing.expectEqualStrings("no newline", reader.text());
    try testing.expect(!reader.flush()); // nothing left the second time
}

test "colour escapes and multi-byte glyphs survive intact" {
    var reader: Self = .{};
    const line = "\u{f023} tun0 ^#46603Fff|^#! \u{f017} 17:37";
    try testing.expect(reader.feed(line ++ "\n"));
    try testing.expectEqualStrings(line, reader.text());
}

//! PDF document admission (issue #25).
//!
//! Core accepts a PDF as first-class user input and hands the bytes to the
//! provider's native document format. It never converts one behind the user's
//! back: there is no OCR, no text extraction, no page rasterisation, and no
//! summary substitution anywhere in this path. What this module owns is the
//! bounded admission decision taken *before* any expensive processing or
//! provider dispatch — is this really a PDF, is it readable at all, is it
//! within the size and page bounds we are willing to submit.
//!
//! Deliberate limits of the inspection, stated rather than hidden:
//!   - Page counting scans for uncompressed `/Type /Page` objects. A PDF that
//!     keeps its page tree inside a compressed object stream (`/ObjStm`, common
//!     for PDF 1.5+) yields `pages == null`, meaning "not determinable without
//!     a full parser". Such a document is still admitted; the byte cap remains
//!     its bound, and the provider enforces its own page limit.
//!   - Encryption is detected from `/Encrypt` in the authoritative trailer: the
//!     tail window, plus the window at the offset the last `startxref` names.
//!     That is where every conforming writer puts it (an incremental update's
//!     latest trailer is at the end by construction), but a document that hides
//!     it elsewhere is rejected by the provider instead of here. Both windows
//!     are fixed size, so no input shape can turn this scan superlinear.
//! Neither shortcut can silently degrade a document: the outcomes are admit or
//! an explicit typed error.

const std = @import("std");

/// The only document media type Core admits today.
pub const MEDIA_TYPE = "application/pdf";

/// Raw (pre-base64) byte ceiling for one submitted document. Base64 inflates
/// this to exactly `MAX_PDF_BASE64_BYTES`, which stays inside both the
/// AgentCore prompt cap and Anthropic's per-request payload limit.
pub const MAX_PDF_BYTES: usize = 12_000_000;

/// base64 length of `MAX_PDF_BYTES`. Derived, never restated: the AgentCore
/// wire cap is comptime-tied to this same expression.
pub const MAX_PDF_BASE64_BYTES: usize = std.base64.standard.Encoder.calcSize(MAX_PDF_BYTES);

/// Page ceiling for one submitted document, matching the documented native
/// document limit of the supported provider path.
pub const MAX_PDF_PAGES: usize = 100;

/// Upper-bound token cost of one submitted page. The provider bills a PDF page
/// as extracted text plus a page image; the published range is roughly
/// 1.5k-3k tokens, and this takes the top of it. Over-estimating only makes
/// auto-compaction fire earlier, while under-estimating overflows the window.
pub const PAGE_TOKEN_ESTIMATE: usize = 3000;

/// Bytes per page assumed when the page count is not determinable. A bounded
/// heuristic, not a measurement: the result is clamped to `MAX_PDF_PAGES`, so
/// the worst case is the same ceiling the admission check already enforces.
pub const ASSUMED_BYTES_PER_PAGE: usize = 20_000;

/// Token estimate for one document block. `base64_len` is the stored payload
/// length (raw size is 3/4 of it); `pages` is the counted page total, or null
/// when admission could not determine it.
pub fn estimateTokens(base64_len: usize, pages: ?u32) usize {
    const counted: usize = if (pages) |n| n else blk: {
        const raw = base64_len / 4 * 3;
        break :blk std.math.clamp(raw / ASSUMED_BYTES_PER_PAGE, 1, MAX_PDF_PAGES);
    };
    return @min(counted, MAX_PDF_PAGES) *| PAGE_TOKEN_ESTIMATE;
}

/// A PDF header may sit behind a small amount of leading junk; readers
/// tolerate it, so admission does too, within a bounded window.
const HEADER_SEARCH_BYTES: usize = 1024;

/// Size of each window scanned for `/Encrypt`: the file tail, and the region
/// starting at the cross-reference offset named by the last `startxref`.
const TRAILER_SCAN_BYTES: usize = 4096;

/// Upper bound on the decimal `startxref` offset we will parse. Anything
/// longer is malformed rather than large.
const MAX_XREF_OFFSET_DIGITS: usize = 20;

pub const Error = error{
    /// Not a PDF at all, or truncated past use.
    InvalidPdfDocument,
    /// Password-protected. Core will not guess, strip, or partially submit it.
    EncryptedPdfUnsupported,
    /// Above `MAX_PDF_BYTES`.
    PdfTooLarge,
    /// Above `MAX_PDF_PAGES` (only reachable when the count is determinable).
    PdfTooManyPages,
};

/// Admission decision over the raw document bytes: an error rejects the
/// document, success returns its counted page total, or null when the page
/// tree is not readable without a full PDF parser. Never a guessed count.
/// Pure: no allocation, no I/O, no mutation of the input.
pub fn inspect(bytes: []const u8) Error!?u32 {
    if (bytes.len == 0) return error.InvalidPdfDocument;
    if (bytes.len > MAX_PDF_BYTES) return error.PdfTooLarge;
    if (!hasHeader(bytes)) return error.InvalidPdfDocument;
    if (std.mem.indexOf(u8, bytes, "%%EOF") == null) return error.InvalidPdfDocument;
    if (looksEncrypted(bytes)) return error.EncryptedPdfUnsupported;
    const pages = countPages(bytes) orelse return null;
    if (pages > MAX_PDF_PAGES) return error.PdfTooManyPages;
    // Bounded by the check above, so the narrowing is total.
    return @intCast(pages);
}

/// Same decision for a base64 payload (the form both the ABI and the neutral
/// block carry). It is admission, not conversion — the decoded copy exists
/// only for the check and the original base64 is what reaches the provider.
/// **Peak memory**: the decode is bounded by `MAX_PDF_BYTES`, but callers that
/// pass an arena get no reclamation from the internal free, so a parts array
/// peaks at the sum of its decoded documents (itself bounded by the caller's
/// total-payload cap).
pub fn inspectBase64(allocator: std.mem.Allocator, base64: []const u8) (Error || error{OutOfMemory})!?u32 {
    if (base64.len == 0) return error.InvalidPdfDocument;
    if (base64.len > MAX_PDF_BASE64_BYTES) return error.PdfTooLarge;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(base64) catch return error.InvalidPdfDocument;
    const raw = try allocator.alloc(u8, size);
    defer allocator.free(raw);
    decoder.decode(raw, base64) catch return error.InvalidPdfDocument;
    return inspect(raw);
}

fn hasHeader(bytes: []const u8) bool {
    const window = bytes[0..@min(bytes.len, HEADER_SEARCH_BYTES)];
    return std.mem.indexOf(u8, window, "%PDF-") != null;
}

/// `/Encrypt` in the authoritative trailer. Two fixed windows: the file tail
/// (where a conventional trailer and a cross-reference stream dictionary both
/// end up, including after incremental updates) and the cross-reference object
/// the last `startxref` points at (which is how a linearized file keeps its
/// trailer reachable). Deliberately not "every `trailer` keyword in the file":
/// that is `O(occurrences x window)` and a crafted document could make it
/// scan gigabytes. Scanning the whole file instead would reject documents
/// whose compressed streams happen to contain those bytes.
fn looksEncrypted(bytes: []const u8) bool {
    if (windowHasEncrypt(bytes, bytes.len -| TRAILER_SCAN_BYTES)) return true;
    const offset = lastStartxrefOffset(bytes) orelse return false;
    if (offset >= bytes.len) return false;
    return windowHasEncrypt(bytes, offset);
}

fn windowHasEncrypt(bytes: []const u8, start: usize) bool {
    const end = @min(bytes.len, start + TRAILER_SCAN_BYTES);
    return std.mem.indexOf(u8, bytes[start..end], "/Encrypt") != null;
}

/// Decimal offset after the last `startxref` keyword, or null when it is
/// absent, empty, or not a bounded decimal number.
fn lastStartxrefOffset(bytes: []const u8) ?usize {
    const at = std.mem.lastIndexOf(u8, bytes, "startxref") orelse return null;
    var i = at + "startxref".len;
    while (i < bytes.len and isPdfSpace(bytes[i])) : (i += 1) {}
    const digits_start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) : (i += 1) {}
    const digits = bytes[digits_start..i];
    if (digits.len == 0 or digits.len > MAX_XREF_OFFSET_DIGITS) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// Counts `/Type` `/Page` objects (never `/Pages`, the tree node). Returns
/// null when none are visible, which means the page tree is compressed rather
/// than that the document has no pages.
fn countPages(bytes: []const u8) ?usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, pos, "/Type")) |at| {
        pos = at + "/Type".len;
        var i = pos;
        while (i < bytes.len and isPdfSpace(bytes[i])) : (i += 1) {}
        if (!std.mem.startsWith(u8, bytes[i..], "/Page")) continue;
        const after = i + "/Page".len;
        // `/Pages` is the tree node, not a page; any other name character
        // means a different key entirely.
        if (after < bytes.len and !isPdfDelimiter(bytes[after])) continue;
        count += 1;
    }
    return if (count == 0) null else count;
}

fn isPdfSpace(byte: u8) bool {
    return byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t' or byte == 0 or byte == 0x0c;
}

/// True at a token boundary: PDF name characters end at whitespace or at one
/// of the delimiter characters from the specification.
fn isPdfDelimiter(byte: u8) bool {
    if (isPdfSpace(byte)) return true;
    return switch (byte) {
        '/', '(', ')', '<', '>', '[', ']', '{', '}', '%' => true,
        else => false,
    };
}

/// Machine-stable outcome name for hosts and structured errors.
pub fn errorCode(err: Error) []const u8 {
    return switch (err) {
        error.InvalidPdfDocument => "invalid_pdf_document",
        error.EncryptedPdfUnsupported => "encrypted_pdf_unsupported",
        error.PdfTooLarge => "pdf_too_large",
        error.PdfTooManyPages => "pdf_too_many_pages",
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

/// Minimal well-formed PDF body with `page_count` uncompressed page objects.
fn testPdf(allocator: std.mem.Allocator, page_count: usize, extra: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "%PDF-1.7\n");
    try out.appendSlice(allocator, extra);
    for (0..page_count) |i| {
        try out.print(allocator, "{d} 0 obj\n<< /Type /Page /Parent 1 0 R >>\nendobj\n", .{i + 2});
    }
    try out.appendSlice(allocator, "trailer\n<< /Root 1 0 R >>\nstartxref\n0\n%%EOF\n");
    return out.toOwnedSlice(allocator);
}

test "inspect admits a well-formed PDF and counts its pages" {
    const allocator = std.testing.allocator;
    const doc = try testPdf(allocator, 3, "1 0 obj\n<< /Type /Pages /Count 3 >>\nendobj\n");
    defer allocator.free(doc);
    // `/Type /Pages` must not be counted as a page.
    try std.testing.expectEqual(@as(?u32, 3), try inspect(doc));
}

test "inspect rejects non-PDF, truncated, encrypted and over-long documents" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPdfDocument, inspect(""));
    try std.testing.expectError(error.InvalidPdfDocument, inspect("just text, definitely not a pdf"));
    try std.testing.expectError(error.InvalidPdfDocument, inspect("%PDF-1.7\n1 0 obj\n<< >>\nendobj\n"));

    const encrypted = try testPdf(allocator, 1, "");
    defer allocator.free(encrypted);
    const with_encrypt = try std.mem.replaceOwned(u8, allocator, encrypted, "trailer\n<< /Root", "trailer\n<< /Encrypt 9 0 R /Root");
    defer allocator.free(with_encrypt);
    try std.testing.expectError(error.EncryptedPdfUnsupported, inspect(with_encrypt));

    // Trailer far from the tail, reachable only through `startxref`: the
    // second window must still see it. Padding is a comment line, so the
    // document stays well formed.
    var far: std.ArrayList(u8) = .empty;
    defer far.deinit(allocator);
    try far.appendSlice(allocator, "%PDF-1.7\n");
    const xref_at = far.items.len;
    try far.appendSlice(allocator, "trailer\n<< /Encrypt 9 0 R /Root 1 0 R >>\n");
    try far.append(allocator, '%');
    try far.appendNTimes(allocator, 'x', 3 * TRAILER_SCAN_BYTES);
    try far.print(allocator, "\nstartxref\n{d}\n%%EOF\n", .{xref_at});
    try std.testing.expectError(error.EncryptedPdfUnsupported, inspect(far.items));

    const too_many = try testPdf(allocator, MAX_PDF_PAGES + 1, "");
    defer allocator.free(too_many);
    try std.testing.expectError(error.PdfTooManyPages, inspect(too_many));
}

test "inspect reports an undeterminable page count instead of guessing zero" {
    const allocator = std.testing.allocator;
    // No uncompressed page objects: a PDF 1.5+ file with its page tree inside
    // an object stream looks like this to a non-parsing scan.
    const doc = try testPdf(allocator, 0, "1 0 obj\n<< /Type /ObjStm /N 4 >>\nstream\nbinary\nendstream\nendobj\n");
    defer allocator.free(doc);
    try std.testing.expectEqual(@as(?u32, null), try inspect(doc));
}

test "inspectBase64 admits the encoded form and rejects malformed base64" {
    const allocator = std.testing.allocator;
    const doc = try testPdf(allocator, 2, "");
    defer allocator.free(doc);
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(doc.len));
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, doc);

    try std.testing.expectEqual(@as(?u32, 2), try inspectBase64(allocator, encoded));
    try std.testing.expectError(error.InvalidPdfDocument, inspectBase64(allocator, "!!!!"));
    try std.testing.expectError(error.InvalidPdfDocument, inspectBase64(allocator, ""));
}

test "estimateTokens uses the counted pages, and stays bounded without them" {
    try std.testing.expectEqual(@as(usize, 3 * PAGE_TOKEN_ESTIMATE), estimateTokens(400, 3));
    // Unknown page count: derived from size, clamped to at least one page and
    // never beyond the admission ceiling.
    try std.testing.expectEqual(@as(usize, PAGE_TOKEN_ESTIMATE), estimateTokens(64, null));
    try std.testing.expectEqual(
        @as(usize, MAX_PDF_PAGES * PAGE_TOKEN_ESTIMATE),
        estimateTokens(MAX_PDF_BASE64_BYTES, null),
    );
    // A malformed page count can never exceed the ceiling either.
    try std.testing.expectEqual(
        @as(usize, MAX_PDF_PAGES * PAGE_TOKEN_ESTIMATE),
        estimateTokens(400, 100_000),
    );
}

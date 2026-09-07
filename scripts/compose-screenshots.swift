#!/usr/bin/env swift
//
//  compose-screenshots.swift — the App Store 6.9" finals.
//
//  Usage:
//      swift scripts/compose-screenshots.swift <raw-dir> <out-dir>
//
//  Reads the raw device captures (shot-01.png …, 1320×2868 each) and writes
//  the finished store images at the same size: Silk's paper ground, the
//  caption set in the system serif above, and the capture below it.
//
//  Two of the six carry no capture at all — they are the claims no competitor
//  can put on their own page, and a screenshot of a screen would only get in
//  the way of them.
//
//  Every colour here is `Silk/DesignSystem.swift`'s: paper #F6F3EC, ink
//  #211E17, and the serif is the system's serif design (New York), which is
//  the face the app itself asks for.
//

import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - The page

let W: CGFloat = 1320
let H: CGFloat = 2868

/// Generous margins, as the brief asks — the restraint is carried by the
/// typography, so the paper around it has to be real.
let sideMargin: CGFloat = 132
let usableWidth = W - sideMargin * 2

let paper = CGColor(srgbRed: 246 / 255, green: 243 / 255, blue: 236 / 255, alpha: 1)
let ink = CGColor(srgbRed: 33 / 255, green: 30 / 255, blue: 23 / 255, alpha: 1)
let hairline = CGColor(srgbRed: 33 / 255, green: 30 / 255, blue: 23 / 255, alpha: 0.10)

/// The system serif. The app sets every sentence it speaks in
/// `.system(design: .serif)`, so the store page speaks in the same voice.
func serif(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .regular)
    if let descriptor = base.fontDescriptor.withDesign(.serif),
       let font = NSFont(descriptor: descriptor, size: size) {
        return font
    }
    return base
}

/// A display serif wants a little negative tracking; the app tracks its own
/// large serif at −0.02em and −0.045em, so this sits inside the family's range.
func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineHeightMultiple = 1.14
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: text, attributes: [
        .font: serif(size),
        .foregroundColor: NSColor(cgColor: ink)!,
        .kern: -0.018 * size,
        .paragraphStyle: paragraph
    ])
}

/// How tall the caption is, and how many lines it took, at a given size.
func measure(_ text: String, size: CGFloat) -> (height: CGFloat, lines: Int) {
    let string = attributed(text, size: size)
    let setter = CTFramesetterCreateWithAttributedString(string)
    let constraint = CGSize(width: usableWidth, height: .greatestFiniteMagnitude)
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        setter, CFRange(location: 0, length: 0), nil, constraint, nil)
    let path = CGPath(rect: CGRect(x: 0, y: 0, width: usableWidth, height: 100_000), transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    let lines = (CTFrameGetLines(frame) as! [CTLine]).count
    return (ceil(suggested.height), lines)
}

/// The largest size in the range that keeps the caption inside `maxLines`.
/// Stepped down a point at a time rather than bisected: the line count is not
/// monotonic in the size (a word can fall back up a line as the measure
/// changes), and one pass over 90 sizes costs nothing.
func fittingSize(_ text: String, maxLines: Int, from ceiling: CGFloat, to floor: CGFloat) -> CGFloat {
    var size = ceiling
    while size > floor {
        if measure(text, size: size).lines <= maxLines { return size }
        size -= 1
    }
    return floor
}

// MARK: - Drawing

func context() -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(paper)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldSmoothFonts(true)
    return ctx
}

/// Draws the caption with its first line's top at `top` (measured down from
/// the page's top edge) and returns the height it took.
@discardableResult
func draw(caption: String, size: CGFloat, top: CGFloat, in ctx: CGContext) -> CGFloat {
    let (height, _) = measure(caption, size: size)
    let string = attributed(caption, size: size)
    let setter = CTFramesetterCreateWithAttributedString(string)
    // CoreText fills a frame from its top edge down, and the page's origin is
    // its bottom-left — so the box is seated by its top and given a little
    // slack underneath for the last line's descenders.
    let box = CGRect(x: sideMargin, y: H - top - height - 8, width: usableWidth, height: height + 8)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                         CGPath(rect: box, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    return height
}

/// The capture, centred, with the device's own corner radius carried through
/// the scale, and a hairline so the frame reads as an object on the page
/// rather than a hole in it.
func draw(capture image: CGImage, width: CGFloat, top: CGFloat, in ctx: CGContext) {
    let height = width * H / W
    let rect = CGRect(x: (W - width) / 2, y: H - top - height, width: width, height: height)
    // 55pt of screen corner at 3× is 165px on a full-size capture; scaled with
    // the image so the corner stays the phone's, not the layout's.
    let radius = 165 * (width / W)
    let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.clip()
    ctx.draw(image, in: rect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(rounded)
    ctx.setStrokeColor(hairline)
    ctx.setLineWidth(3)                     // 1pt at 3×
    ctx.strokePath()
    ctx.restoreGState()
}

func write(_ ctx: CGContext, to url: URL) {
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("could not open \(url.path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
        exit(1)
    }
}

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("missing capture \(url.path)\n".utf8))
        exit(1)
    }
    return image
}

// MARK: - The six

/// The line breaks are authored, not left to the wrapper. Left to it, a
/// caption breaks after a full stop and starts the next line on the two-letter
/// word that opens the next sentence — "No streaks. No / leaderboard." — which
/// is the one typographic fault a page set this large cannot hide. So each
/// caption carries its own breaks, and the fitted size is the largest at which
/// the wrapper adds none of its own.
struct Shot {
    let number: String
    /// Newline-separated. Every line is a phrase that can stand alone.
    let caption: String
    /// nil for the two typographic pages, whose caption is the whole image.
    let capture: String?
    /// What the wrapper is allowed to add on top of the authored breaks. Zero
    /// for the captions above a capture; the typographic pages let their one
    /// long sentence run on, because breaking it by hand at every size would
    /// be authoring a shape rather than a sentence.
    let slack: Int

    var authoredLines: Int { caption.split(separator: "\n", omittingEmptySubsequences: false).count }
    var maxLines: Int { authoredLines + slack }
}

let shots = [
    Shot(number: "01",
         caption: """
         When the budget is spent,
         the blocked app shows
         when it opens again.
         """,
         capture: "shot-01.png", slack: 0),
    Shot(number: "02",
         caption: """
         Minutes left today,
         and which apps
         are open right now.
         """,
         capture: "shot-02.png", slack: 0),
    Shot(number: "03",
         caption: """
         Write \u{201C}unlock Instagram
         for 10 min.\u{201D} It opens
         for ten and locks again.
         """,
         capture: "shot-03.png", slack: 0),
    // Broken short and even rather than at the sentence's own comma. One
    // size is fitted across every captioned page and it is the smallest any
    // one of them needs, so a single long line here does not just set this
    // caption — it re-typesets 01, 02 and 03 with it. "The score for the last
    // full day," is 32 characters and costs the whole set ten points (102 →
    // 92); the break below is three lines of about the same measure as the
    // three above it, and the other pages do not move at all. Both halves of
    // the sentence still land whole: the score, what it is of, and what
    // stands next to it.
    Shot(number: "04",
         caption: """
         The score
         for the last full day,
         and the week beside it.
         """,
         capture: "shot-04.png", slack: 0),
    // The two pages with no phone on them are set larger, and the measure is
    // what buys the size: a line of about seventeen characters at this width
    // carries type half again as big as the captions do. So both are broken
    // short.
    Shot(number: "05",
         caption: """
         Silk sends
         no notifications
         and keeps
         no streaks.
         """,
         capture: nil, slack: 0),
    Shot(number: "06",
         caption: """
         Silk is free.
         The blocking
         never depends
         on a payment.
         """,
         capture: nil, slack: 0)
]

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: compose-screenshots.swift <raw-dir> <out-dir>\n".utf8))
    exit(2)
}
let rawDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outDir = URL(fileURLWithPath: arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// One size for every captioned capture, and one for the two typographic pages
// — a store page whose headline changes size from slot to slot reads as six
// pages rather than one product. The size is the smallest that any single
// caption needs, so nothing is ever set tighter than the page allows.
let captioned = shots.filter { $0.capture != nil }
let typographic = shots.filter { $0.capture == nil }

let captionSize = captioned
    .map { fittingSize($0.caption, maxLines: $0.maxLines, from: 118, to: 74) }
    .min() ?? 118
let typographicSize = typographic
    .map { fittingSize($0.caption, maxLines: $0.maxLines, from: 168, to: 86) }
    .min() ?? 120

let captionTop: CGFloat = 156
let gap: CGFloat = 118
let bottomMargin: CGFloat = 112

// One reserved block for every captioned page, and therefore one capture size
// across all of them. Sized off the tallest caption: three pages whose phone
// is three different sizes read as three layouts, and the whole argument of
// this page set is that it is one voice.
let captionBlock = captioned.map { measure($0.caption, size: captionSize).height }.max() ?? 0
// The capture takes what the caption left, capped at the 82% of width the
// brief asks for. It does not reach it: 82% of the width is 82% of the height
// on a full-screen capture, which leaves 500px for a caption, a gap and two
// margins — and a caption set large enough to carry a store card is three
// lines of serif. The type won; the report says so.
let captureWidth = min(W * 0.82, (H - captionTop - captionBlock - gap - bottomMargin) * W / H)

for shot in shots {
    let ctx = context()
    let size = shot.capture == nil ? typographicSize : captionSize
    let (height, lines) = measure(shot.caption, size: size)
    if let name = shot.capture {
        draw(caption: shot.caption, size: size, top: captionTop, in: ctx)
        draw(capture: load(rawDir.appendingPathComponent(name)),
             width: captureWidth, top: captionTop + captionBlock + gap, in: ctx)
    } else {
        draw(caption: shot.caption, size: size, top: (H - height) / 2, in: ctx)
    }
    let out = outDir.appendingPathComponent("\(shot.number).png")
    write(ctx, to: out)
    print("\(shot.number)  \(Int(size))px  \(lines) lines  \(Int(height))px  \(out.lastPathComponent)")
}
print("capture \(Int(captureWidth))px wide (\(Int(captureWidth / W * 100))% of the page)")

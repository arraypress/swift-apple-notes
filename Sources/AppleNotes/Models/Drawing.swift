//
//  Drawing.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  What is inside a drawing — the `com.apple.paper` attachment Notes writes for the markup
//  canvas: freehand ink, shapes, text boxes and signatures.
//
//  A DRAWING IS NOT IN THE NOTES DATABASE. Unlike every other attachment, its contents live
//  in a SQLite database of their own, one per drawing, at
//  `Accounts/<account>/Paper/Bundles/<identifier>.bundle/Database/data.sqlite3`. That store is
//  content-addressed — a table of objects keyed by id, each a small CRDT — and a different
//  format from the mergeable data a table uses. So `ZMERGEABLEDATA1` is NULL on every drawing
//  and a reader looking only at the database concludes, wrongly, that it is empty.
//
//  WHAT IS DECODED HERE is the part that survives being described in words: the canvas size,
//  which inks were used and in what colour, and any signature as a path. Stroke geometry —
//  the pressure and tilt samples behind each mark — is NOT decoded. It is readable and it is
//  a great deal of work for something no caller can do much with, and the rendered image is
//  right there in ``Drawing/previewURL``.
//
//  COLOURS ARE STORED TWO WAYS and the difference is not cosmetic. An ink's colour is four
//  protobuf `fixed32` fields, which are LITTLE-endian by the wire format. A shape's, a text
//  box's and a signature's is a bare sixteen-byte blob of four BIG-endian floats. Reading
//  either with the other's byte order gives numbers near zero that still look like a valid
//  colour — black — so this is a mistake that renders rather than crashes.
//
//  VERIFIED against the two drawings in a real library, and verified VISUALLY: the decoded
//  ink was `com.apple.ink.marker` at #FF6A00 and the shape #C2C2C2 filled with a #F6CE46
//  border, and the rendered PNG contains exactly those colours in exactly those places.
//

import Foundation

/// A drawing made on the Notes markup canvas.
public struct Drawing: Equatable, Hashable, Sendable, Codable {

    /// The canvas width in points.
    public let width: Double

    /// The canvas height in points.
    public let height: Double

    /// Which inks were used, and in what colour.
    ///
    /// One entry per ink the strokes refer to, so an ink used by nine strokes appears once
    /// with a `strokes` of nine.
    public let inks: [Ink]

    /// Signatures placed on the canvas.
    public let signatures: [Signature]

    /// What the drawing uses, in Apple's own words.
    ///
    /// Read from the attachment's small JSON metadata blob, which names the features rather
    /// than describing the content: whether it holds a graph, whether it holds handwritten
    /// maths, which generation of ink set it was drawn with.
    public let features: [String]

    /// The rendered image macOS keeps beside the drawing.
    ///
    /// A PNG at twice the canvas size, which is the whole drawing as a person sees it. For
    /// most callers this is the answer and everything else here is metadata about it.
    public let previewURL: URL?

    public init(width: Double, height: Double, inks: [Ink] = [], signatures: [Signature] = [],
                features: [String] = [], previewURL: URL? = nil) {
        self.width = width
        self.height = height
        self.inks = inks
        self.signatures = signatures
        self.features = features
        self.previewURL = previewURL
    }

    /// A one-line description for a listing.
    public var summary: String {
        var parts = [String(format: "%.0f×%.0f drawing", width, height)]
        if !inks.isEmpty {
            parts.append(inks.map { "\($0.name) \($0.hex)" }.joined(separator: ", "))
        }
        if !signatures.isEmpty {
            parts.append(signatures.count == 1 ? "1 signature" : "\(signatures.count) signatures")
        }
        if !features.isEmpty { parts.append(features.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}

/// One ink used in a drawing.
public struct Ink: Equatable, Hashable, Sendable, Codable {

    /// Apple's identifier, such as `com.apple.ink.pen` or `com.apple.ink.marker`.
    public let identifier: String

    /// How many strokes use it.
    public let strokes: Int

    /// What colour it draws in.
    public let colour: Colour

    public init(identifier: String, strokes: Int, colour: Colour) {
        self.identifier = identifier
        self.strokes = strokes
        self.colour = colour
    }

    /// The tool's name — the last component of the identifier, so `pen` or `marker`.
    public var name: String { identifier.split(separator: ".").last.map(String.init) ?? identifier }

    /// The colour as `#RRGGBB`.
    public var hex: String { colour.hex }
}

/// A signature placed on a drawing.
///
/// Stored as a `CGPath` — a stream of elements, each a kind and the points it needs — inside
/// a keyed archive inside the drawing's object store. It is a path and not an image, so it
/// scales, and it can be written straight out as SVG.
///
/// THE PATH IS AN OUTLINE AND MUST BE FILLED, NOT STROKED. Every mark is a closed shape
/// tracing both sides of the pen, which is how a signature keeps its varying thickness.
/// Stroking it draws each mark as two thin parallel lines with a hollow middle — legible
/// enough to look correct at a glance, which is what makes it worth saying. ``svg`` fills.
public struct Signature: Equatable, Hashable, Sendable, Codable {

    /// One element of the path.
    public struct Element: Equatable, Hashable, Sendable, Codable {

        /// What `CGPathElementType` calls it.
        public enum Kind: Int, Sendable, Codable {
            case move = 0, line = 1, quadratic = 2, cubic = 3, close = 4

            /// How many points the element carries.
            var points: Int {
                switch self {
                case .move, .line: return 1
                case .quadratic: return 2
                case .cubic: return 3
                case .close: return 0
                }
            }
        }

        public let kind: Kind
        public let points: [Point]

        public init(kind: Kind, points: [Point]) {
            self.kind = kind
            self.points = points
        }
    }

    /// A point on the canvas.
    public struct Point: Equatable, Hashable, Sendable, Codable {
        public let x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    /// The strokes, in the order they were drawn.
    public let elements: [Element]

    public init(elements: [Element]) { self.elements = elements }

    /// How many times the pen went down — one per `move`.
    public var strokeCount: Int { elements.filter { $0.kind == .move }.count }

    /// The box the signature occupies, or `nil` if it has no points.
    public var bounds: (x: Double, y: Double, width: Double, height: Double)? {
        let points = elements.flatMap(\.points)
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return (minX, minY, maxX - minX, maxY - minY)
    }

    /// A complete SVG document, sized to the signature and filled black on transparent.
    ///
    /// Filled rather than stroked, for the reason on the type. Returns an empty string when
    /// there is nothing to draw.
    public var svg: String {
        guard let box = bounds else { return "" }
        let pad = 8.0
        let width = box.width + pad * 2, height = box.height + pad * 2
        let header = String(format: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%.2f\" height=\"%.2f\"", width, height)
        let view = String(format: " viewBox=\"%.2f %.2f %.2f %.2f\">", box.x - pad, box.y - pad, width, height)
        return header + view + "<path d=\"" + svgPath + "\" fill=\"black\"/></svg>"
    }

    /// The path as an SVG `d` attribute.
    public var svgPath: String {
        func pair(_ point: Point) -> String { String(format: "%.2f %.2f", point.x, point.y) }
        return elements.map { element in
            let points = element.points.map(pair).joined(separator: " ")
            switch element.kind {
            case .move: return "M \(points)"
            case .line: return "L \(points)"
            case .quadratic: return "Q \(points)"
            case .cubic: return "C \(points)"
            case .close: return "Z"
            }
        }.joined(separator: " ")
    }
}

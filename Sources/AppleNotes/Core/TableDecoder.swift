//
//  TableDecoder.swift
//  AppleNotes
//
//  Created by David Sherlock on 2026.
//
//  A table attachment's CRDT, turned back into rows and columns.
//
//  THE SHAPE OF IT. The root object is an `ICTable` with three attributes that matter:
//  `crRows` and `crColumns`, each an ordered set, and `cellColumns`, a dictionary keyed by
//  column holding one dictionary per column keyed by row. So a cell is reached column first
//  and the grid has to be transposed on the way out — which is also why the flattened summary
//  Notes writes alongside is row-major and this is not.
//
//  THE PART THAT IS NOT OBVIOUS, and cost a working decode that produced the right shape with
//  every cell empty: an ordered set's ELEMENTS are not the objects the rest of the graph
//  refers to. The ordering array names each element by UUID; the ordering's contents map that
//  element to a SECOND object, carrying a DIFFERENT UUID, and it is that second object the
//  cell dictionaries are keyed by. Worse, each column allocates its own copy of it — the
//  third column of a 2×3 table referred to both rows by objects the first two columns never
//  mention. So rows and columns are matched by UUID and never by object index.
//
//  DELETED ROWS TAKE CARE OF THEMSELVES. A CRDT keeps a tombstone for anything removed, so
//  the contents dictionary can name more rows than the table has. The order comes from the
//  ordering array, which holds only the live ones, and everything here iterates that.
//
//  VERIFIED against three real tables: 2×2, 2×3 and a 3×2 whose last row is empty. The cells
//  land where their names say they should, and the empty row is present — the flattened
//  summary for that third table has four cells and no way to tell you six were expected.
//

import Foundation

/// Decoding a table attachment.
public enum TableDecoder {

    /// Attribute names on the root object, measured from real tables.
    enum Attribute {
        static let rows = "crRows"
        static let columns = "crColumns"
        static let cells = "cellColumns"
        static let direction = "crTableColumnDirection"
        /// The one attribute the direction register's own object holds.
        static let value = "self"
    }

    /// The direction Notes writes when the columns run right to left.
    static let rightToLeft = "CRTableColumnDirectionRightToLeft"

    /// Turn a table attachment's stored blob into a grid.
    ///
    /// - Parameter data: the raw `ZMERGEABLEDATA1` blob.
    /// - Returns: the table, or `nil` if the blob holds no table.
    public static func decode(_ data: Data) -> Table? {
        guard let graph = MergeableData.graph(data),
              case .map(_, let root)? = graph.entries.first else { return nil }

        let rowOrder = axis(root[Attribute.rows], in: graph)
        let columnOrder = axis(root[Attribute.columns], in: graph)
        guard !rowOrder.isEmpty, !columnOrder.isEmpty else { return nil }

        var grid = [[Table.Cell]](repeating: [Table.Cell](repeating: Table.Cell(text: ""),
                                                          count: columnOrder.count),
                                  count: rowOrder.count)
        if case .dictionary(let columns)? = graph.entry(root[Attribute.cells]) {
            for (columnKey, columnCells) in columns {
                guard let uuid = graph.uuid(of: columnKey),
                      let column = columnOrder.firstIndex(of: uuid),
                      case .dictionary(let cells)? = graph.entry(columnCells) else { continue }
                for (rowKey, cell) in cells {
                    guard let uuid = graph.uuid(of: rowKey),
                          let row = rowOrder.firstIndex(of: uuid) else { continue }
                    grid[row][column] = self.cell(cell, in: graph)
                }
            }
        }
        return Table(rows: grid, isRightToLeft: isRightToLeft(root, in: graph))
    }

    /// One cell, with the character styling its text carries.
    ///
    /// A cell's runs use the same character vocabulary a note body does — weight, underline,
    /// strikethrough, colour, link — but NOT its paragraph vocabulary: field 2 on a cell run
    /// is a CRDT identifier where on a body run it is the paragraph style, so only the
    /// character half is read.
    static func cell(_ reference: MergeableData.Reference?,
                     in graph: MergeableData.Graph) -> Table.Cell {
        guard case .text(let text, let runs)? = graph.entry(reference) else {
            return Table.Cell(text: graph.text(of: reference) ?? "")
        }
        return Table.Cell(text: text, spans: BodyDecoder.characterSpans(text: text, runs: runs))
    }

    /// One ordered set resolved to the UUIDs the cell dictionaries are keyed by, in order.
    ///
    /// The ordering's contents pair each element with the object the cells use. Which side of
    /// the pair is which is not fixed, so the side whose UUID appears in the order is taken as
    /// the element and the other as the key.
    static func axis(_ reference: MergeableData.Reference?, in graph: MergeableData.Graph) -> [Data] {
        guard case .orderedSet(let set)? = graph.entry(reference) else { return [] }
        var keyed: [Data: Data] = [:]
        let live = Set(set.order)
        for (left, right) in set.pairs {
            let leftUUID = graph.uuid(of: left)
            let rightUUID = graph.uuid(of: right)
            if let element = leftUUID, live.contains(element), let key = rightUUID {
                keyed[element] = key
            } else if let element = rightUUID, live.contains(element), let key = leftUUID {
                keyed[element] = key
            }
        }
        return set.order.compactMap { keyed[$0] }
    }

    /// Whether the table's column direction says right to left.
    static func isRightToLeft(_ root: [String: MergeableData.Reference],
                              in graph: MergeableData.Graph) -> Bool {
        guard case .register(let inner)? = graph.entry(root[Attribute.direction]),
              case .map(_, let holder)? = graph.entry(inner),
              case .string(let direction)? = holder[Attribute.value] else { return false }
        return direction == rightToLeft
    }
}

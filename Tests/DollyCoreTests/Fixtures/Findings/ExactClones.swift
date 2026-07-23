// swift-format-ignore-file
// Two token-identical rendering routines: the classic copy-paste clone.
// The engine reports the group once, anchored at the first member.

struct GridCell {
    let row: Int
    let column: Int
    let weight: Double
}

func renderPrimaryGrid(cells: [GridCell]) -> String {  // #dl:expect exact-clone
    var output = ""
    for cell in cells {
        if cell.weight > 0.5 {
            output += "[#\(cell.row):\(cell.column)]"
        } else {
            output += "[ \(cell.row):\(cell.column)]"
        }
        if cell.column == 7 {
            output += "\n"
        }
    }
    return output
}

func renderSecondaryGrid(cells: [GridCell]) -> String {
    var output = ""
    for cell in cells {
        if cell.weight > 0.5 {
            output += "[#\(cell.row):\(cell.column)]"
        } else {
            output += "[ \(cell.row):\(cell.column)]"
        }
        if cell.column == 7 {
            output += "\n"
        }
    }
    return output
}

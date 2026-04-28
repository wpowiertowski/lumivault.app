import SwiftUI

/// CRT-styled fixed-grid canvas used by retro mini-games.
///
/// The drawing closure receives a `RetroPainter` that maps integer cell
/// coordinates to filled rects, so callers don't deal with pixel math.
struct RetroCanvas: View {
    let columns: Int
    let rows: Int
    let draw: (RetroPainter) -> Void

    var body: some View {
        GeometryReader { geo in
            let cell = min(geo.size.width / CGFloat(columns), geo.size.height / CGFloat(rows))
            let width = cell * CGFloat(columns)
            let height = cell * CGFloat(rows)
            let originX = (geo.size.width - width) / 2
            let originY = (geo.size.height - height) / 2

            ZStack {
                Canvas { context, _ in
                    let painter = RetroPainter(
                        cell: cell,
                        originX: originX,
                        originY: originY,
                        columns: columns,
                        rows: rows,
                        context: context
                    )
                    painter.fillBackground()
                    draw(painter)
                }
                scanlines
                    .frame(width: width, height: height)
                    .offset(x: originX, y: originY)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Constants.Design.accentColor.opacity(0.4), lineWidth: 1)
        )
    }

    private var scanlines: some View {
        Canvas { context, size in
            let lineHeight: CGFloat = 2
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(.black.opacity(0.18)))
                y += lineHeight
            }
        }
    }
}

struct RetroPainter {
    let cell: CGFloat
    let originX: CGFloat
    let originY: CGFloat
    let columns: Int
    let rows: Int
    let context: GraphicsContext

    func fillBackground() {
        let rect = CGRect(x: originX, y: originY, width: cell * CGFloat(columns), height: cell * CGFloat(rows))
        context.fill(Path(rect), with: .color(.black))
    }

    /// Fills a single grid cell.
    func fillCell(x: Int, y: Int, color: Color, inset: CGFloat = 1) {
        let rect = CGRect(
            x: originX + CGFloat(x) * cell + inset,
            y: originY + CGFloat(y) * cell + inset,
            width: cell - inset * 2,
            height: cell - inset * 2
        )
        context.fill(Path(rect), with: .color(color))
    }

    /// Fills a rectangular block of cells (e.g. a pipe).
    func fillRect(x: Int, y: Int, width: Int, height: Int, color: Color) {
        let rect = CGRect(
            x: originX + CGFloat(x) * cell,
            y: originY + CGFloat(y) * cell,
            width: cell * CGFloat(width),
            height: cell * CGFloat(height)
        )
        context.fill(Path(rect), with: .color(color))
    }

    /// Draws monospaced text inside the canvas at a given cell origin.
    func drawText(_ text: String, atCellX cellX: Int, cellY: Int, color: Color) {
        let resolved = context.resolve(
            Text(text)
                .font(.system(size: cell * 1.4, design: .monospaced).weight(.bold))
                .foregroundColor(color)
        )
        context.draw(resolved, at: CGPoint(
            x: originX + CGFloat(cellX) * cell,
            y: originY + CGFloat(cellY) * cell
        ), anchor: .topLeading)
    }
}

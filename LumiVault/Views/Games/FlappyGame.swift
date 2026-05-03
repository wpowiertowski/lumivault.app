import SwiftUI

@Observable
final class FlappyGame {
    struct Pipe: Equatable {
        var x: Double          // left edge in cells (can be fractional for smooth motion)
        let gapTop: Int        // first cell of the gap
        let gapHeight: Int
        var scored: Bool = false
    }

    let columns: Int
    let rows: Int
    let pipeWidth: Int = 3
    let gravity: Double = 0.45     // cells per tick²
    let flapImpulse: Double = -1.6 // cells per tick
    let scrollSpeed: Double = 0.35 // cells per tick

    private(set) var birdY: Double
    private(set) var velocity: Double = 0
    private(set) var pipes: [Pipe] = []
    private(set) var score: Int = 0
    private(set) var isGameOver: Bool = false
    private(set) var hasStarted: Bool = false
    private var pipeSpawnCountdown: Double

    let birdX: Int = 6

    init(columns: Int = 30, rows: Int = 20) {
        self.columns = columns
        self.rows = rows
        self.birdY = Double(rows) / 2
        self.pipeSpawnCountdown = 0
    }

    func reset() {
        birdY = Double(rows) / 2
        velocity = 0
        pipes.removeAll()
        score = 0
        isGameOver = false
        hasStarted = false
        pipeSpawnCountdown = 0
    }

    func flap() {
        if isGameOver { return }
        hasStarted = true
        velocity = flapImpulse
    }

    func tick() {
        guard !isGameOver else { return }
        // The bird hovers until the player's first flap, so the first frame
        // is a friendly landing pad rather than an instant fall.
        guard hasStarted else { return }

        velocity += gravity
        birdY += velocity

        if birdY < 0 || birdY >= Double(rows) {
            isGameOver = true
            return
        }

        for i in pipes.indices {
            pipes[i].x -= scrollSpeed
        }
        pipes.removeAll { $0.x + Double(pipeWidth) < 0 }

        pipeSpawnCountdown -= scrollSpeed
        if pipeSpawnCountdown <= 0 {
            spawnPipe()
            pipeSpawnCountdown = 11 // cells between pipe pairs
        }

        let birdCellY = Int(birdY)
        for i in pipes.indices {
            let pipeLeftCell = Int(pipes[i].x.rounded(.down))
            let pipeRightCell = pipeLeftCell + pipeWidth - 1

            // Score when the pipe's right edge passes behind the bird.
            if !pipes[i].scored && pipeRightCell < birdX {
                pipes[i].scored = true
                score += 1
            }

            if birdX >= pipeLeftCell && birdX <= pipeRightCell {
                let inGap = birdCellY >= pipes[i].gapTop && birdCellY < pipes[i].gapTop + pipes[i].gapHeight
                if !inGap {
                    isGameOver = true
                    return
                }
            }
        }
    }

    private func spawnPipe() {
        let gapHeight = 6
        let minTop = 2
        let maxTop = max(minTop, rows - gapHeight - 2)
        let gapTop = Int.random(in: minTop...maxTop)
        pipes.append(Pipe(x: Double(columns), gapTop: gapTop, gapHeight: gapHeight))
    }
}

struct FlappyGameView: View {
    @State private var game = FlappyGame()
    @State private var highScore: Int = UserDefaults.standard.integer(forKey: "games.flappy.highScore")
    @State private var tickTask: Task<Void, Never>?

    private let tickInterval: Duration = .milliseconds(60)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("SCORE \(game.score)")
                Spacer()
                Text("HIGH \(highScore)")
            }
            .font(Constants.Design.monoCaption)
            .foregroundStyle(Constants.Design.accentColor)

            RetroCanvas(columns: game.columns, rows: game.rows) { painter in
                // pipes
                for pipe in game.pipes {
                    let leftCell = Int(pipe.x.rounded(.down))
                    let topHeight = pipe.gapTop
                    let bottomY = pipe.gapTop + pipe.gapHeight
                    let bottomHeight = game.rows - bottomY
                    if topHeight > 0 {
                        painter.fillRect(x: leftCell, y: 0, width: game.pipeWidth, height: topHeight, color: Constants.Design.accentColor)
                    }
                    if bottomHeight > 0 {
                        painter.fillRect(x: leftCell, y: bottomY, width: game.pipeWidth, height: bottomHeight, color: Constants.Design.accentColor)
                    }
                }
                // bird (3-cell sprite)
                let birdCellY = Int(game.birdY)
                painter.fillCell(x: game.birdX, y: birdCellY, color: .yellow)
                painter.fillCell(x: game.birdX - 1, y: birdCellY, color: .yellow.opacity(0.7))
                painter.fillCell(x: game.birdX + 1, y: birdCellY, color: .yellow.opacity(0.7))

                if game.isGameOver {
                    painter.drawText("GAME OVER", atCellX: max(0, game.columns / 2 - 5), cellY: game.rows / 2 - 1, color: .red)
                    painter.drawText("PRESS R", atCellX: max(0, game.columns / 2 - 3), cellY: game.rows / 2 + 1, color: .white)
                } else if !game.hasStarted {
                    painter.drawText("SPACE TO FLAP", atCellX: max(0, game.columns / 2 - 7), cellY: game.rows / 2, color: .white)
                }
            }
            .aspectRatio(CGFloat(game.columns) / CGFloat(game.rows), contentMode: .fit)

            Text("Space or click to flap • R to restart")
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.secondary)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .space:
                if game.isGameOver { game.reset() } else { game.flap() }
                return .handled
            case KeyEquivalent("r"), KeyEquivalent("R"):
                game.reset(); return .handled
            default:
                return .ignored
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if game.isGameOver { game.reset() } else { game.flap() }
        }
        .onAppear { startLoop() }
        .onDisappear { tickTask?.cancel() }
    }

    private func startLoop() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                if !game.isGameOver {
                    game.tick()
                    if game.score > highScore {
                        highScore = game.score
                        UserDefaults.standard.set(highScore, forKey: "games.flappy.highScore")
                    }
                }
            }
        }
    }
}

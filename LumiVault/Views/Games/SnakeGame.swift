import SwiftUI

@Observable
final class SnakeGame {
    enum Direction {
        case up, down, left, right
        var delta: (x: Int, y: Int) {
            switch self {
            case .up: (0, -1)
            case .down: (0, 1)
            case .left: (-1, 0)
            case .right: (1, 0)
            }
        }
        func isOpposite(of other: Direction) -> Bool {
            switch (self, other) {
            case (.up, .down), (.down, .up), (.left, .right), (.right, .left): true
            default: false
            }
        }
    }

    struct Cell: Equatable { let x: Int; let y: Int }

    let columns: Int
    let rows: Int
    private(set) var snake: [Cell]
    private(set) var direction: Direction
    private(set) var pendingDirection: Direction
    var food: Cell
    private(set) var score: Int = 0
    private(set) var isGameOver: Bool = false
    private(set) var hasStarted: Bool = false

    init(columns: Int = 28, rows: Int = 18) {
        self.columns = columns
        self.rows = rows
        let mid = Cell(x: columns / 2, y: rows / 2)
        self.snake = [mid, Cell(x: mid.x - 1, y: mid.y), Cell(x: mid.x - 2, y: mid.y)]
        self.direction = .right
        self.pendingDirection = .right
        self.food = Cell(x: columns - 4, y: rows / 2)
        self.food = Self.spawnFood(columns: columns, rows: rows, occupied: snake)
    }

    func reset() {
        let mid = Cell(x: columns / 2, y: rows / 2)
        snake = [mid, Cell(x: mid.x - 1, y: mid.y), Cell(x: mid.x - 2, y: mid.y)]
        direction = .right
        pendingDirection = .right
        food = Self.spawnFood(columns: columns, rows: rows, occupied: snake)
        score = 0
        isGameOver = false
        hasStarted = false
    }

    /// Begin advancing on the next tick. The game sits idle until this is
    /// called so a freshly-presented board can't run itself into a wall
    /// before the player has had a chance to react.
    func start() {
        hasStarted = true
    }

    func turn(_ new: Direction) {
        // Compare against the locked-in direction so a player can't 180° into themselves
        // by quickly hitting two perpendicular keys before the next tick.
        guard !direction.isOpposite(of: new) else { return }
        pendingDirection = new
    }

    func tick() {
        guard hasStarted, !isGameOver else { return }
        direction = pendingDirection
        let head = snake[0]
        let next = Cell(x: head.x + direction.delta.x, y: head.y + direction.delta.y)

        if next.x < 0 || next.y < 0 || next.x >= columns || next.y >= rows {
            isGameOver = true
            return
        }

        let willEat = next == food
        // Tail will move out of its current cell unless we grow this tick.
        let body = willEat ? snake : snake.dropLast()
        if body.contains(next) {
            isGameOver = true
            return
        }

        if willEat {
            snake = [next] + snake
            score += 1
            food = Self.spawnFood(columns: columns, rows: rows, occupied: snake)
        } else {
            snake = [next] + Array(snake.dropLast())
        }
    }

    private static func spawnFood(columns: Int, rows: Int, occupied: [Cell]) -> Cell {
        let occupiedSet = Set(occupied.map { $0.x * 10_000 + $0.y })
        var candidates: [Cell] = []
        candidates.reserveCapacity(columns * rows - occupied.count)
        for x in 0..<columns {
            for y in 0..<rows where !occupiedSet.contains(x * 10_000 + y) {
                candidates.append(Cell(x: x, y: y))
            }
        }
        return candidates.randomElement() ?? Cell(x: 0, y: 0)
    }
}

struct SnakeGameView: View {
    @State private var game = SnakeGame()
    @State private var isRunning = true
    @State private var highScore: Int = UserDefaults.standard.integer(forKey: "games.snake.highScore")
    @State private var tickTask: Task<Void, Never>?

    private let tickInterval: Duration = .milliseconds(110)

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
                // food
                painter.fillCell(x: game.food.x, y: game.food.y, color: .red)
                // snake — head brighter than body
                for (i, cell) in game.snake.enumerated() {
                    let color = i == 0 ? Constants.Design.accentColor : Constants.Design.accentColor.opacity(0.7)
                    painter.fillCell(x: cell.x, y: cell.y, color: color)
                }
                if game.isGameOver {
                    painter.drawText("GAME OVER", atCellX: max(0, game.columns / 2 - 5), cellY: game.rows / 2 - 1, color: .red)
                    painter.drawText("PRESS R", atCellX: max(0, game.columns / 2 - 3), cellY: game.rows / 2 + 1, color: .white)
                } else if !game.hasStarted {
                    painter.drawText("SPACE TO START", atCellX: max(0, game.columns / 2 - 7), cellY: game.rows / 2, color: .white)
                }
            }
            .aspectRatio(CGFloat(game.columns) / CGFloat(game.rows), contentMode: .fit)

            Text("Space to start • Arrows or WASD to move • Space to pause • R to restart")
                .font(Constants.Design.monoCaption2)
                .foregroundStyle(.secondary)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            handleKey(press.key)
        }
        .onAppear { startLoop() }
        .onDisappear { tickTask?.cancel() }
    }

    private func startLoop() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                if isRunning && !game.isGameOver {
                    game.tick()
                    if game.score > highScore {
                        highScore = game.score
                        UserDefaults.standard.set(highScore, forKey: "games.snake.highScore")
                    }
                }
            }
        }
    }

    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .upArrow, KeyEquivalent("w"): game.turn(.up); return .handled
        case .downArrow, KeyEquivalent("s"): game.turn(.down); return .handled
        case .leftArrow, KeyEquivalent("a"): game.turn(.left); return .handled
        case .rightArrow, KeyEquivalent("d"): game.turn(.right); return .handled
        case KeyEquivalent("r"), KeyEquivalent("R"):
            game.reset(); isRunning = true; return .handled
        case .space:
            // First space press kicks off play; subsequent presses pause/resume.
            if !game.hasStarted {
                game.start()
            } else {
                isRunning.toggle()
            }
            return .handled
        default: return .ignored
        }
    }
}

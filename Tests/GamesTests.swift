import Testing
import Foundation
@testable import LumiVault

@Suite
@MainActor
struct SnakeGameTests {
    @Test func startsWithThreeSegmentsMovingRight() {
        let game = SnakeGame(columns: 20, rows: 10)
        #expect(game.snake.count == 3)
        #expect(game.direction == .right)
        #expect(!game.isGameOver)
        #expect(game.score == 0)
        #expect(!game.hasStarted)
    }

    @Test func snakeHoldsBeforeFirstStart() {
        let game = SnakeGame(columns: 20, rows: 10)
        let initialHead = game.snake[0]
        game.tick()
        game.tick()
        #expect(game.snake[0] == initialHead)
        #expect(!game.isGameOver)
    }

    @Test func tickAdvancesHeadByOneCell() {
        let game = SnakeGame(columns: 20, rows: 10)
        // Pin food to the corner so the next tick can't accidentally consume it.
        game.food = SnakeGame.Cell(x: 0, y: 0)
        game.start()
        let head = game.snake[0]
        game.tick()
        let newHead = game.snake[0]
        #expect(newHead.x == head.x + 1)
        #expect(newHead.y == head.y)
        #expect(game.snake.count == 3)
    }

    @Test func cannotReverseDirectly() {
        let game = SnakeGame(columns: 20, rows: 10)
        game.food = SnakeGame.Cell(x: 0, y: 0)
        // Snake starts moving right. Trying to turn left should be ignored
        // and the snake should keep moving right rather than colliding with itself.
        game.turn(.left)
        game.start()
        let head = game.snake[0]
        game.tick()
        #expect(game.snake[0].x == head.x + 1)
        #expect(!game.isGameOver)
    }

    @Test func collidingWithRightWallEndsGame() {
        let game = SnakeGame(columns: 8, rows: 8)
        game.food = SnakeGame.Cell(x: 0, y: 0)
        game.start()
        for _ in 0..<10 {
            if game.isGameOver { break }
            game.tick()
        }
        #expect(game.isGameOver)
    }

    @Test func eatingFoodGrowsSnakeAndIncrementsScore() {
        let game = SnakeGame(columns: 20, rows: 10)
        // Force food directly in front of the head so the very next tick eats it.
        let head = game.snake[0]
        game.food = SnakeGame.Cell(x: head.x + 1, y: head.y)
        game.start()
        game.tick()
        #expect(game.score == 1)
        #expect(game.snake.count == 4)
    }

    @Test func resetReturnsToInitialState() {
        let game = SnakeGame(columns: 20, rows: 10)
        game.start()
        for _ in 0..<5 { game.tick() }
        game.reset()
        #expect(game.snake.count == 3)
        #expect(game.score == 0)
        #expect(game.direction == .right)
        #expect(!game.isGameOver)
        #expect(!game.hasStarted)
    }
}

@Suite
@MainActor
struct FlappyGameTests {
    @Test func birdHoversBeforeFirstFlap() {
        let game = FlappyGame(columns: 30, rows: 20)
        let initialY = game.birdY
        game.tick()
        game.tick()
        #expect(game.birdY == initialY)
        #expect(!game.isGameOver)
    }

    @Test func flapAppliesUpwardImpulse() {
        let game = FlappyGame(columns: 30, rows: 20)
        let before = game.birdY
        game.flap()
        game.tick()
        #expect(game.birdY < before)
    }

    @Test func gravityPullsDownAfterFlap() {
        let game = FlappyGame(columns: 30, rows: 20)
        game.flap()
        game.tick()
        let afterFirst = game.birdY
        for _ in 0..<20 { game.tick() }
        // No further flap - bird should have descended past the post-flap apex.
        #expect(game.birdY > afterFirst)
    }

    @Test func birdHittingFloorEndsGame() {
        let game = FlappyGame(columns: 30, rows: 20)
        game.flap()
        // Run enough ticks for gravity to drag the bird below the floor.
        for _ in 0..<200 {
            if game.isGameOver { break }
            game.tick()
        }
        #expect(game.isGameOver)
    }

    @Test func resetClearsState() {
        let game = FlappyGame(columns: 30, rows: 20)
        game.flap()
        for _ in 0..<10 { game.tick() }
        game.reset()
        #expect(game.score == 0)
        #expect(game.pipes.isEmpty)
        #expect(!game.isGameOver)
        #expect(!game.hasStarted)
    }
}


import SwiftUI

enum RetroGame: String, CaseIterable, Identifiable {
    case snake = "Snake"
    case flappy = "Flappy"
    var id: String { rawValue }
}

/// Coalesced snapshot of `PhotosImportProgress` fields used by the game step.
/// The import pipeline mutates `PhotosImportProgress` at full speed; while the
/// games are on screen, a 30 Hz task copies into this mirror so the SwiftUI
/// view tree re-renders at most ~30×/sec. That leaves MainActor with enough
/// slack for the game tick task to fire on schedule.
@Observable
final class GameProgressMirror {
    var fraction: Double = 0
    var phaseLabel: String = ""
    var currentFilename: String = ""
    var totalFiles: Int = 0
    var currentFile: Int = 0
}

struct GameStepView: View {
    let progress: GameProgressMirror
    let onExit: () -> Void

    @State private var game: RetroGame = .snake

    var body: some View {
        VStack(spacing: 12) {
            // Top progress strip — kept compact so the game gets most of the sheet.
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fraction)
                    Text("\(Int(progress.fraction * 100))%")
                        .font(Constants.Design.monoCaption)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    Text(progress.phaseLabel)
                        .foregroundStyle(.secondary)
                    if !progress.currentFilename.isEmpty {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(progress.currentFilename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if progress.totalFiles > 0 {
                        Text("\(progress.currentFile)/\(progress.totalFiles)")
                            .foregroundStyle(.quaternary)
                    }
                }
                .font(Constants.Design.monoCaption2)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Picker("", selection: $game) {
                ForEach(RetroGame.allCases) { g in
                    Text(g.rawValue).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .frame(maxWidth: 220)

            Group {
                switch game {
                case .snake: SnakeGameView()
                case .flappy: FlappyGameView()
                }
            }
            .id(game)              // remount on switch so each game starts fresh
            .padding(.horizontal)

            HStack {
                Spacer()
                Button("Back to Progress", action: onExit)
                    .accessibilityIdentifier("import.games.back")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

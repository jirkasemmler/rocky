import RockyCore
import SwiftUI

/// Local cache of exercise images downloaded from the Rocky server (content-addressed by sha256,
/// immutable). Filled by the sync client; read here.
enum AssetCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("assets", isDirectory: true)
    }

    static func fileURL(for assetID: String) -> URL {
        directory.appendingPathComponent(assetID)
    }

    static func data(for assetID: String?) -> Data? {
        guard let assetID, !assetID.isEmpty else { return nil }
        return try? Data(contentsOf: fileURL(for: assetID))
    }
}

extension Exercise {
    /// Placeholder pictogram until the server provides a real image.
    var pictogram: String {
        switch id {
        case "squat", "bulgarian-split-squat": return "figure.strengthtraining.functional"
        case "push-up", "close-grip-push-up": return "figure.cross.training"
        case "bent-over-row", "romanian-deadlift": return "figure.strengthtraining.traditional"
        case "overhead-press": return "figure.strengthtraining.traditional"
        case "plank", "side-plank", "dead-bug": return "figure.core.training"
        case "reverse-lunge": return "figure.mixed.cardio"
        case "glute-bridge": return "figure.pilates"
        default: return equipment == .dumbbells ? "figure.strengthtraining.traditional" : "figure.core.training"
        }
    }
}

/// Exercise image (cached from the server) or a pictogram placeholder.
struct ExerciseImageView: View {
    let exercise: Exercise
    var height: CGFloat = 120

    var body: some View {
        Group {
            if let image = loadedImage {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: exercise.pictogram)
                    .resizable()
                    .scaledToFit()
                    .padding(height * 0.15)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Obrázek: \(exercise.name)")
    }

    private var loadedImage: Image? {
        #if canImport(UIKit)
        if let data = AssetCache.data(for: exercise.imageAssetID), let ui = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        #endif
        return nil
    }
}

#if os(iOS)
/// "Jak na to": image, target and the longer instructions of one exercise.
struct ExerciseDetailView: View {
    let exercise: Exercise

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ExerciseImageView(exercise: exercise, height: 260)
                Text(exercise.targetLabel).font(.title3.bold())
                Label(exercise.equipment.label, systemImage: "dumbbell").foregroundStyle(.secondary)
                Text(exercise.techniqueTip).font(.headline)
                if let instructions = exercise.instructions, !instructions.isEmpty {
                    Text(instructions)
                }
            }
            .padding()
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

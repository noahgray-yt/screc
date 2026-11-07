import Foundation

/// Screc's own wallpapers (SPEC §3.4): procedural mesh gradients, drawn by a shader from these parameters,
/// so they are sharp at any size. Names, colours and layouts are original.
public struct Wallpaper: Identifiable, Equatable, Sendable {
    public enum Category: String, CaseIterable, Sendable { case dawn = "Dawn", ocean = "Ocean", forest = "Forest", night = "Night" }

    public var id: String
    public var name: String
    public var category: Category
    /// Four colour points: (#RRGGBB, x, y) with x, y in 0…1 of the canvas.
    public var points: [(color: String, x: Double, y: Double)]
    /// How strongly the gradient is bent (0 = straight blends, 1 = strong swirls).
    public var warp: Double
    /// Seed for the warp field.
    public var seed: Double

    public static func == (a: Wallpaper, b: Wallpaper) -> Bool { a.id == b.id }
}

public enum Wallpapers {
    public static let defaultID = "dawn-1"

    public static let all: [Wallpaper] = [
        // Dawn: warm sunrise tones
        .init(id: "dawn-1", name: "First Light", category: .dawn,
              points: [("#FFB38A", 0.1, 0.15), ("#FF6F91", 0.85, 0.2), ("#FFD6A5", 0.2, 0.9), ("#C86BFA", 0.9, 0.85)], warp: 0.55, seed: 1.3),
        .init(id: "dawn-2", name: "Apricot", category: .dawn,
              points: [("#FFCF99", 0.0, 0.0), ("#FF9E7A", 1.0, 0.3), ("#F7E8D0", 0.3, 1.0), ("#FF7A7A", 0.8, 0.95)], warp: 0.35, seed: 2.1),
        .init(id: "dawn-3", name: "Rose Haze", category: .dawn,
              points: [("#F9C5D1", 0.2, 0.1), ("#9795EF", 0.9, 0.1), ("#FDE2E4", 0.1, 0.8), ("#F28EB0", 0.75, 0.9)], warp: 0.6, seed: 3.7),
        .init(id: "dawn-4", name: "Ember", category: .dawn,
              points: [("#3B1F4A", 0.0, 0.0), ("#FF8C42", 0.7, 0.4), ("#FF3C38", 0.2, 0.85), ("#FFD166", 1.0, 1.0)], warp: 0.7, seed: 4.4),
        // Ocean: blues and teals
        .init(id: "ocean-1", name: "Lagoon", category: .ocean,
              points: [("#5EE7DF", 0.1, 0.2), ("#2F80ED", 0.9, 0.15), ("#B4F8C8", 0.15, 0.9), ("#1D4E89", 0.85, 0.85)], warp: 0.5, seed: 5.2),
        .init(id: "ocean-2", name: "Deep Water", category: .ocean,
              points: [("#0B132B", 0.0, 0.0), ("#1C2541", 1.0, 0.2), ("#3A506B", 0.2, 1.0), ("#5BC0BE", 0.9, 0.9)], warp: 0.45, seed: 6.8),
        .init(id: "ocean-3", name: "Sea Glass", category: .ocean,
              points: [("#D3F8E2", 0.1, 0.1), ("#A9DEF9", 0.9, 0.3), ("#E4C1F9", 0.3, 0.95), ("#7FD8BE", 0.95, 0.9)], warp: 0.4, seed: 7.5),
        .init(id: "ocean-4", name: "Tide", category: .ocean,
              points: [("#00B4D8", 0.0, 0.3), ("#0077B6", 0.6, 0.0), ("#90E0EF", 0.4, 1.0), ("#03045E", 1.0, 0.8)], warp: 0.65, seed: 8.9),
        // Forest: greens and earth
        .init(id: "forest-1", name: "Moss", category: .forest,
              points: [("#A7C957", 0.1, 0.1), ("#386641", 0.9, 0.2), ("#F2E8CF", 0.2, 0.9), ("#6A994E", 0.85, 0.85)], warp: 0.5, seed: 9.1),
        .init(id: "forest-2", name: "Fern", category: .forest,
              points: [("#D8F3DC", 0.0, 0.0), ("#52B788", 1.0, 0.1), ("#95D5B2", 0.1, 1.0), ("#1B4332", 0.9, 1.0)], warp: 0.45, seed: 10.6),
        .init(id: "forest-3", name: "Clearing", category: .forest,
              points: [("#FEFAE0", 0.15, 0.1), ("#DDA15E", 0.9, 0.25), ("#606C38", 0.2, 0.85), ("#BC6C25", 0.8, 0.9)], warp: 0.55, seed: 11.3),
        .init(id: "forest-4", name: "Canopy", category: .forest,
              points: [("#081C15", 0.0, 0.0), ("#2D6A4F", 0.8, 0.3), ("#40916C", 0.2, 0.7), ("#B7E4C7", 1.0, 1.0)], warp: 0.7, seed: 12.2),
        // Night: dark and violet
        .init(id: "night-1", name: "Dusk", category: .night,
              points: [("#22223B", 0.0, 0.0), ("#4A4E69", 1.0, 0.2), ("#9A8C98", 0.2, 1.0), ("#C9ADA7", 0.9, 0.9)], warp: 0.4, seed: 13.7),
        .init(id: "night-2", name: "Aurora", category: .night,
              points: [("#0D1B2A", 0.0, 0.1), ("#7B2CBF", 0.9, 0.0), ("#3CF0C5", 0.3, 0.6), ("#10002B", 1.0, 1.0)], warp: 0.75, seed: 14.4),
        .init(id: "night-3", name: "Ink", category: .night,
              points: [("#101014", 0.1, 0.1), ("#2B2D42", 0.9, 0.2), ("#1A1A2E", 0.2, 0.9), ("#3E3F5B", 0.85, 0.85)], warp: 0.35, seed: 15.9),
        .init(id: "night-4", name: "Neon", category: .night,
              points: [("#14001F", 0.0, 0.0), ("#FF2E88", 0.8, 0.2), ("#2E2BFF", 0.2, 0.8), ("#00F0FF", 1.0, 1.0)], warp: 0.6, seed: 16.5),
    ]

    public static func wallpaper(id: String) -> Wallpaper {
        all.first { $0.id == id } ?? all[0]
    }
}

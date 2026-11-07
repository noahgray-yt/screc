import Foundation

/// The visual style of a project (ARCHITECTURE §5.1 `look`). Every field has a default, and every key is
/// optional when decoding, so older or hand-written `project.json` files always load.
public struct Look: Codable, Equatable, Sendable {
    public enum Aspect: String, Codable, Sendable, CaseIterable {
        case auto, wide = "16:9", square = "1:1", classic = "4:3", vertical = "9:16", tall = "3:4", portrait = "4:5"

        /// Width / height, or nil for `auto`.
        public var ratio: Double? {
            switch self {
            case .auto: nil
            case .wide: 16.0 / 9
            case .square: 1
            case .classic: 4.0 / 3
            case .vertical: 9.0 / 16
            case .tall: 3.0 / 4
            case .portrait: 4.0 / 5
            }
        }
    }

    public var aspect: Aspect = .auto
    /// Normalised recording rect `[x, y, w, h]` (top-left origin).
    public var crop: [Double] = [0, 0, 1, 1]
    public var background = Background()
    public var frame = FrameStyle()
    public var cursor = CursorLook()
    public var animation = AnimationLook()
    /// Keyboard-shortcut overlay (Phase 5).
    public var keys = KeyOverlayLook()
    /// Captions (Phase 5).
    public var captions = CaptionLook()
    public var webcam = WebcamLook()
    /// Reframing (Phase 5): zoom in until the screen fills the canvas and follow the cursor. Meant for an aspect
    /// ratio that differs from the recording's (a wide screen in a 9:16 reel).
    public var fillFrame = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Look()
        aspect = try c.decodeIfPresent(Aspect.self, forKey: .aspect) ?? d.aspect
        crop = try c.decodeIfPresent([Double].self, forKey: .crop) ?? d.crop
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? d.background
        frame = try c.decodeIfPresent(FrameStyle.self, forKey: .frame) ?? d.frame
        cursor = try c.decodeIfPresent(CursorLook.self, forKey: .cursor) ?? d.cursor
        animation = try c.decodeIfPresent(AnimationLook.self, forKey: .animation) ?? d.animation
        keys = try c.decodeIfPresent(KeyOverlayLook.self, forKey: .keys) ?? d.keys
        captions = try c.decodeIfPresent(CaptionLook.self, forKey: .captions) ?? d.captions
        webcam = try c.decodeIfPresent(WebcamLook.self, forKey: .webcam) ?? d.webcam
        fillFrame = try c.decodeIfPresent(Bool.self, forKey: .fillFrame) ?? d.fillFrame
    }
}

public struct Background: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case wallpaper, gradient, color, image }

    public var kind: Kind = .wallpaper
    public var wallpaper: String = Wallpapers.defaultID
    public var gradient = Gradient()
    public var color: String = "#1E1E24"
    /// File name inside the bundle (`background.<ext>`).
    public var image: String?
    /// 0…100.
    public var blur: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Background()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? d.kind
        wallpaper = try c.decodeIfPresent(String.self, forKey: .wallpaper) ?? d.wallpaper
        gradient = try c.decodeIfPresent(Gradient.self, forKey: .gradient) ?? d.gradient
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        image = try c.decodeIfPresent(String.self, forKey: .image)
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? d.blur
    }
}

public struct Gradient: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case linear, radial }
    public struct Stop: Codable, Equatable, Sendable {
        public var color: String
        public var location: Double
        public init(color: String, location: Double) {
            self.color = color
            self.location = location
        }
        // Stored as `["#FF8A5B", 0]` (ARCHITECTURE §5.1).
        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            color = try c.decode(String.self)
            location = try c.decode(Double.self)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(color)
            try c.encode(location)
        }
    }

    public var type: Kind = .linear
    /// Degrees; 0 = left → right, 90 = top → bottom.
    public var angle: Double = 135
    public var stops: [Stop] = [Stop(color: "#FF8A5B", location: 0), Stop(color: "#7B5CFF", location: 1)]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Gradient()
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? d.type
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? d.angle
        stops = try c.decodeIfPresent([Stop].self, forKey: .stops) ?? d.stops
    }
}

public struct FrameStyle: Codable, Equatable, Sendable {
    public struct Shadow: Codable, Equatable, Sendable {
        public enum Style: String, Codable, Sendable { case classic, directional }
        /// 0…1.
        public var amount: Double = 0.5
        public var style: Style = .classic
        /// Directional only: degrees, 90 = light from above (shadow falls downwards).
        public var angle: Double = 90
        /// Directional only: 0…1.
        public var distance: Double = 0.3
        /// Directional only: 0…1.
        public var softness: Double = 0.6

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Shadow()
            amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? d.amount
            style = try c.decodeIfPresent(Style.self, forKey: .style) ?? d.style
            angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? d.angle
            distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? d.distance
            softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? d.softness
        }
    }

    /// Fraction of the canvas' short side, 0…0.4.
    public var padding: Double = 0.10
    /// Pixels at a 1080p reference, 0…48.
    public var cornerRadius: Double = 12
    public var inset: Bool = false
    public var shadow = Shadow()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameStyle()
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        inset = try c.decodeIfPresent(Bool.self, forKey: .inset) ?? d.inset
        shadow = try c.decodeIfPresent(Shadow.self, forKey: .shadow) ?? d.shadow
    }
}

public struct CursorLook: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case standardArrow, outlineArrow, dot, filledColorArrow, boldWhiteArrow, thinArrow
    }
    public enum ClickEffect: String, Codable, Sendable, CaseIterable { case none, circle, ripple }
    public enum ClickSound: String, Codable, Sendable, CaseIterable { case none, soft, crisp }
    public struct Rotation: Codable, Equatable, Sendable {
        public var enabled = false
        public var maxDegrees: Double = 8
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            maxDegrees = try c.decodeIfPresent(Double.self, forKey: .maxDegrees) ?? 8
        }
    }

    public var style: Style = .standardArrow
    /// Fill colour of `filledColorArrow` and `dot`.
    public var color: String = "#FF5A36"
    /// 0.5…4.
    public var size: Double = 1.5
    public var alwaysPointer = false
    public var hideWhenIdle = false
    public var loop = false
    public var hidden = false
    public var clickEffect: ClickEffect = .ripple
    public var clickSound: ClickSound = .none
    public var rotation = Rotation()
    /// Spring ω (1/s) that replaces the Animation-panel cursor style ("Advanced › smoothing"). nil = use the style.
    public var smoothingOverride: Double?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CursorLook()
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? d.style
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        alwaysPointer = try c.decodeIfPresent(Bool.self, forKey: .alwaysPointer) ?? d.alwaysPointer
        hideWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? d.hideWhenIdle
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? d.loop
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? d.hidden
        clickEffect = try c.decodeIfPresent(ClickEffect.self, forKey: .clickEffect) ?? d.clickEffect
        clickSound = try c.decodeIfPresent(ClickSound.self, forKey: .clickSound) ?? d.clickSound
        rotation = try c.decodeIfPresent(Rotation.self, forKey: .rotation) ?? d.rotation
        smoothingOverride = try c.decodeIfPresent(Double.self, forKey: .smoothingOverride)
    }
}

public struct AnimationLook: Codable, Equatable, Sendable {
    public enum Screen: String, Codable, Sendable, CaseIterable {
        case focused, smooth
        /// Spring ω for zoom transitions (SPEC §3.3).
        public var zoomOmega: Double { self == .focused ? 12 : 6.7 }
        /// Spring ω for the follow pan.
        public var panOmega: Double { self == .focused ? 12 : 6.5 }
    }
    public enum Cursor: String, Codable, Sendable, CaseIterable {
        case smooth, medium, rapid, none
        /// Spring ω; lag at constant speed = 2/ω (SPEC §3.6: 250 / 150 / 90 ms). nil = raw path.
        public var omega: Double? {
            switch self {
            case .smooth: 8
            case .medium: 13
            case .rapid: 22
            case .none: nil
            }
        }
    }

    public var screen: Screen = .focused
    public var cursor: Cursor = .medium
    /// 0…100; 100 = 180° shutter (half a frame interval).
    public var motionBlur: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screen = try c.decodeIfPresent(Screen.self, forKey: .screen) ?? .focused
        cursor = try c.decodeIfPresent(Cursor.self, forKey: .cursor) ?? .medium
        motionBlur = try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0
    }
}

/// `#RRGGBB` → linear-light RGB in 0…1 (sRGB transfer removed), for the compositor.
public enum ColorParsing {
    public static func srgb(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0, 0, 0) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func linear(_ hex: String) -> (r: Double, g: Double, b: Double) {
        let c = srgb(hex)
        return (toLinear(c.r), toLinear(c.g), toLinear(c.b))
    }

    public static func toLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
}

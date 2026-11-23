import SwiftUI

/// A lighthouse keeper's log: every beam, every ship, every storm.
@Observable
final class Lighthouse {
    enum Weather: String, CaseIterable {
        case calm, breezy, meltemi, storm

        var visibility: Measurement<UnitLength> {
            switch self {
            case .calm: .init(value: 24, unit: .nauticalMiles)
            case .breezy: .init(value: 18, unit: .nauticalMiles)
            case .meltemi: .init(value: 9, unit: .nauticalMiles)
            case .storm: .init(value: 2.5, unit: .nauticalMiles)
            }
        }
    }

    let name: String
    private(set) var sightings: [Sighting] = []
    var weather: Weather = .calm

    init(name: String) {
        self.name = name
    }

    /// Records a ship, ignoring duplicates seen within ten minutes.
    func record(_ ship: String, bearing: Double, at date: Date = .now) {
        let recent = sightings.last { $0.ship == ship }
        guard recent.map({ date.timeIntervalSince($0.date) > 600 }) ?? true else { return }
        sightings.append(Sighting(ship: ship, bearing: bearing.truncatingRemainder(dividingBy: 360), date: date))
    }
}

struct Sighting: Identifiable, Hashable {
    let id = UUID()
    let ship: String
    let bearing: Double
    let date: Date
}

struct LogView: View {
    @State private var lighthouse = Lighthouse(name: "Akrotiri")

    var body: some View {
        List(lighthouse.sightings.reversed()) { sighting in
            LabeledContent(sighting.ship) {
                Text(sighting.date, style: .time)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(lighthouse.name)
        .toolbar {
            Picker("Weather", selection: $lighthouse.weather) {
                ForEach(Lighthouse.Weather.allCases, id: \.self) { Text($0.rawValue.capitalized) }
            }
        }
    }
}

import Foundation
import SwiftUI

// MARK: - Model

/// A berth in the harbour: where a vessel ties up, and for how long.
struct Berth: Identifiable, Hashable {
    let id: Int
    var name: String
    var depth: Measurement<UnitLength>
    var vessel: Vessel?

    var isFree: Bool { vessel == nil }

    struct Vessel: Hashable {
        var name: String
        var flag: String
        var length: Double
        var arrival: Date
        var departure: Date?

        /// How long the vessel has been alongside.
        func stay(until now: Date = .now) -> TimeInterval {
            (departure ?? now).timeIntervalSince(arrival)
        }
    }
}

// MARK: - Harbour master

@Observable
final class HarbourMaster {
    enum Weather: String, CaseIterable {
        case calm, breezy, meltemi, gale

        /// Ships longer than this wait outside the breakwater.
        var maximumLength: Double {
            switch self {
            case .calm: return 220
            case .breezy: return 180
            case .meltemi: return 120
            case .gale: return 0
            }
        }
    }

    private(set) var berths: [Berth]
    var weather: Weather = .calm
    private var log: [String] = []

    init(berths: Int) {
        self.berths = (1...berths).map { number in
            Berth(id: number, name: "Berth \(number)", depth: .init(value: 9 + Double(number % 4), unit: .meters))
        }
    }

    /// Finds a free berth deep and long enough, preferring the closest to the harbour mouth.
    func assign(_ vessel: Berth.Vessel, draft: Double) throws -> Berth {
        guard vessel.length <= weather.maximumLength else {
            throw HarbourError.tooLong(vessel.name, limit: weather.maximumLength)
        }
        let candidates = berths.indices.filter { index in
            let berth = berths[index]
            return berth.isFree && berth.depth.converted(to: .meters).value > draft + 1.5
        }
        guard let index = candidates.first else {
            throw HarbourError.full
        }
        berths[index].vessel = vessel
        record("\(vessel.name) assigned to \(berths[index].name)")
        return berths[index]
    }

    func depart(from id: Int, at date: Date = .now) {
        guard let index = berths.firstIndex(where: { $0.id == id }), var vessel = berths[index].vessel else {
            return
        }
        vessel.departure = date
        let hours = vessel.stay(until: date) / 3600
        record("\(vessel.name) departed after \(hours.formatted(.number.precision(.fractionLength(1)))) h")
        berths[index].vessel = nil
    }

    private func record(_ line: String) {
        log.append("[\(Date.now.formatted(date: .omitted, time: .shortened))] \(line)")
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }
}

enum HarbourError: LocalizedError {
    case full
    case tooLong(String, limit: Double)

    var errorDescription: String? {
        switch self {
        case .full: return "Every berth is taken."
        case .tooLong(let name, let limit): return "\(name) is longer than \(Int(limit)) m; wait for calmer weather."
        }
    }
}

// MARK: - Views

struct BerthList: View {
    @State private var master = HarbourMaster(berths: 12)
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered) { berth in
                HStack {
                    Text(berth.name)
                    Spacer()
                    if let vessel = berth.vessel {
                        Text(vessel.name).foregroundStyle(.secondary)
                    } else {
                        Text("Free").foregroundStyle(.green)
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Harbour")
        }
    }

    private var filtered: [Berth] {
        guard !query.isEmpty else { return master.berths }
        return master.berths.filter { berth in
            berth.name.localizedCaseInsensitiveContains(query)
                || (berth.vessel?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

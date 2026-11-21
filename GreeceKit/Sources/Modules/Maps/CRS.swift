import Foundation

/// A coordinate reference system, read from a shapefile's .prj, a GeoPackage's spatial reference
/// table, a legacy GeoJSON `crs` member or an EPSG code, and able to bring coordinates to WGS 84.
struct CRS {
    enum Kind {
        case geographic
        case projected(Projection)
        /// Known to be planar but not something Greece can invert.
        case unsupported(method: String)
    }

    var name: String
    var kind: Kind
    var ellipsoid: Ellipsoid = .wgs84
    /// Degrees per source angle unit (geographic) or metres per source length unit (projected).
    var unit: Double = 1
    /// Prime meridian in degrees east of Greenwich.
    var primeMeridian: Double = 0
    /// Position-vector Helmert parameters to WGS 84, when the datum isn't WGS 84-compatible.
    var toWGS84: Helmert?
    var epsg: Int?

    var isWGS84Compatible: Bool {
        if case .geographic = kind, toWGS84 == nil, primeMeridian == 0, abs(unit - 1) < 1e-12 { return true }
        return false
    }

    var canTransform: Bool {
        if case .unsupported = kind { return false }
        return true
    }

    static let wgs84 = CRS(name: "WGS 84", kind: .geographic, epsg: 4326)

    /// Source coordinates to WGS 84 longitude and latitude in degrees, or nil if out of range.
    func transform(_ p: GeoPoint) -> GeoPoint? {
        guard p.isFinite else { return nil }
        var lon: Double, lat: Double
        switch kind {
        case .geographic:
            lon = p.x * unit + primeMeridian
            lat = p.y * unit
        case .projected(let projection):
            guard let (l, f) = projection.inverse(p.x * unit, p.y * unit, ellipsoid) else { return nil }
            lon = l * 180 / .pi + primeMeridian
            lat = f * 180 / .pi
        case .unsupported:
            return nil
        }
        if let helmert = toWGS84 {
            (lon, lat) = helmert.apply(lon: lon, lat: lat, from: ellipsoid)
        }
        guard lon.isFinite, lat.isFinite, abs(lat) <= 90.5 else { return nil }
        return GeoPoint(lon, lat)
    }
}

struct Ellipsoid: Equatable {
    let a: Double
    let f: Double
    var e2: Double { f * (2 - f) }
    var e: Double { sqrt(e2) }

    init(a: Double, f: Double) { self.a = a; self.f = f }
    init(a: Double, inverseFlattening: Double) { self.a = a; f = inverseFlattening == 0 ? 0 : 1 / inverseFlattening }

    static let wgs84 = Ellipsoid(a: 6378137, inverseFlattening: 298.257223563)
    static let grs80 = Ellipsoid(a: 6378137, inverseFlattening: 298.257222101)
    static let airy1830 = Ellipsoid(a: 6377563.396, inverseFlattening: 299.3249646)
    static let bessel1841 = Ellipsoid(a: 6377397.155, inverseFlattening: 299.1528128)
    static let international1924 = Ellipsoid(a: 6378388, inverseFlattening: 297)
    static let clarke1866 = Ellipsoid(a: 6378206.4, inverseFlattening: 294.9786982)
    static let clarke1880 = Ellipsoid(a: 6378249.2, inverseFlattening: 293.4660213)
    static let sphere = Ellipsoid(a: 6378137, f: 0)
}

/// A seven-parameter (position vector) transformation to WGS 84.
struct Helmert {
    var tx, ty, tz: Double
    /// Rotations in arc-seconds, scale in parts per million.
    var rx = 0.0, ry = 0.0, rz = 0.0, ppm = 0.0

    init(_ values: [Double]) {
        tx = values.count > 0 ? values[0] : 0
        ty = values.count > 1 ? values[1] : 0
        tz = values.count > 2 ? values[2] : 0
        rx = values.count > 3 ? values[3] : 0
        ry = values.count > 4 ? values[4] : 0
        rz = values.count > 5 ? values[5] : 0
        ppm = values.count > 6 ? values[6] : 0
    }

    var isIdentity: Bool { tx == 0 && ty == 0 && tz == 0 && rx == 0 && ry == 0 && rz == 0 && ppm == 0 }

    func apply(lon: Double, lat: Double, from source: Ellipsoid) -> (Double, Double) {
        let lambda = lon * .pi / 180, phi = lat * .pi / 180
        let nu = source.a / sqrt(1 - source.e2 * sin(phi) * sin(phi))
        let x = nu * cos(phi) * cos(lambda)
        let y = nu * cos(phi) * sin(lambda)
        let z = nu * (1 - source.e2) * sin(phi)
        let s = 1 + ppm * 1e-6
        let arc = Double.pi / (180 * 3600)
        let (rx, ry, rz) = (self.rx * arc, self.ry * arc, self.rz * arc)
        let x2 = tx + s * (x - rz * y + ry * z)
        let y2 = ty + s * (rz * x + y - rx * z)
        let z2 = tz + s * (-ry * x + rx * y + z)
        // Back to geodetic on WGS 84 (Bowring, then two refinements).
        let target = Ellipsoid.wgs84
        let p = sqrt(x2 * x2 + y2 * y2)
        var phi2 = atan2(z2, p * (1 - target.e2))
        for _ in 0..<4 {
            let n = target.a / sqrt(1 - target.e2 * sin(phi2) * sin(phi2))
            phi2 = atan2(z2 + target.e2 * n * sin(phi2), p)
        }
        return (atan2(y2, x2) * 180 / .pi, phi2 * 180 / .pi)
    }
}

// MARK: - Projections

/// Inverse map projections (projected metres to geodetic radians), after EPSG Guidance Note 7-2.
struct Projection {
    enum Method: String {
        case transverseMercator = "Transverse Mercator"
        case mercator = "Mercator"
        case webMercator = "Pseudo-Mercator"
        case lambertConformalConic = "Lambert Conformal Conic"
        case albers = "Albers Equal Area"
        case lambertAzimuthal = "Lambert Azimuthal Equal Area"
        case polarStereographic = "Polar Stereographic"
        case obliqueStereographic = "Oblique Stereographic"
        case equirectangular = "Equirectangular"
        case obliqueMercator = "Oblique Mercator"
    }

    var method: Method
    var lat0 = 0.0, lon0 = 0.0
    var lat1: Double?, lat2: Double?
    var k0 = 1.0
    var falseEasting = 0.0, falseNorthing = 0.0
    var latTs: Double?
    var azimuth: Double?
    var rectifiedGridAngle: Double?

    private static func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }

    func inverse(_ x: Double, _ y: Double, _ ell: Ellipsoid) -> (lon: Double, lat: Double)? {
        let a = ell.a, e2 = ell.e2, e = ell.e
        let E = x - falseEasting, N = y - falseNorthing
        let phi0 = Projection.rad(lat0), lambda0 = Projection.rad(lon0)

        func m(_ phi: Double) -> Double { cos(phi) / sqrt(1 - e2 * sin(phi) * sin(phi)) }
        func t(_ phi: Double) -> Double {
            tan(.pi / 4 - phi / 2) / pow((1 - e * sin(phi)) / (1 + e * sin(phi)), e / 2)
        }
        func q(_ phi: Double) -> Double {
            let s = sin(phi)
            if e < 1e-12 { return 2 * s }
            return (1 - e2) * (s / (1 - e2 * s * s) - (1 / (2 * e)) * log((1 - e * s) / (1 + e * s)))
        }
        /// Latitude from conformal latitude χ.
        func fromConformal(_ chi: Double) -> Double {
            let e4 = e2 * e2, e6 = e4 * e2, e8 = e6 * e2
            return chi + (e2 / 2 + 5 * e4 / 24 + e6 / 12 + 13 * e8 / 360) * sin(2 * chi)
                + (7 * e4 / 48 + 29 * e6 / 240 + 811 * e8 / 11520) * sin(4 * chi)
                + (7 * e6 / 120 + 81 * e8 / 1120) * sin(6 * chi)
                + (4279 * e8 / 161280) * sin(8 * chi)
        }
        /// Latitude from t (Lambert conic, Mercator, polar stereographic), iterated.
        func fromT(_ tValue: Double) -> Double {
            var phi = .pi / 2 - 2 * atan(tValue)
            for _ in 0..<15 {
                let next = .pi / 2 - 2 * atan(tValue * pow((1 - e * sin(phi)) / (1 + e * sin(phi)), e / 2))
                if abs(next - phi) < 1e-12 { return next }
                phi = next
            }
            return phi
        }

        switch method {
        case .webMercator:
            return (E / a + lambda0, atan(sinh(N / a)))

        case .mercator:
            var k = k0
            if let latTs { let p = Projection.rad(latTs); k = cos(p) / sqrt(1 - e2 * sin(p) * sin(p)) }
            let tValue = exp(-N / (a * k))
            return (E / (a * k) + lambda0, fromConformal(.pi / 2 - 2 * atan(tValue)))

        case .equirectangular:
            let ts = Projection.rad(latTs ?? lat1 ?? 0)
            return (E / (a * cos(ts)) + lambda0, N / a + phi0)

        case .transverseMercator:
            let ep2 = e2 / (1 - e2)
            let e4 = e2 * e2, e6 = e4 * e2
            func arc(_ phi: Double) -> Double {
                a * ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
                     - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * sin(2 * phi)
                     + (15 * e4 / 256 + 45 * e6 / 1024) * sin(4 * phi)
                     - (35 * e6 / 3072) * sin(6 * phi))
            }
            let M = arc(phi0) + N / k0
            let mu = M / (a * (1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256))
            let e1 = (1 - sqrt(1 - e2)) / (1 + sqrt(1 - e2))
            let phi1 = mu + (3 * e1 / 2 - 27 * pow(e1, 3) / 32) * sin(2 * mu)
                + (21 * e1 * e1 / 16 - 55 * pow(e1, 4) / 32) * sin(4 * mu)
                + (151 * pow(e1, 3) / 96) * sin(6 * mu)
                + (1097 * pow(e1, 4) / 512) * sin(8 * mu)
            let s1 = sin(phi1), c1 = cos(phi1)
            guard abs(c1) > 1e-12 else { return (lambda0, phi1) }
            let C1 = ep2 * c1 * c1
            let T1 = tan(phi1) * tan(phi1)
            let N1 = a / sqrt(1 - e2 * s1 * s1)
            let R1 = a * (1 - e2) / pow(1 - e2 * s1 * s1, 1.5)
            let D = E / (N1 * k0)
            let phi = phi1 - (N1 * tan(phi1) / R1) * (D * D / 2
                - (5 + 3 * T1 + 10 * C1 - 4 * C1 * C1 - 9 * ep2) * pow(D, 4) / 24
                + (61 + 90 * T1 + 298 * C1 + 45 * T1 * T1 - 252 * ep2 - 3 * C1 * C1) * pow(D, 6) / 720)
            let lambda = lambda0 + (D - (1 + 2 * T1 + C1) * pow(D, 3) / 6
                + (5 - 2 * C1 + 28 * T1 - 3 * C1 * C1 + 8 * ep2 + 24 * T1 * T1) * pow(D, 5) / 120) / c1
            return (lambda, phi)

        case .lambertConformalConic:
            let p1 = Projection.rad(lat1 ?? lat0), p2 = Projection.rad(lat2 ?? lat1 ?? lat0)
            let n: Double
            if abs(p1 - p2) < 1e-10 { n = sin(p1) } else { n = (log(m(p1)) - log(m(p2))) / (log(t(p1)) - log(t(p2))) }
            guard abs(n) > 1e-12 else { return nil }
            let F = m(p1) / (n * pow(t(p1), n))
            let r0 = a * F * k0 * pow(t(phi0), n)
            let dy = r0 - N
            let r = (n > 0 ? 1.0 : -1.0) * sqrt(E * E + dy * dy)
            let theta = n > 0 ? atan2(E, dy) : atan2(-E, -dy)
            if r == 0 { return (lambda0, n > 0 ? .pi / 2 : -.pi / 2) }
            let tValue = pow(r / (a * k0 * F), 1 / n)
            return (theta / n + lambda0, fromT(tValue))

        case .albers:
            let p1 = Projection.rad(lat1 ?? lat0), p2 = Projection.rad(lat2 ?? lat1 ?? lat0)
            let m1 = m(p1), m2 = m(p2), q1 = q(p1), q2 = q(p2), q0 = q(phi0)
            let n = abs(p1 - p2) < 1e-10 ? sin(p1) : (m1 * m1 - m2 * m2) / (q2 - q1)
            guard abs(n) > 1e-12 else { return nil }
            let C = m1 * m1 + n * q1
            let rho0 = a * sqrt(max(C - n * q0, 0)) / n
            let dy = rho0 - N
            let rho = sqrt(E * E + dy * dy)
            let theta = n > 0 ? atan2(E, dy) : atan2(-E, -dy)
            let qValue = (C - rho * rho * n * n / (a * a)) / n
            var phi = asin(max(-1, min(1, qValue / 2)))
            if e > 1e-12 {
                for _ in 0..<15 {
                    let s = sin(phi)
                    let delta = pow(1 - e2 * s * s, 2) / (2 * cos(phi))
                        * (qValue / (1 - e2) - s / (1 - e2 * s * s) + (1 / (2 * e)) * log((1 - e * s) / (1 + e * s)))
                    phi += delta
                    if abs(delta) < 1e-12 { break }
                }
            }
            return (lambda0 + theta / n, phi)

        case .lambertAzimuthal:
            let qP = q(.pi / 2)
            let Rq = a * sqrt(qP / 2)
            func latitudeFromQ(_ qValue: Double) -> Double {
                // Authalic latitude to geodetic.
                let beta = asin(max(-1, min(1, qValue / qP)))
                let e4 = e2 * e2, e6 = e4 * e2
                return beta + (e2 / 3 + 31 * e4 / 180 + 517 * e6 / 5040) * sin(2 * beta)
                    + (23 * e4 / 360 + 251 * e6 / 3780) * sin(4 * beta)
                    + (761 * e6 / 45360) * sin(6 * beta)
            }
            if abs(abs(lat0) - 90) < 1e-9 {
                let rho = sqrt(E * E + N * N)
                let north = lat0 > 0
                let qValue = north ? qP - rho * rho / (a * a) : -(qP - rho * rho / (a * a))
                return (lambda0 + (north ? atan2(E, -N) : atan2(E, N)), latitudeFromQ(qValue))
            }
            let beta0 = asin(q(phi0) / qP)
            let D = a * (cos(phi0) / sqrt(1 - e2 * sin(phi0) * sin(phi0))) / (Rq * cos(beta0))
            let rho = sqrt(pow(E / D, 2) + pow(D * N, 2))
            if rho < 1e-9 { return (lambda0, phi0) }
            let C = 2 * asin(min(1, rho / (2 * Rq)))
            let betaPrime = asin(max(-1, min(1, cos(C) * sin(beta0) + D * N * sin(C) * cos(beta0) / rho)))
            let lambda = lambda0 + atan2(E * sin(C), D * rho * cos(beta0) * cos(C) - D * D * N * sin(beta0) * sin(C))
            let e4 = e2 * e2, e6 = e4 * e2
            let phi = betaPrime + (e2 / 3 + 31 * e4 / 180 + 517 * e6 / 5040) * sin(2 * betaPrime)
                + (23 * e4 / 360 + 251 * e6 / 3780) * sin(4 * betaPrime)
                + (761 * e6 / 45360) * sin(6 * betaPrime)
            return (lambda, phi)

        case .polarStereographic:
            let north = (latTs ?? lat0) >= 0
            var k = k0
            if let latTs, abs(abs(latTs) - 90) > 1e-9 {
                let pf = Projection.rad(abs(latTs))
                let tF = t(pf)
                let mF = m(pf)
                k = mF * sqrt(pow(1 + e, 1 + e) * pow(1 - e, 1 - e)) / (2 * tF)
            }
            let rho = sqrt(E * E + N * N)
            let tValue = rho * sqrt(pow(1 + e, 1 + e) * pow(1 - e, 1 - e)) / (2 * a * k)
            let chi = .pi / 2 - 2 * atan(tValue)
            let phi = fromConformal(chi)
            if north { return (lambda0 + atan2(E, -N), phi) }
            return (lambda0 + atan2(E, N), -phi)

        case .obliqueStereographic:
            let s0 = sin(phi0)
            let rho0 = a * (1 - e2) / pow(1 - e2 * s0 * s0, 1.5)
            let nu0 = a / sqrt(1 - e2 * s0 * s0)
            let R = sqrt(rho0 * nu0)
            let n = sqrt(1 + e2 * pow(cos(phi0), 4) / (1 - e2))
            let S1 = (1 + s0) / (1 - s0)
            let S2 = (1 - e * s0) / (1 + e * s0)
            let w1 = pow(S1 * pow(S2, e), n)
            let sinChi00 = (w1 - 1) / (w1 + 1)
            let c = (n + s0) * (1 - sinChi00) / ((n - s0) * (1 + sinChi00))
            let w2 = c * w1
            let chi0 = asin((w2 - 1) / (w2 + 1))
            let g = 2 * R * k0 * tan(.pi / 4 - chi0 / 2)
            let h = 4 * R * k0 * tan(chi0) + g
            let i = atan(E / (h + N))
            let j = atan(E / (g - N)) - i
            let chi = chi0 + 2 * atan((N - E * tan(j / 2)) / (2 * R * k0))
            let Lambda = j + 2 * i + lambda0
            let lambda = (Lambda - lambda0) / n + lambda0
            let psi = 0.5 * log((1 + sin(chi)) / (c * (1 - sin(chi)))) / n
            var phi = 2 * atan(exp(psi)) - .pi / 2
            for _ in 0..<15 {
                let psiI = log(tan(phi / 2 + .pi / 4) * pow((1 - e * sin(phi)) / (1 + e * sin(phi)), e / 2))
                let next = phi - (psiI - psi) * cos(phi) * (1 - e2 * sin(phi) * sin(phi)) / (1 - e2)
                if abs(next - phi) < 1e-12 { phi = next; break }
                phi = next
            }
            return (lambda, phi)

        case .obliqueMercator:
            // Hotine oblique mercator, variant B (centre of projection), EPSG 9815.
            let phiC = phi0, lambdaC = lambda0
            let alphaC = Projection.rad(azimuth ?? 90)
            let gammaC = rectifiedGridAngle.map(Projection.rad)
            let sC = sin(phiC)
            let B = sqrt(1 + e2 * pow(cos(phiC), 4) / (1 - e2))
            let A = a * B * k0 * sqrt(1 - e2) / (1 - e2 * sC * sC)
            let t0 = tan(.pi / 4 - phiC / 2) / pow((1 - e * sC) / (1 + e * sC), e / 2)
            var D = B * sqrt(1 - e2) / (cos(phiC) * sqrt(1 - e2 * sC * sC))
            if D < 1 { D = 1 }
            let sign: Double = phiC < 0 ? -1 : 1
            let F = D + sqrt(D * D - 1) * sign
            let H = F * pow(t0, B)
            let G = (F - 1 / F) / 2
            let gamma0 = asin(sin(alphaC) / D)
            let lambdaZero = lambdaC - asin(max(-1, min(1, G * tan(gamma0)))) / B
            let uc: Double
            if abs(abs(alphaC) - .pi / 2) < 1e-12 { uc = A * (lambdaC - lambdaZero) } else {
                uc = (A / B) * atan(sqrt(D * D - 1) / cos(alphaC)) * sign
            }
            let gc = gammaC ?? gamma0
            let v = E * cos(gc) - N * sin(gc)
            let u = N * cos(gc) + E * sin(gc) + abs(uc) * sign
            let Q = exp(-B * v / A)
            let S = (Q - 1 / Q) / 2
            let T = (Q + 1 / Q) / 2
            let V = sin(B * u / A)
            let U = (V * cos(gamma0) + S * sin(gamma0)) / T
            guard abs(U) < 1 else { return (lambdaZero, U > 0 ? .pi / 2 : -.pi / 2) }
            let tValue = pow(H / sqrt((1 + U) / (1 - U)), 1 / B)
            let phi = fromConformal(.pi / 2 - 2 * atan(tValue))
            let lambda = lambdaZero - atan2(S * cos(gamma0) - V * sin(gamma0), cos(B * u / A)) / B
            return (lambda, phi)
        }
    }
}

// MARK: - Reading CRS definitions

extension CRS {

    /// A CRS from WKT (OGC or ESRI WKT1, or WKT2), as found in .prj files and GeoPackages.
    static func parse(wkt: String) -> CRS? {
        guard let root = WKTNode.parse(wkt) else { return nil }
        return from(root)
    }

    private static func from(_ node: WKTNode) -> CRS? {
        let keyword = node.keyword
        switch keyword {
        case "COMPD_CS", "COMPOUNDCRS":
            return node.nodes.lazy.compactMap { from($0) }.first
        case "BOUNDCRS":
            guard var base = node.node("SOURCECRS")?.nodes.first.flatMap({ from($0) }) else { return nil }
            if let transformation = node.node("ABRIDGEDTRANSFORMATION") {
                let values = transformation.nodes.filter { $0.keyword == "PARAMETER" }.compactMap(\.firstNumber)
                if values.count >= 3 { base.toWGS84 = Helmert(values) }
            }
            return base
        case "GEOGCS", "GEOGCRS", "GEODCRS", "GEOGRAPHICCRS", "GEODETICCRS", "BASEGEOGCRS", "BASEGEODCRS":
            return geographic(node)
        case "PROJCS", "PROJCRS", "PROJECTEDCRS":
            return projected(node)
        default:
            return nil
        }
    }

    private static func geographic(_ node: WKTNode) -> CRS? {
        var crs = CRS(name: prettyName(node.firstString ?? "Geographic"), kind: .geographic)
        applyDatum(node, to: &crs)
        if let unit = node.nodes.last(where: { ["UNIT", "ANGLEUNIT"].contains($0.keyword) }),
           let radians = unit.firstNumber, radians > 0 {
            crs.unit = radians * 180 / .pi
        } else if let unit = node.nodes.first(where: { $0.keyword == "AXIS" })?.node("ANGLEUNIT"), let radians = unit.firstNumber, radians > 0 {
            crs.unit = radians * 180 / .pi
        }
        if abs(crs.unit - 1) < 1e-9 { crs.unit = 1 }
        crs.epsg = node.authorityCode
        return crs
    }

    private static func applyDatum(_ node: WKTNode, to crs: inout CRS) {
        let datum = node.node("DATUM") ?? node.node("GEODETICDATUM") ?? node.node("TRF")
        if let spheroid = datum?.node("SPHEROID") ?? datum?.node("ELLIPSOID") ?? node.node("SPHEROID") ?? node.node("ELLIPSOID") {
            let numbers = spheroid.numbers
            if numbers.count >= 2, numbers[0] > 6_000_000, numbers[0] < 7_000_000 {
                var a = numbers[0]
                // WKT2 may give the axis in another length unit; it is metres in every real file.
                if let unit = spheroid.node("LENGTHUNIT")?.firstNumber, unit > 0 { a *= unit }
                crs.ellipsoid = Ellipsoid(a: a, inverseFlattening: numbers[1])
            }
        }
        if let towgs = datum?.node("TOWGS84") {
            let helmert = Helmert(towgs.numbers)
            if !helmert.isIdentity { crs.toWGS84 = helmert }
        } else if let name = datum?.firstString, let shift = knownDatumShift(name) {
            crs.toWGS84 = shift
        }
        if let meridian = node.node("PRIMEM"), let value = meridian.firstNumber {
            var degrees = value
            if let unit = meridian.node("ANGLEUNIT")?.firstNumber, unit > 0 { degrees = value * unit * 180 / .pi }
            crs.primeMeridian = degrees
        }
    }

    private static func projected(_ node: WKTNode) -> CRS? {
        let base = node.nodes.first { ["GEOGCS", "GEOGCRS", "BASEGEOGCRS", "BASEGEODCRS", "GEODCRS"].contains($0.keyword) }
        var crs = CRS(name: prettyName(node.firstString ?? "Projected"), kind: .unsupported(method: "unknown"))
        if let base { applyDatum(base, to: &crs) }
        crs.epsg = node.authorityCode

        // Linear unit: WKT1 puts UNIT directly under PROJCS; WKT2 under the axes or as LENGTHUNIT.
        var unit = 1.0
        if let u = node.nodes.last(where: { ["UNIT", "LENGTHUNIT"].contains($0.keyword) })?.firstNumber, u > 0 {
            unit = u
        } else if let axis = node.nodes.first(where: { $0.keyword == "AXIS" }), let u = axis.node("LENGTHUNIT")?.firstNumber ?? axis.node("UNIT")?.firstNumber, u > 0 {
            unit = u
        }
        crs.unit = unit

        let conversion = node.node("CONVERSION")
        let methodName = node.node("PROJECTION")?.firstString ?? conversion?.node("METHOD")?.firstString ?? conversion?.node("PROJECTION")?.firstString ?? ""
        let parameterNodes = (conversion ?? node).nodes.filter { $0.keyword == "PARAMETER" }
        var parameters: [String: Double] = [:]
        for parameter in parameterNodes {
            guard let name = parameter.firstString, var value = parameter.firstNumber else { continue }
            let key = normalized(name)
            if conversion != nil {
                // WKT2: every parameter carries its own unit.
                if let angle = parameter.node("ANGLEUNIT")?.firstNumber, angle > 0 { value = value * angle * 180 / .pi }
                if let length = parameter.node("LENGTHUNIT")?.firstNumber, length > 0 { value *= length }
            } else if ["falseeasting", "falsenorthing", "eastingatfalseorigin", "northingatfalseorigin"].contains(key) {
                // WKT1: false origins are in the CRS's linear unit.
                value *= unit
            }
            parameters[key] = value
        }
        guard let projection = makeProjection(method: methodName, parameters, name: crs.name) else {
            crs.kind = .unsupported(method: methodName.replacingOccurrences(of: "_", with: " "))
            if let code = crs.epsg, var known = epsg(code) {
                known.name = crs.name
                return known
            }
            return crs
        }
        crs.kind = .projected(projection)
        return crs
    }

    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func makeProjection(method: String, _ p: [String: Double], name: String) -> Projection? {
        func value(_ keys: String...) -> Double? { keys.lazy.compactMap { p[$0] }.first }
        let lat0 = value("latitudeoforigin", "latitudeofnaturalorigin", "latitudeofcenter", "latitudeoffalseorigin",
                         "latitudeofprojectioncentre", "latitudeofprojectioncenter", "centrallatitude") ?? 0
        let lon0 = value("centralmeridian", "longitudeofnaturalorigin", "longitudeofcenter", "longitudeoffalseorigin",
                         "longitudeoforigin", "longitudeofprojectioncentre", "longitudeofprojectioncenter") ?? 0
        let k0 = value("scalefactor", "scalefactoratnaturalorigin", "scalefactoroninitialline", "scalefactoratprojectioncentre") ?? 1
        let fe = value("falseeasting", "eastingatfalseorigin", "eastingatprojectioncentre") ?? 0
        let fn = value("falsenorthing", "northingatfalseorigin", "northingatprojectioncentre") ?? 0
        let sp1 = value("standardparallel1", "latitudeof1ststandardparallel", "latitudeoffirststandardparallel")
        let sp2 = value("standardparallel2", "latitudeof2ndstandardparallel", "latitudeofsecondstandardparallel")
        let latTs = value("latitudeofstandardparallel", "standardparallel")

        var projection = Projection(method: .transverseMercator, lat0: lat0, lon0: lon0, k0: k0, falseEasting: fe, falseNorthing: fn)
        switch normalized(method) {
        case "transversemercator", "gausskruger", "transversemercatorsouthorientated":
            projection.method = .transverseMercator
        case "mercator", "mercator1sp", "mercatorvarianta", "mercator2sp", "mercatorvariantb", "mercatorvariantc":
            projection.method = .mercator
            projection.latTs = sp1 ?? latTs
            if projection.latTs == 0 { projection.latTs = nil }
        case "mercatorauxiliarysphere", "popularvisualisationpseudomercator", "pseudomercator", "googlemaps", "webmercator":
            projection.method = .webMercator
        case "lambertconformalconic", "lambertconformalconic2sp", "lambertconformalconic1sp", "lambertconicconformal2sp",
             "lambertconicconformal1sp", "lambertconformalconic2spbelgium", "lambertconicconformal2spbelgium":
            projection.method = .lambertConformalConic
            projection.lat1 = sp1 ?? lat0
            projection.lat2 = sp2 ?? sp1 ?? lat0
        case "albers", "albersconicequalarea", "albersequalarea":
            projection.method = .albers
            projection.lat1 = sp1 ?? lat0
            projection.lat2 = sp2 ?? sp1 ?? lat0
        case "lambertazimuthalequalarea":
            projection.method = .lambertAzimuthal
        case "polarstereographic", "polarstereographicvarianta", "polarstereographicvariantb", "stereographicnorthpole", "stereographicsouthpole":
            projection.method = .polarStereographic
            if let ts = sp1 ?? latTs, abs(abs(ts) - 90) > 1e-9 {
                projection.latTs = ts
            } else {
                projection.latTs = normalized(method) == "stereographicsouthpole" ? -90 : (lat0 < 0 ? -90 : 90)
            }
            if normalized(method) == "stereographicsouthpole", let ts = projection.latTs, ts > 0 { projection.latTs = -ts }
        case "obliquestereographic", "doublestereographic", "stereographic":
            projection.method = .obliqueStereographic
        case "equirectangular", "equidistantcylindrical", "platecarree":
            projection.method = .equirectangular
            projection.latTs = sp1 ?? latTs ?? 0
        case "hotineobliquemercatorazimuthcenter", "hotineobliquemercatorvariantb", "obliquemercator", "hotineobliquemercator",
             "swissobliquemercator", "swissobliquecylindrical", "hotineobliquemercatorvarianta":
            projection.method = .obliqueMercator
            projection.azimuth = value("azimuth", "azimuthofinitialline", "azimuthatprojectioncentre") ?? 90
            projection.rectifiedGridAngle = value("rectifiedgridangle", "anglefromrectifiedtoskewgrid")
        default:
            return nil
        }
        return projection
    }

    /// ESRI and OGC names, tidied for display: "WGS_1984_UTM_Zone_33N" → "WGS 84 / UTM zone 33N".
    static func prettyName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("GCS_") { name.removeFirst(4) }
        name = name.replacingOccurrences(of: "_", with: " ")
        for (from, to) in [("WGS 1984", "WGS 84"), ("NAD 1983", "NAD83"), ("NAD 1927", "NAD27"), ("ETRS 1989", "ETRS89"),
                           ("GDA 1994", "GDA94"), ("GDA 2020", "GDA2020"), ("British National Grid", "British National Grid")] {
            if name.hasPrefix(from) && !name.contains("/") {
                let rest = name.dropFirst(from.count).trimmingCharacters(in: .whitespaces)
                name = rest.isEmpty ? to : "\(to) / \(rest)"
            }
        }
        name = name.replacingOccurrences(of: " Zone ", with: " zone ")
        return String(name.prefix(80))
    }

    /// Datums whose ESRI .prj files carry no TOWGS84: published transformations, accurate to a few metres.
    static func knownDatumShift(_ datum: String) -> Helmert? {
        switch normalized(datum) {
        case "osgb1936", "dosgb1936": return Helmert([446.448, -125.157, 542.06, 0.15, 0.247, 0.842, -20.489])
        case "europeandatum1950", "deuropeandatum1950": return Helmert([-87, -98, -121])
        case "northamericandatum1927", "dnorthamerican1927": return Helmert([-8, 160, 176])
        case "deutscheshauptdreiecksnetz", "ddeutscheshauptdreiecksnetz": return Helmert([598.1, 73.7, 418.2, 0.202, 0.045, -2.455, 6.7])
        case "amersfoort", "damersfoort": return Helmert([565.2369, 50.0087, 465.658, -0.406857, 0.350733, -1.87035, 4.0812])
        case "ch1903", "dch1903", "ch1903plus", "dch1903plus", "ch1903+": return Helmert([674.374, 15.056, 405.346])
        case "tokyo", "dtokyo": return Helmert([-146.414, 507.337, 680.507])
        case "nouvelletriangulationfrancaise", "dntf": return Helmert([-168, -60, 320])
        default: return nil
        }
    }

    // MARK: EPSG codes

    /// "EPSG:3857", "urn:ogc:def:crs:EPSG::27700", "urn:ogc:def:crs:OGC:1.3:CRS84"…
    static func named(_ raw: String) -> CRS? {
        let text = raw.uppercased()
        if text.hasSuffix("CRS84") || text.hasSuffix("CRS:84") { return .wgs84 }
        let digits = text.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let code = Int(String(digits.reversed())) else { return nil }
        return epsg(code)
    }

    /// Common EPSG codes, for files that name a CRS without defining it.
    static func epsg(_ code: Int) -> CRS? {
        func geo(_ name: String, _ ell: Ellipsoid = .wgs84, _ shift: Helmert? = nil) -> CRS {
            CRS(name: name, kind: .geographic, ellipsoid: ell, toWGS84: shift, epsg: code)
        }
        func proj(_ name: String, _ projection: Projection, _ ell: Ellipsoid = .wgs84, _ shift: Helmert? = nil, unit: Double = 1) -> CRS {
            CRS(name: name, kind: .projected(projection), ellipsoid: ell, unit: unit, toWGS84: shift, epsg: code)
        }
        func tm(_ lon0: Double, k0: Double = 0.9996, fe: Double = 500_000, fn: Double = 0, lat0: Double = 0) -> Projection {
            Projection(method: .transverseMercator, lat0: lat0, lon0: lon0, k0: k0, falseEasting: fe, falseNorthing: fn)
        }
        switch code {
        case 4326, 4979, 4030: return .wgs84
        case 4269: return geo("NAD83", .grs80)
        case 4258: return geo("ETRS89", .grs80)
        case 4283: return geo("GDA94", .grs80)
        case 7844: return geo("GDA2020", .grs80)
        case 4167: return geo("NZGD2000", .grs80)
        case 4617: return geo("NAD83(CSRS)", .grs80)
        case 4277: return geo("OSGB36", .airy1830, knownDatumShift("osgb1936"))
        case 4230: return geo("ED50", .international1924, knownDatumShift("europeandatum1950"))
        case 4267: return geo("NAD27", .clarke1866, knownDatumShift("northamericandatum1927"))
        case 4314: return geo("DHDN", .bessel1841, knownDatumShift("deutscheshauptdreiecksnetz"))
        case 4289: return geo("Amersfoort", .bessel1841, knownDatumShift("amersfoort"))
        case 4149, 4150: return geo("CH1903", .bessel1841, knownDatumShift("ch1903"))
        case 4301: return geo("Tokyo", .bessel1841, knownDatumShift("tokyo"))
        case 3857, 900913, 3785, 102100, 102113:
            return proj("WGS 84 / Pseudo-Mercator", Projection(method: .webMercator))
        case 3395: return proj("WGS 84 / World Mercator", Projection(method: .mercator))
        case 4087, 32662: return proj("WGS 84 / World Equidistant Cylindrical", Projection(method: .equirectangular, latTs: 0))
        case 32601...32660: return proj("WGS 84 / UTM zone \(code - 32600)N", tm(Double(code - 32600) * 6 - 183))
        case 32701...32760: return proj("WGS 84 / UTM zone \(code - 32700)S", tm(Double(code - 32700) * 6 - 183, fn: 10_000_000))
        case 25828...25838: return proj("ETRS89 / UTM zone \(code - 25800)N", tm(Double(code - 25800) * 6 - 183), .grs80)
        case 26901...26923: return proj("NAD83 / UTM zone \(code - 26900)N", tm(Double(code - 26900) * 6 - 183), .grs80)
        case 26701...26722: return proj("NAD27 / UTM zone \(code - 26700)N", tm(Double(code - 26700) * 6 - 183), .clarke1866, knownDatumShift("northamericandatum1927"))
        case 23028...23038: return proj("ED50 / UTM zone \(code - 23000)N", tm(Double(code - 23000) * 6 - 183), .international1924, knownDatumShift("europeandatum1950"))
        case 27700:
            return proj("OSGB36 / British National Grid", tm(-2, k0: 0.9996012717, fe: 400_000, fn: -100_000, lat0: 49), .airy1830, knownDatumShift("osgb1936"))
        case 2154:
            return proj("RGF93 / Lambert-93", Projection(method: .lambertConformalConic, lat0: 46.5, lon0: 3, lat1: 49, lat2: 44, falseEasting: 700_000, falseNorthing: 6_600_000), .grs80)
        case 3035:
            return proj("ETRS89 / LAEA Europe", Projection(method: .lambertAzimuthal, lat0: 52, lon0: 10, falseEasting: 4_321_000, falseNorthing: 3_210_000), .grs80)
        case 3034:
            return proj("ETRS89 / LCC Europe", Projection(method: .lambertConformalConic, lat0: 52, lon0: 10, lat1: 35, lat2: 65, falseEasting: 4_000_000, falseNorthing: 2_800_000), .grs80)
        case 28992:
            return proj("Amersfoort / RD New", Projection(method: .obliqueStereographic, lat0: 52.156160555555555, lon0: 5.387638888888889, k0: 0.9999079, falseEasting: 155_000, falseNorthing: 463_000), .bessel1841, knownDatumShift("amersfoort"))
        case 2056, 21781:
            let lv95 = code == 2056
            return proj(lv95 ? "CH1903+ / LV95" : "CH1903 / LV03",
                        Projection(method: .obliqueMercator, lat0: 46.952405555555555, lon0: 7.439583333333333, k0: 1,
                                   falseEasting: lv95 ? 2_600_000 : 600_000, falseNorthing: lv95 ? 1_200_000 : 200_000, azimuth: 90, rectifiedGridAngle: 90),
                        .bessel1841, knownDatumShift("ch1903"))
        case 3413:
            return proj("WGS 84 / NSIDC Sea Ice Polar Stereographic North", Projection(method: .polarStereographic, lon0: -45, latTs: 70))
        case 3031:
            return proj("WGS 84 / Antarctic Polar Stereographic", Projection(method: .polarStereographic, lon0: 0, latTs: -71))
        case 3995:
            return proj("WGS 84 / Arctic Polar Stereographic", Projection(method: .polarStereographic, lon0: 0, latTs: 71))
        case 5070:
            return proj("NAD83 / Conus Albers", Projection(method: .albers, lat0: 23, lon0: -96, lat1: 29.5, lat2: 45.5), .grs80)
        case 102003:
            return proj("USA Contiguous Albers Equal Area Conic", Projection(method: .albers, lat0: 37.5, lon0: -96, lat1: 29.5, lat2: 45.5), .grs80)
        case 3338:
            return proj("NAD83 / Alaska Albers", Projection(method: .albers, lat0: 50, lon0: -154, lat1: 55, lat2: 65), .grs80)
        case 3577:
            return proj("GDA94 / Australian Albers", Projection(method: .albers, lat0: 0, lon0: 132, lat1: -18, lat2: -36), .grs80)
        case 2193:
            return proj("NZGD2000 / New Zealand Transverse Mercator 2000", tm(173, k0: 0.9996, fe: 1_600_000, fn: 10_000_000), .grs80)
        case 31466...31469:
            let zone = Double(code - 31464)
            return proj("DHDN / 3-degree Gauss-Kruger zone \(code - 31464)", tm(zone * 3, k0: 1, fe: zone * 1_000_000 + 500_000), .bessel1841, knownDatumShift("deutscheshauptdreiecksnetz"))
        case 3067: return proj("ETRS89 / TM35FIN(E,N)", tm(27), .grs80)
        case 3006: return proj("SWEREF99 TM", tm(15), .grs80)
        case 2180: return proj("ETRF2000-PL / CS92", tm(19, k0: 0.9993, fn: -5_300_000), .grs80)
        default: return nil
        }
    }
}

// MARK: - WKT

/// A node of a well-known-text CRS definition: KEYWORD["name", 1.0, CHILD[...], WORD].
final class WKTNode {
    enum Item { case node(WKTNode), string(String), number(Double), word(String) }

    let keyword: String
    var items: [Item] = []

    init(keyword: String) { self.keyword = keyword }

    var nodes: [WKTNode] { items.compactMap { if case .node(let n) = $0 { return n }; return nil } }
    var numbers: [Double] { items.compactMap { if case .number(let n) = $0 { return n }; return nil } }
    var firstString: String? { items.lazy.compactMap { if case .string(let s) = $0 { return s }; return nil }.first }
    var firstNumber: Double? { numbers.first }
    func node(_ keyword: String) -> WKTNode? { nodes.first { $0.keyword == keyword } }

    var authorityCode: Int? {
        guard let authority = node("AUTHORITY") ?? node("ID"),
              authority.firstString?.uppercased() == "EPSG" else { return nil }
        for item in authority.items.dropFirst() {
            switch item {
            case .string(let s): if let code = Int(s) { return code }
            case .number(let n): return Int(n)
            default: break
            }
        }
        return nil
    }

    static func parse(_ text: String) -> WKTNode? {
        let scalars = Array(text.utf8.prefix(128 * 1024))
        var pos = 0
        func skip() { while pos < scalars.count, scalars[pos] == 0x20 || scalars[pos] == 0x0A || scalars[pos] == 0x0D || scalars[pos] == 0x09 { pos += 1 } }
        func word() -> String {
            let start = pos
            while pos < scalars.count, (scalars[pos] >= 0x41 && scalars[pos] <= 0x5A) || (scalars[pos] >= 0x61 && scalars[pos] <= 0x7A)
                    || (scalars[pos] >= 0x30 && scalars[pos] <= 0x39) || scalars[pos] == 0x5F { pos += 1 }
            return String(decoding: scalars[start..<pos], as: UTF8.self)
        }
        func node(depth: Int) -> WKTNode? {
            guard depth < 24 else { return nil }
            skip()
            let keyword = word().uppercased()
            guard !keyword.isEmpty else { return nil }
            skip()
            guard pos < scalars.count, scalars[pos] == 0x5B || scalars[pos] == 0x28 else { return nil }
            let close: UInt8 = scalars[pos] == 0x5B ? 0x5D : 0x29
            pos += 1
            let result = WKTNode(keyword: keyword)
            while true {
                skip()
                guard pos < scalars.count else { return result }
                let c = scalars[pos]
                if c == close || c == 0x5D || c == 0x29 { pos += 1; return result }
                if c == 0x2C { pos += 1; continue }
                if c == 0x22 {
                    pos += 1
                    var bytes: [UInt8] = []
                    while pos < scalars.count {
                        if scalars[pos] == 0x22 {
                            if pos + 1 < scalars.count, scalars[pos + 1] == 0x22 { bytes.append(0x22); pos += 2; continue }
                            pos += 1
                            break
                        }
                        bytes.append(scalars[pos])
                        pos += 1
                    }
                    result.items.append(.string(String(decoding: bytes, as: UTF8.self)))
                } else if c == 0x2D || c == 0x2B || c == 0x2E || (c >= 0x30 && c <= 0x39) {
                    let start = pos
                    pos += 1
                    while pos < scalars.count, (scalars[pos] >= 0x30 && scalars[pos] <= 0x39) || [0x2E, 0x65, 0x45, 0x2D, 0x2B].contains(scalars[pos]) { pos += 1 }
                    result.items.append(.number(Double(String(decoding: scalars[start..<pos], as: UTF8.self)) ?? .nan))
                } else {
                    let save = pos
                    let w = word()
                    if w.isEmpty { pos = save + 1; continue }
                    skip()
                    if pos < scalars.count, scalars[pos] == 0x5B || scalars[pos] == 0x28 {
                        pos = save
                        guard let child = node(depth: depth + 1) else { return result }
                        result.items.append(.node(child))
                    } else {
                        result.items.append(.word(w))
                    }
                }
                if result.items.count > 4096 { return result }
            }
        }
        return node(depth: 0)
    }
}

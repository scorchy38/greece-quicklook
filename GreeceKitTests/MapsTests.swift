import XCTest
@testable import GreeceKit

/// Maps and geodata: detection, every reader, reprojection, limits and hostile input.
final class MapsTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/maps")
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GreeceMaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    @discardableResult
    private func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func file(_ name: String, data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func load(_ url: URL, limits: GeoLimits = .preview) throws -> MapDocument {
        let info = FileInfo(url: url)
        guard let format = MapDetection.format(of: info) else { throw GeoError.invalid("not claimed: \(url.lastPathComponent)") }
        let document = try MapLoader.load(info, format: format, limits: limits)
        document.normalize()
        return document
    }

    private func geojson(_ text: String, limits: GeoLimits = .preview) throws -> GeoJSONResult {
        try GeoJSONReader.read(Data(text.utf8), limits: limits)
    }

    // MARK: - Detection

    func testFixturesAreClaimedWithTheRightFormat() throws {
        let expected: [String: MapFormat] = [
            "countries.geojson": .geojson, "cities.json": .geojson, "rivers.geojsonl": .geojsonLines,
            "world.topojson": .topojson, "us-states-albers.topojson": .topojson, "places.kml": .kml, "tour.kmz": .kmz,
            "hike.gpx": .gpx, "ride.gpx": .gpx, "rivers.shp": .shapefile, "parcels_utm33n.shp": .shapefile,
            "cities_shp.zip": .zippedShapefile, "places.gpkg": .geopackage, "raster.mbtiles": .mbtiles,
            "vector.mbtiles": .mbtiles, "relief.mbtiles": .mbtiles, "town.osm": .osm, "shapes.wkt": .wkt, "single.wkt": .wkt,
        ]
        for (name, format) in expected {
            let info = FileInfo(url: fixture(name))
            XCTAssertEqual(MapDetection.format(of: info), format, name)
            XCTAssertEqual(FileKind.detect(fixture(name)), .module("maps"), name)
        }
    }

    func testOrdinaryJSONStaysWithTheJSONViewer() throws {
        let cases = [
            "{\"name\": \"greece\", \"version\": \"1.0.0\", \"dependencies\": {}}",
            "[1, 2, 3]",
            // GeoJSON nested inside an API response is not a GeoJSON document.
            "{\"status\": \"ok\", \"result\": {\"type\": \"FeatureCollection\", \"features\": []}}",
            // A Feature without a geometry member.
            "{\"type\": \"Feature\", \"properties\": {}}",
            "{\"type\": \"Topology\"}",
            "{\"features\": [{\"kind\": \"Feature\"}]}",
        ]
        for (i, text) in cases.enumerated() {
            let url = try file("plain\(i).json", text)
            XCTAssertNil(MapDetection.format(of: FileInfo(url: url)), text)
            XCTAssertEqual(FileKind.detect(url), .json, text)
        }
    }

    func testGeoJSONInPlainJSONIsRecognised() throws {
        let cases = [
            "{\"type\":\"FeatureCollection\",\"features\":[]}",
            "\u{FEFF}  {\n \"type\" : \"Feature\", \"geometry\": null, \"properties\": {}}",
            // Members in any order: the first feature tells.
            "{\"features\": [{\"type\": \"Feature\", \"geometry\": {\"type\": \"Point\", \"coordinates\": [1, 2]}}], \"type\": \"FeatureCollection\"}",
        ]
        for (i, text) in cases.enumerated() {
            XCTAssertEqual(MapDetection.format(of: FileInfo(url: try file("geo\(i).json", text))), .geojson, text)
        }
        XCTAssertEqual(MapDetection.format(of: FileInfo(url: try file("topo.json", "{\"type\":\"Topology\",\"objects\":{},\"arcs\":[]}"))), .topojson)
        XCTAssertEqual(MapDetection.format(of: FileInfo(url: try file("lines.ndjson", "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[0,0]}}\n"))), .geojsonLines)
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("log.ndjson", "{\"level\":\"info\",\"msg\":\"hi\"}\n"))))
    }

    func testWrongContentUnderAMapExtensionIsNotClaimed() throws {
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("fake.shp", "not a shapefile at all, just text that is long enough to fill a header of one hundred bytes......."))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("fake.gpkg", "hello"))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("fake.mbtiles", "hello"))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("fake.kml", "<html><body>not kml</body></html>"))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("fake.gpx", "<xml/>"))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("fake.kmz", "PK? no"))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("notes.wkt", "These are notes about WKT, not geometry."))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("binary.geojson", data: Data([0, 1, 2, 0, 0, 255, 0])))))
    }

    func testOnlyZipsOfShapefilesAreClaimed() throws {
        // A real zip of shapefiles is claimed; an ordinary archive isn't, even with a .shp inside.
        XCTAssertEqual(MapDetection.format(of: FileInfo(url: fixture("cities_shp.zip"))), .zippedShapefile)
        let zip = try makeZip(["a.shp": Data(count: 120), "a.dbf": Data(count: 40), "readme.md": Data("x".utf8),
                               "src/main.swift": Data("x".utf8), "src/b.swift": Data("y".utf8), "c.png": Data(count: 9)])
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("mixed.zip", data: zip))))
        XCTAssertNil(MapDetection.format(of: FileInfo(url: try file("damaged.zip", data: Data([0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 7, count: 64))))))
    }

    // MARK: - GeoJSON

    func testGeoJSONFeatureCollection() throws {
        let result = try geojson("""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"a","properties":{"name":"Point A","n":1.5,"ok":true,"none":null,"tags":["x", "y"],"nested":{"k":"v"}},
           "geometry":{"type":"Point","coordinates":[2.35,48.85,35]}},
          {"type":"Feature","properties":{"stroke":"#F00","stroke-width":99,"fill":"red; background:url(x)"},
           "geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1],[0,0]],[[0.2,0.2],[0.4,0.2],[0.4,0.4],[0.2,0.2]]]}},
          {"type":"Feature","properties":{},"geometry":null},
          {"type":"Feature","geometry":{"type":"GeometryCollection","geometries":[{"type":"LineString","coordinates":[[0,0],[1,1]]},{"type":"Point","coordinates":[5,5]}]}}
        ]}
        """)
        XCTAssertEqual(result.features.count, 4)
        let a = result.features[0]
        XCTAssertEqual(a.name, "Point A")
        XCTAssertEqual(a.geometry.map { if case .point(let p) = $0 { return p }; return nil } ?? nil, GeoPoint(2.35, 48.85))
        XCTAssertEqual(a.properties.map(\.key), ["id", "name", "n", "ok", "none", "tags", "nested"])
        XCTAssertEqual(a.properties[5].value, .json("[\"x\",\"y\"]"))
        XCTAssertEqual(a.properties[6].value, .json("{\"k\":\"v\"}"))
        // Styling is validated: colours must be hex, widths are clamped.
        XCTAssertEqual(result.features[1].style?.stroke, "#ff0000")
        XCTAssertEqual(result.features[1].style?.strokeWidth, 24)
        XCTAssertNil(result.features[1].style?.fill)
        XCTAssertNil(result.features[2].geometry)
        XCTAssertEqual(result.features[3].geometry?.family, .mixed)
    }

    func testGeoJSONBareGeometryFeatureAndEscapes() throws {
        XCTAssertEqual(try geojson("{\"type\":\"LineString\",\"coordinates\":[[0,0],[1e1,-2.5E-1]]}").features.first?.geometry?.pointCount, 2)
        let feature = try geojson("{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]},\"properties\":{\"name\":\"Caf\\u00e9 \\ud83d\\uddfa \\\"q\\\"\"}}")
        XCTAssertEqual(feature.features.first?.name, "Café 🗺 \"q\"")
        // Arrays of features and trailing commas, as some tools write them.
        XCTAssertEqual(try geojson("[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]},}]").features.count, 1)
    }

    func testGeoJSONLegacyCRSIsHonoured() throws {
        let url = try file("mercator.geojson", """
        {"type":"FeatureCollection","crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:EPSG::3857"}},
         "features":[{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[255422.572,6250868.901]}}]}
        """)
        let document = try load(url)
        XCTAssertTrue(document.isReprojected)
        guard case .point(let p) = document.layers[0].features[0].geometry! else { return XCTFail() }
        XCTAssertEqual(p.x, 2.2945, accuracy: 1e-6)
        XCTAssertEqual(p.y, 48.8584, accuracy: 1e-6)
    }

    func testGeoJSONBadCoordinatesAreDroppedNotFatal() throws {
        let result = try geojson("""
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"LineString","coordinates":[[0,0],["a","b"],[null,1],[2,2],[3]]}},
          {"type":"Feature","geometry":{"type":"Polygon","coordinates":"nope"}},
          {"type":"Feature","geometry":{"type":"Unknown","coordinates":[1,2]}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[]}}
        ]}
        """)
        XCTAssertEqual(result.features.count, 4)
        XCTAssertEqual(result.features[0].geometry?.pointCount, 2)
        XCTAssertEqual(result.features[1].geometry?.pointCount, 0)
        XCTAssertNil(result.features[2].geometry)
    }

    func testDamagedGeoJSONKeepsWhatWasReadOrFails() throws {
        let truncated = try geojson("{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]}},{\"type\":\"Feat")
        XCTAssertEqual(truncated.features.count, 1)
        XCTAssertTrue(truncated.truncated)
        XCTAssertThrowsError(try geojson("{\"type\":\"FeatureCollection\",\"features\":[{"))
        XCTAssertThrowsError(try geojson(""))
        XCTAssertThrowsError(try geojson("not json"))
    }

    func testHostileNestingAndNumbersDontCrash() throws {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        XCTAssertThrowsError(try geojson("{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":\(deep)}}"))
        let deepProperties = "{\"type\":\"Feature\",\"geometry\":null,\"properties\":{\"a\":" + String(repeating: "{\"b\":", count: 50_000) + "1" + String(repeating: "}", count: 50_000) + "}}"
        XCTAssertThrowsError(try geojson(deepProperties))
        // An infinite ordinate drops its position; the rest parse exactly.
        let numbers = try geojson("{\"type\":\"LineString\",\"coordinates\":[[1e400,1],[-1e-400,2],[123456789012345678901234567890,3],[0.1234567890123456789,4]]}")
        XCTAssertEqual(numbers.features.first?.geometry?.pointCount, 3)
        XCTAssertThrowsError(try GeoJSONReader.readLines(Data([0x1E, 0xFF, 0xFE, 0x0A, 0x7B, 0x0A]), limits: .preview))
    }

    func testFeatureAndPointLimitsTruncate() throws {
        var text = "{\"type\":\"FeatureCollection\",\"features\":["
        text += (0..<500).map { "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[\($0 % 180),0]}}" }.joined(separator: ",")
        text += "]}"
        var limits = GeoLimits.preview
        limits.maxFeatures = 100
        let result = try geojson(text, limits: limits)
        XCTAssertEqual(result.features.count, 100)
        XCTAssertTrue(result.truncated)
        limits = .preview
        limits.maxPoints = 50
        XCTAssertLessThanOrEqual(try geojson(text, limits: limits).features.count, 51)
        limits = .preview
        limits.maxProperties = 2
        let props = try geojson("{\"type\":\"Feature\",\"geometry\":null,\"properties\":{\"a\":1,\"b\":2,\"c\":3,\"d\":4}}", limits: limits)
        XCTAssertEqual(props.features[0].properties.count, 2)
    }

    func testGeoJSONLines() throws {
        let text = """
        {"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{"name":"one"}}
        \u{1E}{"type":"Feature","geometry":{"type":"Point","coordinates":[3,4]},"properties":{}}
        this line is broken
        {"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[5,6]}}]}
        """
        let result = try GeoJSONReader.readLines(Data(text.utf8), limits: .preview)
        XCTAssertEqual(result.features.count, 3)
        XCTAssertEqual(result.skipped, 1)
        let rivers = try load(fixture("rivers.geojsonl"))
        XCTAssertEqual(rivers.stats.lines, 13)
    }

    // MARK: - TopoJSON

    func testTopoJSONQuantizedArcsAndObjects() throws {
        let text = """
        {"type":"Topology","transform":{"scale":[0.5,0.25],"translate":[10,20]},
         "arcs":[[[0,0],[2,0],[0,4]],[[2,4],[-2,0],[0,-4]],[[0,0],[1,1]]],
         "objects":{"shapes":{"type":"GeometryCollection","geometries":[
            {"type":"Polygon","arcs":[[0,1]],"properties":{"name":"square"},"id":7},
            {"type":"LineString","arcs":[~1]},
            {"type":"LineString","arcs":[99, -50]},
            {"type":"Point","coordinates":[4,8]}]},
          "single":{"type":"MultiPoint","coordinates":[[0,0]]}}}
        """.replacingOccurrences(of: "~1", with: "-2")
        let result = try TopoJSONReader.read(Data(text.utf8), limits: .preview)
        XCTAssertEqual(result.layers.map(\.name), ["shapes", "single"])
        let shapes = result.layers[0].features
        XCTAssertEqual(shapes[0].name, "square")
        guard case .polygon(let rings) = shapes[0].geometry! else { return XCTFail() }
        XCTAssertEqual(rings[0].first, GeoPoint(10, 20))
        XCTAssertEqual(rings[0][1], GeoPoint(11, 20))
        XCTAssertEqual(rings[0][2], GeoPoint(11, 21))
        XCTAssertEqual(rings[0].last, GeoPoint(10, 20))
        // ~1 is arc 1 reversed.
        guard case .lineString(let reversed) = shapes[1].geometry! else { return XCTFail() }
        XCTAssertEqual(reversed.first, GeoPoint(10, 20))
        // Out-of-range arc indices are ignored.
        XCTAssertEqual(shapes[2].geometry?.pointCount, 0)
        XCTAssertEqual(shapes[3].geometry.map { if case .point(let p) = $0 { return p }; return nil } ?? nil, GeoPoint(12, 22))
        XCTAssertThrowsError(try TopoJSONReader.read(Data("{\"type\":\"FeatureCollection\"}".utf8), limits: .preview))
    }

    func testWorldAtlasAndPreProjectedTopoJSON() throws {
        let world = try load(fixture("world.topojson"))
        XCTAssertEqual(world.layers.map(\.name), ["countries", "land"])
        XCTAssertEqual(world.layers[0].features.count, 177)
        XCTAssertFalse(world.isPlanar)
        // Antimeridian crossings are unwrapped instead of streaking across the map.
        for feature in world.layers[0].features {
            feature.geometry?.forEachPoint { _ in }
            if case .multiPolygon(let polygons)? = feature.geometry {
                for ring in polygons.flatMap({ $0 }) where ring.count > 1 {
                    for i in 1..<ring.count where abs(ring[i].x - ring[i - 1].x) > 180 {
                        // Only rings that encircle a pole may still jump.
                        XCTAssertTrue(ring.contains { $0.y < -80 }, feature.name ?? "?")
                    }
                }
            }
        }
        let albers = try load(fixture("us-states-albers.topojson"))
        XCTAssertTrue(albers.isPlanar)
        XCTAssertEqual(albers.planar?.yDown, true)
        XCTAssertFalse(albers.notices.isEmpty)
    }

    // MARK: - Coordinate systems

    /// Projected coordinates computed by PROJ 9 (pyproj) for each EPSG code and WGS 84 position.
    private let references: [(Int, Double, Double, Double, Double, Double)] = [
        (3857, 255422.572, 6250868.901, 2.2945, 48.8584, 1e-6),
        (3395, -8242596.036, 4938742.827, -74.0445, 40.6892, 1e-6),
        (32633, 602065.207, 5340353.594, 16.3738, 48.2082, 1e-6),
        (32756, 334900.570, 6252288.753, 151.2153, -33.8568, 1e-6),
        (2154, 842666.659, 6519924.367, 4.8357, 45.764, 1e-6),
        (3035, 4552036.450, 3273268.274, 13.405, 52.52, 1e-6),
        (3413, 0.000, -1633879.497, -45.0, 75.0, 1e-6),
        (3031, 305541.415, -1289183.942, 166.6667, -77.85, 1e-6),
        (5070, -762409.048, 1893843.600, -104.9903, 39.7392, 1e-6),
        (3577, 1550557.243, -3957467.752, 149.13, -35.2809, 1e-6),
        (2193, 1757209.253, 5920482.809, 174.7633, -36.8485, 1e-6),
        (4087, 11131949.079, 1520686.105, 100.0, 13.75, 1e-6),
        // Different datums: a published Helmert transformation, good to a few metres.
        (28992, 121492.620, 487038.223, 4.8952, 52.3702, 1e-4),
        (2056, 2600667.475, 1199657.316, 7.4474, 46.948, 1e-4),
        (21781, 683303.894, 247925.628, 8.5417, 47.3769, 1e-4),
        (27700, 530043.195, 180358.209, -0.1276, 51.5072, 1e-4),
        (31468, 4468995.873, 5333091.880, 11.582, 48.1351, 1e-4),
    ]

    func testInverseProjectionsMatchPROJ() throws {
        for (code, x, y, lon, lat, tolerance) in references {
            guard let crs = CRS.epsg(code), let p = crs.transform(GeoPoint(x, y)) else { XCTFail("EPSG:\(code)"); continue }
            XCTAssertEqual(p.x, lon, accuracy: tolerance, "EPSG:\(code) longitude")
            XCTAssertEqual(p.y, lat, accuracy: tolerance, "EPSG:\(code) latitude")
        }
    }

    func testESRIAndWKT2DefinitionsMatchTheirEPSGCodes() throws {
        let esri: [Int: String] = [
            3035: #"PROJCS["ETRS_1989_LAEA",GEOGCS["GCS_ETRS_1989",DATUM["D_ETRS_1989",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Lambert_Azimuthal_Equal_Area"],PARAMETER["False_Easting",4321000.0],PARAMETER["False_Northing",3210000.0],PARAMETER["Central_Meridian",10.0],PARAMETER["Latitude_Of_Origin",52.0],UNIT["Meter",1.0]]"#,
            28992: #"PROJCS["RD_New",GEOGCS["GCS_Amersfoort",DATUM["D_Amersfoort",SPHEROID["Bessel_1841",6377397.155,299.1528128]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Double_Stereographic"],PARAMETER["False_Easting",155000.0],PARAMETER["False_Northing",463000.0],PARAMETER["Central_Meridian",5.38763888888889],PARAMETER["Scale_Factor",0.9999079],PARAMETER["Latitude_Of_Origin",52.1561605555556],UNIT["Meter",1.0]]"#,
            2056: #"PROJCS["CH1903+_LV95",GEOGCS["GCS_CH1903+",DATUM["D_CH1903+",SPHEROID["Bessel_1841",6377397.155,299.1528128]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Hotine_Oblique_Mercator_Azimuth_Center"],PARAMETER["False_Easting",2600000.0],PARAMETER["False_Northing",1200000.0],PARAMETER["Scale_Factor",1.0],PARAMETER["Azimuth",90.0],PARAMETER["Longitude_Of_Center",7.43958333333333],PARAMETER["Latitude_Of_Center",46.9524055555556],UNIT["Meter",1.0]]"#,
            3413: #"PROJCS["WGS_1984_NSIDC_Sea_Ice_Polar_Stereographic_North",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Stereographic_North_Pole"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",-45.0],PARAMETER["Standard_Parallel_1",70.0],UNIT["Meter",1.0]]"#,
            5070: #"PROJCS["NAD_1983_Contiguous_USA_Albers",GEOGCS["GCS_North_American_1983",DATUM["D_North_American_1983",SPHEROID["GRS_1980",6378137.0,298.257222101]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Albers"],PARAMETER["False_Easting",0.0],PARAMETER["False_Northing",0.0],PARAMETER["Central_Meridian",-96.0],PARAMETER["Standard_Parallel_1",29.5],PARAMETER["Standard_Parallel_2",45.5],PARAMETER["Latitude_Of_Origin",23.0],UNIT["Meter",1.0]]"#,
            27700: #"PROJCS["British_National_Grid",GEOGCS["GCS_OSGB_1936",DATUM["D_OSGB_1936",SPHEROID["Airy_1830",6377563.396,299.3249646]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["False_Easting",400000.0],PARAMETER["False_Northing",-100000.0],PARAMETER["Central_Meridian",-2.0],PARAMETER["Scale_Factor",0.9996012717],PARAMETER["Latitude_Of_Origin",49.0],UNIT["Meter",1.0]]"#,
            // WKT2 with a datum ensemble and per-parameter units.
            -3035: #"PROJCRS["ETRS89-extended / LAEA Europe",BASEGEOGCRS["ETRS89",ENSEMBLE["European Terrestrial Reference System 1989 ensemble",MEMBER["European Terrestrial Reference Frame 1989"],ELLIPSOID["GRS 1980",6378137,298.257222101,LENGTHUNIT["metre",1]],ENSEMBLEACCURACY[0.1]],PRIMEM["Greenwich",0,ANGLEUNIT["degree",0.0174532925199433]],ID["EPSG",4258]],CONVERSION["Europe Equal Area 2001",METHOD["Lambert Azimuthal Equal Area",ID["EPSG",9820]],PARAMETER["Latitude of natural origin",52,ANGLEUNIT["degree",0.0174532925199433],ID["EPSG",8801]],PARAMETER["Longitude of natural origin",10,ANGLEUNIT["degree",0.0174532925199433],ID["EPSG",8802]],PARAMETER["False easting",4321000,LENGTHUNIT["metre",1],ID["EPSG",8806]],PARAMETER["False northing",3210000,LENGTHUNIT["metre",1],ID["EPSG",8807]]],CS[Cartesian,2],AXIS["northing (Y)",north,ORDER[1],LENGTHUNIT["metre",1]],AXIS["easting (X)",east,ORDER[2],LENGTHUNIT["metre",1]],ID["EPSG",3035]]"#,
            -2056: #"PROJCRS["CH1903+ / LV95",BASEGEOGCRS["CH1903+",DATUM["CH1903+",ELLIPSOID["Bessel 1841",6377397.155,299.1528128,LENGTHUNIT["metre",1]]],PRIMEM["Greenwich",0,ANGLEUNIT["degree",0.0174532925199433]],ID["EPSG",4150]],CONVERSION["Swiss Oblique Mercator 1995",METHOD["Hotine Oblique Mercator (variant B)",ID["EPSG",9815]],PARAMETER["Latitude of projection centre",46.9524055555556,ANGLEUNIT["degree",0.0174532925199433]],PARAMETER["Longitude of projection centre",7.43958333333333,ANGLEUNIT["degree",0.0174532925199433]],PARAMETER["Azimuth at projection centre",90,ANGLEUNIT["degree",0.0174532925199433]],PARAMETER["Angle from Rectified to Skew Grid",90,ANGLEUNIT["degree",0.0174532925199433]],PARAMETER["Scale factor at projection centre",1,SCALEUNIT["unity",1]],PARAMETER["Easting at projection centre",2600000,LENGTHUNIT["metre",1]],PARAMETER["Northing at projection centre",1200000,LENGTHUNIT["metre",1]]],CS[Cartesian,2],AXIS["(E)",east,ORDER[1],LENGTHUNIT["metre",1]],AXIS["(N)",north,ORDER[2],LENGTHUNIT["metre",1]],ID["EPSG",2056]]"#,
        ]
        for (key, wkt) in esri {
            let code = abs(key)
            guard let reference = references.first(where: { $0.0 == code }) else { XCTFail("\(code)"); continue }
            guard let crs = CRS.parse(wkt: wkt), let p = crs.transform(GeoPoint(reference.1, reference.2)) else { XCTFail("WKT \(key)"); continue }
            XCTAssertEqual(p.x, reference.3, accuracy: reference.5, "WKT \(key)")
            XCTAssertEqual(p.y, reference.4, accuracy: reference.5, "WKT \(key)")
        }
        XCTAssertEqual(CRS.parse(wkt: esri[27700]!)?.name, "British National Grid")
    }

    func testNamedCRSAndUnsupportedOnes() throws {
        XCTAssertEqual(CRS.named("urn:ogc:def:crs:OGC:1.3:CRS84")?.isWGS84Compatible, true)
        XCTAssertEqual(CRS.named("EPSG:4326")?.isWGS84Compatible, true)
        XCTAssertEqual(CRS.named("urn:ogc:def:crs:EPSG::32633")?.name, "WGS 84 / UTM zone 33N")
        XCTAssertNil(CRS.named("something else"))
        let robinson = #"PROJCS["World_Robinson",GEOGCS["GCS_WGS_1984",DATUM["D_WGS_1984",SPHEROID["WGS_1984",6378137.0,298.257223563]],PRIMEM["Greenwich",0.0],UNIT["Degree",0.0174532925199433]],PROJECTION["Robinson"],PARAMETER["Central_Meridian",0.0],UNIT["Meter",1.0]]"#
        let crs = try XCTUnwrap(CRS.parse(wkt: robinson))
        XCTAssertFalse(crs.canTransform)
        XCTAssertNil(CRS.parse(wkt: "garbage[[[[[["))
        XCTAssertNil(CRS.parse(wkt: String(repeating: "A[", count: 10_000)))
    }

    func testShapefileReprojectionMatchesPyprojReference() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("scripts/shapefile_reference.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let layers = try XCTUnwrap(json["layers"] as? [String: [String: Any]])
        XCTAssertEqual(layers.count, 3)
        for (_, layer) in layers {
            let name = try XCTUnwrap(layer["file"] as? String)
            let wgs = try XCTUnwrap(layer["wgs84"] as? [String: Double])
            let document = try load(fixture(name))
            XCTAssertTrue(document.isReprojected, name)
            var first: GeoPoint?
            document.layers[0].features[0].geometry?.forEachPoint { if first == nil { first = $0 } }
            let p = try XCTUnwrap(first)
            XCTAssertEqual(p.x, wgs["lon"]!, accuracy: 1e-5, name)
            XCTAssertEqual(p.y, wgs["lat"]!, accuracy: 1e-5, name)
        }
    }

    // MARK: - Shapefiles

    func testShapefilesWithSidecars() throws {
        let parcels = try load(fixture("parcels_utm33n.shp"))
        XCTAssertEqual(parcels.stats.polygons, 40)
        let withHoles = parcels.layers[0].features.filter {
            if case .polygon(let rings) = $0.geometry { return rings.count > 1 }
            if case .multiPolygon(let polygons) = $0.geometry { return polygons.contains { $0.count > 1 } }
            return false
        }
        XCTAssertEqual(withHoles.count, 6)
        let fields = parcels.layers[0].features[0].properties.map(\.key)
        XCTAssertEqual(fields, ["ID", "NAME", "AREA_M2", "ZONED", "SURVEYED"])

        let rivers = try load(fixture("rivers.shp"))
        XCTAssertEqual(rivers.stats.lines, 13)
        XCTAssertTrue(rivers.layers[0].features.contains { $0.properties.contains { $0.value == .string("Paraná") } })
        // Windows-1252 text without a .cpg.
        let roads = try load(fixture("roads_lambert93.shp"))
        let names = roads.layers[0].features.compactMap { f in f.properties.first { $0.key == "NAME" }?.value.text }
        XCTAssertTrue(names.contains { $0.contains("é") || $0.contains("è") || $0.contains("ô") }, names.joined(separator: ", "))
        // No .prj, coordinates in degrees: assumed WGS 84.
        let summits = try load(fixture("points_noprj.shp"))
        XCTAssertEqual(summits.stats.points, 11)
        XCTAssertEqual(summits.projectionText, "WGS 84")
    }

    func testZippedShapefile() throws {
        let document = try load(fixture("cities_shp.zip"))
        XCTAssertEqual(document.format, .zippedShapefile)
        XCTAssertEqual(document.stats.points, 243)
        XCTAssertTrue(document.layers[0].features[0].properties.contains { $0.key == "CAPITAL" })
    }

    func testHostileShapefilesDontCrash() throws {
        var header = Data(count: 100)
        header[0] = 0; header[1] = 0; header[2] = 0x27; header[3] = 0x0A
        header[32] = 5
        // A record that claims a huge length, then one with absurd part and point counts.
        var record = Data()
        func be(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { record.append(contentsOf: $0) } }
        func le(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { record.append(contentsOf: $0) } }
        be(1); be(30); le(5); record.append(Data(count: 32)); le(0xFFFF_FFF0); le(0xFFFF_FFF0); le(0)
        let url = try file("evil.shp", data: header + record)
        XCTAssertNoThrow(try load(url))
        var other = Data()
        swap(&record, &other)
        be(1); be(0x7FFF_FFFF); le(1)
        XCTAssertNoThrow(try load(try file("evil2.shp", data: header + record)))
        // A DBF whose header lies about its sizes.
        var dbf = Data(count: 64)
        dbf[4] = 0xFF; dbf[5] = 0xFF; dbf[6] = 0xFF; dbf[7] = 0x7F
        dbf[8] = 0xFF; dbf[9] = 0x7F
        dbf[10] = 1
        XCTAssertNil(ShapefileDBF(data: dbf, cpg: nil, maxFields: 10))
    }

    // MARK: - KML, KMZ, GPX

    func testKMLStylesFoldersAndTracks() throws {
        let document = try load(fixture("places.kml"))
        XCTAssertEqual(document.layers.map(\.name), ["Landmarks", "Walks", "Areas"])
        XCTAssertEqual(document.stats.features, 13)
        let all = document.layers.flatMap(\.features)
        // aabbggrr colours become #rrggbb with opacity.
        XCTAssertTrue(all.contains { $0.style?.stroke != nil && $0.style?.strokeWidth != nil })
        XCTAssertTrue(all.contains { $0.style?.fill != nil && ($0.style?.fillOpacity ?? 1) < 1 })
        // IconStyle colours tint the marker (ff0000ff is red, ff00ffff yellow); remote icons are never loaded.
        XCTAssertTrue(all.contains { $0.style?.markerColor == "#ff0000" })
        XCTAssertTrue(all.contains { $0.style?.markerColor == "#ffff00" })
        XCTAssertTrue(document.icons.isEmpty)
        // Without a colour, Google's standard icons keep theirs by name.
        XCTAssertEqual(KMLReader.iconColor(forHref: "http://maps.google.com/mapfiles/kml/paddle/red-circle.png"), "#ff3b30")
        XCTAssertEqual(KMLReader.iconColor(forHref: "http://maps.google.com/mapfiles/kml/pushpin/ylw-pushpin.png"), "#ffcc00")
        XCTAssertEqual(document.tracks.count, 1)
        XCTAssertTrue(all.contains { $0.properties.count > 2 })
        // Descriptions stay as text here; the page sanitises them.
        XCTAssertTrue(all.contains { ($0.detail ?? "").contains("<script>") })
        XCTAssertEqual(KMLReader.color("7f0000ff")?.0, "#ff0000")
        XCTAssertEqual(KMLReader.color("7f0000ff")?.1 ?? 0, 127.0 / 255, accuracy: 1e-9)
        XCTAssertNil(KMLReader.color("zzzzzzzz"))
    }

    func testKMZWithIconsAndOverlay() throws {
        let document = try load(fixture("tour.kmz"))
        XCTAssertEqual(document.stats.points, 6)
        XCTAssertEqual(document.overlays.count, 1)
        XCTAssertEqual(document.icons, ["files/marker.png"])
        let icon = try XCTUnwrap(document.loadImage?("files/marker.png", 1 << 20))
        XCTAssertEqual(TileSet.sniffFormat(icon), "png")
        XCTAssertNil(document.loadImage?("../../etc/passwd", 1 << 20))
        XCTAssertNil(document.loadImage?("files/overlay.png", 10))
    }

    func testMalformedXMLFormats() throws {
        // Damaged with nothing readable: an error, so the preview falls back to showing the XML.
        XCTAssertThrowsError(try load(try file("broken.kml", "<kml><Document><Placemark><Point><coordinates>1,2")))
        XCTAssertThrowsError(try load(try file("broken.gpx", "<gpx><trk><trkseg><trkpt lat=\"x\"")))
        let fallback = try MapsModule.prepare(FileInfo(url: try file("broken2.kml", "<kml><Placemark><name>x</nam")), settings: PreviewSettings())
        guard case .web(let page, _, _) = fallback else { return XCTFail() }
        XCTAssertEqual(page.kind, .code)
        // Damaged after some placemarks: what was read is kept.
        let partial = try load(try file("partial.kml", "<kml><Placemark><Point><coordinates>1,2</coordinates></Point></Placemark><Placemark><Point><coord"))
        XCTAssertEqual(partial.stats.points, 1)
        let entities = """
        <?xml version="1.0"?><!DOCTYPE kml [<!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"><!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;"><!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;"><!ENTITY f "&e;&e;&e;&e;&e;&e;&e;&e;&e;&e;"><!ENTITY x SYSTEM "file:///etc/passwd">]>
        <kml><Document><Placemark><name>&f;&x;</name><Point><coordinates>1,2</coordinates></Point></Placemark></Document></kml>
        """
        let start = CFAbsoluteTimeGetCurrent()
        let document = try? load(try file("bomb.kml", entities))
        try XCTAssertWithinBudget(CFAbsoluteTimeGetCurrent() - start, 10)
        XCTAssertFalse((document?.layers.first?.features.first?.name ?? "").contains("root:"))
    }

    func testGPXTrackStatistics() throws {
        let hike = try load(fixture("hike.gpx"))
        XCTAssertEqual(hike.layers.map(\.name), ["Tracks", "Waypoints"])
        XCTAssertEqual(hike.facts, ["4 waypoints"])
        let track = try XCTUnwrap(hike.tracks.first)
        XCTAssertEqual(track.pointCount, 1530)
        XCTAssertEqual(track.distance, 14_360, accuracy: 300)
        XCTAssertEqual(track.duration ?? 0, 5 * 3600, accuracy: 1)
        XCTAssertLessThan(track.movingTime ?? .infinity, 5 * 3600 - 15 * 60)
        XCTAssertEqual(track.gain ?? 0, 940, accuracy: 60)
        XCTAssertEqual(track.maxElevation ?? 0, 2537, accuracy: 15)
        XCTAssertNotNil(track.averageHeartRate)
        XCTAssertLessThanOrEqual(track.samples.count, 1601)
        let ride = try load(fixture("ride.gpx"))
        // The recorded ride comes before the planned route.
        XCTAssertNotNil(ride.tracks.first?.duration)
        let rideTrack = try XCTUnwrap(ride.tracks.first)
        XCTAssertEqual(rideTrack.distance, 39_980, accuracy: 800)
        XCTAssertEqual(rideTrack.duration ?? 0, 6130, accuracy: 2)
        XCTAssertGreaterThan(rideTrack.maxSpeed ?? 0, 5)
        XCTAssertTrue(ride.layers.contains { $0.name == "Routes" })
    }

    func testISOTime() {
        XCTAssertEqual(ISOTime.parse("1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(ISOTime.parse("2024-05-01T10:15:30.5Z"), 1_714_558_530.5)
        XCTAssertEqual(ISOTime.parse("2024-05-01T12:15:30+02:00"), 1_714_558_530)
        XCTAssertNil(ISOTime.parse("yesterday"))
        XCTAssertNil(ISOTime.parse("2024-13-01T00:00:00Z"))
    }

    // MARK: - OpenStreetMap and WKT

    func testOpenStreetMap() throws {
        let town = try load(fixture("town.osm"))
        let buildings = try XCTUnwrap(town.layers.first { $0.name == "Buildings" })
        XCTAssertGreaterThanOrEqual(buildings.features.count, 150)
        XCTAssertTrue(town.layers.contains { $0.role == .road })
        XCTAssertTrue(town.layers.contains { $0.role == .place })
        // The multipolygon relation (outer split in two ways, plus an inner way) becomes one area with a hole.
        let relation = town.layers.flatMap(\.features).first { $0.properties.first?.value.text.hasPrefix("relation/") == true }
        if case .polygon(let rings)? = relation?.geometry { XCTAssertEqual(rings.count, 2) } else { XCTFail("relation geometry") }
        XCTAssertEqual(OSMReader.joinRings([[1, 2, 3], [3, 4, 1]]), [[1, 2, 3, 4, 1]])
        XCTAssertEqual(OSMReader.joinRings([[1, 2], [5, 6]]), [])
    }

    func testWKT() throws {
        let result = WKTReader.read("""
        SRID=4326;POINT (13.4 52.5)
        POINT Z (1 2 3)
        LINESTRING(0 0, 1 1, 2 0)
        POLYGON ((0 0, 4 0, 4 4, 0 4, 0 0), (1 1, 2 1, 2 2, 1 1))
        MULTIPOINT ((1 2), (3 4))
        MULTIPOINT (1 2, 3 4)
        MULTILINESTRING ((0 0, 1 1), (2 2, 3 3))
        MULTIPOLYGON (((0 0, 1 0, 1 1, 0 0)), ((5 5, 6 5, 6 6, 5 5)))
        GEOMETRYCOLLECTION (POINT (1 1), LINESTRING (0 0, 1 1))
        POINT EMPTY
        this is not wkt
        POLYGON ((0 0, 1
        """, limits: .preview)
        XCTAssertEqual(result.srid, 4326)
        XCTAssertEqual(result.geometries.count, 10)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertEqual(result.geometries.map(\.family), [.point, .point, .line, .polygon, .point, .point, .line, .polygon, .mixed, .point])
        XCTAssertEqual(result.geometries[4].pointCount, 2)
        XCTAssertEqual(result.geometries[5].pointCount, 2)
        let deep = String(repeating: "GEOMETRYCOLLECTION (", count: 10_000) + "POINT (1 1)" + String(repeating: ")", count: 10_000)
        XCTAssertTrue(WKTReader.read(deep, limits: .preview).geometries.isEmpty)
        XCTAssertEqual(try load(fixture("single.wkt")).stats.polygons, 1)
    }

    func testWKB() throws {
        // Little-endian point, big-endian linestring with Z (ISO 1002).
        var le = Data([1]); le.append(contentsOf: [1, 0, 0, 0])
        for v in [2.5, -1.25] { withUnsafeBytes(of: v.bitPattern.littleEndian) { le.append(contentsOf: $0) } }
        guard case .point(let p) = WKBReader.geometry(le) else { return XCTFail() }
        XCTAssertEqual(p, GeoPoint(2.5, -1.25))
        var be = Data([0]); withUnsafeBytes(of: UInt32(1002).bigEndian) { be.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(2).bigEndian) { be.append(contentsOf: $0) }
        for v in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0] { withUnsafeBytes(of: v.bitPattern.bigEndian) { be.append(contentsOf: $0) } }
        guard case .lineString(let line) = WKBReader.geometry(be) else { return XCTFail() }
        XCTAssertEqual(line, [GeoPoint(1, 2), GeoPoint(4, 5)])
        // A GeoPackage header with an xy envelope in front.
        var gp = Data([0x47, 0x50, 0, 0b0000_0011]); withUnsafeBytes(of: Int32(4326).littleEndian) { gp.append(contentsOf: $0) }
        gp.append(Data(count: 32)); gp.append(le)
        let parsed = try XCTUnwrap(WKBReader.geoPackage(gp))
        XCTAssertEqual(parsed.srs, 4326)
        XCTAssertNotNil(parsed.geometry)
        // Lies about counts, and truncation.
        var evil = Data([1]); evil.append(contentsOf: [2, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertNil(WKBReader.geometry(evil))
        XCTAssertNil(WKBReader.geometry(le.prefix(10)))
        XCTAssertNil(WKBReader.geometry(Data()))
    }

    // MARK: - GeoPackage and MBTiles

    func testGeoPackage() throws {
        let document = try load(fixture("places.gpkg"))
        XCTAssertEqual(document.layers.map(\.name).sorted(), ["parks", "peaks", "trails"])
        XCTAssertEqual(document.stats.polygons, 5)
        XCTAssertEqual(document.stats.points, 15)
        XCTAssertEqual(document.stats.lines, 10)
        XCTAssertEqual(document.stats.empty, 1)
        XCTAssertTrue(document.facts.contains("1 attribute table"))
        // Peaks are stored in Web Mercator metres and come out near Yosemite.
        let peaks = try XCTUnwrap(document.layers.first { $0.name == "peaks" })
        let b = peaks.bounds
        XCTAssertGreaterThan(b.minX, -120.5); XCTAssertLessThan(b.maxX, -118.5)
        XCTAssertGreaterThan(b.minY, 37.0); XCTAssertLessThan(b.maxY, 38.5)
        XCTAssertNotNil(document.crsSummary)
    }

    func testMBTiles() throws {
        let raster = try load(fixture("raster.mbtiles"))
        let set = try XCTUnwrap(raster.tileSets.first)
        XCTAssertEqual(set.info.kind, .raster)
        XCTAssertEqual(set.info.format, "png")
        XCTAssertEqual(set.info.minzoom, 0)
        XCTAssertEqual(set.info.maxzoom, 3)
        XCTAssertEqual(set.info.name, "World Overview")
        XCTAssertEqual(set.fetch(0, 0, 0).map(TileSet.sniffFormat), "png")
        XCTAssertNil(set.fetch(0, 1, 0))
        XCTAssertNil(set.fetch(-1, 0, 0))
        XCTAssertNil(set.fetch(40, 0, 0))

        let vector = try load(fixture("vector.mbtiles"))
        let vset = try XCTUnwrap(vector.tileSets.first)
        XCTAssertEqual(vset.info.kind, .vector)
        XCTAssertEqual(Set(vset.info.vectorLayers.map(\.id)), ["land", "boundaries", "rivers", "places"])
        // Tiles are stored gzipped and served inflated.
        let tile = try XCTUnwrap(vset.fetch(0, 0, 0))
        XCTAssertFalse(Inflate.isGzip(tile))
        let decoded = try XCTUnwrap(VectorTile.decode(tile))
        XCTAssertEqual(Set(decoded.layers.map(\.name)), ["land", "boundaries", "rivers", "places"])
        XCTAssertTrue(decoded.layers.contains { $0.features.contains { $0.properties.contains { $0.key == "name" } } })
        XCTAssertEqual(try load(fixture("relief.mbtiles")).tileSets.first?.info.format, "jpg")
    }

    func testHostileTilesAndArchives() throws {
        // Random bytes never crash the tile decoder.
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let bytes = (0..<Int.random(in: 0...512, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = VectorTile.decode(Data(bytes))
        }
        // A deflate stream that expands past its limit is refused.
        let zeros = Data(count: 4 << 20)
        let compressed = try (zeros as NSData).compressed(using: .zlib) as Data
        XCTAssertNil(Inflate.decompress(compressed, mode: .raw, limit: 1 << 20))
        XCTAssertEqual(Inflate.decompress(compressed, mode: .raw, limit: 8 << 20)?.count, 4 << 20)
        XCTAssertNil(Inflate.decompress(Data([1, 2, 3, 4]), mode: .gzipOrZlib, limit: 1024))
        // A non-SQLite file with a database extension is turned away before SQLite sees it,
        // and a SQLite file without the expected tables is an error, not a crash.
        let db = try file("empty.mbtiles", data: Data("SQLite format 3\0".utf8) + Data(count: 84))
        XCTAssertThrowsError(try load(db))
    }

    // MARK: - Output for the page

    func testWriterProducesValidWoundGeoJSON() throws {
        let layer = GeoLayer(name: "test")
        var styled = GeoFeature(geometry: .polygon([[GeoPoint(0, 0), GeoPoint(0, 1), GeoPoint(1, 1), GeoPoint(1, 0)],
                                                     [GeoPoint(0.2, 0.2), GeoPoint(0.4, 0.2), GeoPoint(0.4, 0.4)]]))
        styled.style = GeoStyle(stroke: "#ff0000", strokeWidth: 2, fill: "#00ff00", fillOpacity: 0.5, markerColor: nil, icon: 3)
        var named = GeoFeature(geometry: .point(GeoPoint(-0.00000004, 1e-9)))
        named.name = "\"Quote\" </script> \\ \u{0001}"
        layer.features = [styled, named, GeoFeature(geometry: .lineString([GeoPoint(1, 1)])), GeoFeature(geometry: nil)]
        let data = GeoJSONWriter.layer(layer, firstID: 10)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try XCTUnwrap(json["features"] as? [[String: Any]])
        // The one-point line and the empty geometry are left out.
        XCTAssertEqual(features.count, 2)
        XCTAssertEqual(features[0]["id"] as? Int, 10)
        XCTAssertEqual(features[1]["id"] as? Int, 11)
        let properties = try XCTUnwrap(features[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["stroke"] as? String, "#ff0000")
        XCTAssertEqual(properties["icon"] as? String, "icon-3")
        XCTAssertEqual((features[1]["properties"] as? [String: Any])?["label"] as? String, named.name)
        let rings = try XCTUnwrap((features[0]["geometry"] as? [String: Any])?["coordinates"] as? [[[Double]]])
        func area(_ ring: [[Double]]) -> Double { zip(ring, ring.dropFirst()).reduce(0) { $0 + $1.0[0] * $1.1[1] - $1.1[0] * $1.0[1] } / 2 }
        XCTAssertGreaterThan(area(rings[0]), 0, "outer ring counter-clockwise")
        XCTAssertLessThan(area(rings[1]), 0, "hole clockwise")
        XCTAssertEqual(rings[1].first, rings[1].last, "rings are closed")
        let point = try XCTUnwrap((features[1]["geometry"] as? [String: Any])?["coordinates"] as? [Double])
        XCTAssertEqual(point, [0, 0])
    }

    func testPageDataAndResources() throws {
        let topo = """
        {"type":"Topology","arcs":[[[0,0],[1,1]]],"objects":{"</script><script>alert(1)</script>":{"type":"GeometryCollection","geometries":[{"type":"LineString","arcs":[0],"properties":{"name":"<img src=x onerror=alert(1)>"}}]}}}
        """
        let url = try file("evil.topojson", topo)
        let info = FileInfo(url: url)
        let document = try MapLoader.load(info, format: .topojson, limits: .preview)
        document.normalize()
        guard case .web(let page, let summary, _) = MapPageBuilder.preview(document, file: info) else { return XCTFail() }
        let html = page.html(settings: PreviewSettings())
        XCTAssertFalse(html.contains("</script><script>alert"))
        XCTAssertTrue(html.contains("connect-src greece://asset greece://module;"))
        XCTAssertEqual(summary.title, "TopoJSON")
        let resources = try XCTUnwrap(page.resources)
        let layer = try XCTUnwrap(resources("layer/0.json"))
        XCTAssertEqual(layer.mimeType, "application/json")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: layer.data))
        let feature = try XCTUnwrap(resources("feature/0"))
        let details = try XCTUnwrap(JSONSerialization.jsonObject(with: feature.data) as? [String: Any])
        XCTAssertEqual(details["name"] as? String, "<img src=x onerror=alert(1)>")
        XCTAssertNotNil(details["length"])
        for path in ["layer/1.json", "layer/-1.json", "feature/99", "feature/-5", "feature/x", "icon/0", "overlay/0", "tile/x/0/0/0",
                     "../../../etc/passwd", "layer/../../etc/passwd", ""] {
            XCTAssertNil(resources(path), path)
        }
    }

    func testPreviewSummaries() throws {
        func summary(_ name: String) throws -> FileSummary {
            let info = FileInfo(url: fixture(name))
            guard case .web(_, let summary, _) = try MapsModule.prepare(info, settings: PreviewSettings()) else { throw GeoError.invalid(name) }
            return summary
        }
        XCTAssertEqual(try summary("countries.geojson").details.prefix(2), ["177 polygons", "WGS 84"])
        XCTAssertEqual(try summary("parcels_utm33n.shp").details[1], "WGS 84 / UTM zone 33N")
        let gpx = try summary("hike.gpx")
        XCTAssertEqual(gpx.title, "GPX")
        XCTAssertTrue(gpx.details.contains("4 waypoints"))
        XCTAssertTrue(try summary("vector.mbtiles").details.contains("Vector · 4 layers"))
    }

    func testBrokenGeoJSONInAJSONFileFallsBackToCode() throws {
        // Looks like GeoJSON in its first bytes, but is damaged right away.
        let url = try file("broken.json", "{\"type\":\"FeatureCollection\",\"features\":[{\"type\": oops")
        let prepared = try MapsModule.prepare(FileInfo(url: url), settings: PreviewSettings())
        guard case .web(let page, let summary, _) = prepared else { return XCTFail() }
        XCTAssertEqual(page.kind, .code)
        XCTAssertEqual(summary.title, "JSON")
    }

    // MARK: - Thumbnails

    func testThumbnailsForEveryFormat() throws {
        let names = ["countries.geojson", "cities.json", "rivers.geojsonl", "world.topojson", "us-states-albers.topojson", "places.kml",
                     "tour.kmz", "hike.gpx", "rivers.shp", "cities_shp.zip", "places.gpkg", "raster.mbtiles", "vector.mbtiles",
                     "town.osm", "shapes.wkt"]
        let maximum = CGSize(width: 256, height: 256)
        for name in names {
            let page = try XCTUnwrap(MapsModule.thumbnail(FileInfo(url: fixture(name)), size: maximum, settings: PreviewSettings()), name)
            XCTAssertLessThanOrEqual(page.size.width, 256, name)
            XCTAssertLessThanOrEqual(page.size.height, 256, name)
            XCTAssertGreaterThan(min(page.size.width, page.size.height), 150, name)
            let image = NSImage(size: page.size, flipped: false) { _ in page.draw(); return true }
            XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil), name)
        }
        XCTAssertFalse(Basemap.layers.isEmpty)
        XCTAssertEqual(Set(Basemap.layers.keys), ["land", "lakes", "rivers", "states", "borders", "countries"])
    }

    // MARK: - Helpers

    /// A stored (uncompressed) ZIP with the given members.
    private func makeZip(_ members: [String: Data]) throws -> Data {
        var out = Data()
        var central = Data()
        func u16(_ v: Int, _ d: inout Data) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: Int, _ d: inout Data) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        for (name, data) in members.sorted(by: { $0.key < $1.key }) {
            let offset = out.count
            let nameData = Data(name.utf8)
            u32(0x04034B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0, &out)
            u32(0, &out); u32(data.count, &out); u32(data.count, &out); u16(nameData.count, &out); u16(0, &out)
            out.append(nameData); out.append(data)
            u32(0x02014B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0, &central); u32(data.count, &central); u32(data.count, &central); u16(nameData.count, &central)
            u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central)
            central.append(nameData)
        }
        let start = out.count
        out.append(central)
        u32(0x06054B50, &out); u16(0, &out); u16(0, &out); u16(members.count, &out); u16(members.count, &out)
        u32(central.count, &out); u32(start, &out); u16(0, &out)
        return out
    }
}

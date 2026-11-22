# Map fixtures: sources and licences

Every file here (except the two TopoJSON downloads, which are copied byte for byte) is written by
`scripts/make_fixtures.py`. The script uses fixed seeds and fixed timestamps, so two runs give
byte-identical output.

```
python3 -m venv venv && venv/bin/pip install pyproj Pillow mapbox-vector-tile
venv/bin/python scripts/make_fixtures.py --ne <natural-earth-geojson-dir> --cache <download-dir>
```

- Requirements: Python 3, `pyproj` (exact reprojection, geodesic lengths and areas) and `Pillow` 9.1+
  (PNG/JPEG tiles, KMZ images). `mapbox-vector-tile` is optional. It is used only to decode every
  vector tile back as an independent check. Tested with Python 3.12.0, pyproj 3.8.0 (PROJ 9.8.1),
  Pillow 13.0.0 and mapbox-vector-tile 2.2.0. Byte-identical output assumes the same library
  versions, because PNG/JPEG encoders and SQLite page layout can change between releases.
- Inputs: Natural Earth 1:110m GeoJSON layers from github.com/nvkelso/natural-earth-vector
  (`geojson/` folder). Missing layers are downloaded; their SHA-256 values are printed on each run.
- The helper modules (`fx_*.py`) live next to the script. `make_large.py` needs only the standard
  library. `scripts/build_basemap.py` belongs to the app's basemap build and is not part of these
  fixtures.

Licences: Natural Earth data is public domain. world-atlas and us-atlas are ISC-licensed builds of
Natural Earth and US Census Bureau (public domain) data. Everything marked synthetic was made up by
the script; real place names are used, but the geometry is approximate and the data is invented.

## Files

| File | What it is | Source / licence |
| --- | --- | --- |
| `countries.geojson` | 177 admin-0 countries (148 Polygon, 29 MultiPolygon). Only the properties NAME, NAME_LONG, CONTINENT, SUBREGION, POP_EST, GDP_MD and ISO_A3 are kept, and coordinates are rounded to 4 decimals. Sudan keeps the self-intersection it has in the source. ISO_A3 is "-99" for Norway, France, N. Cyprus, Somaliland and Kosovo, as in the source. | Natural Earth, public domain |
| `cities.json` | GeoJSON FeatureCollection with a `.json` extension, and `"type"` as its first key. Holds 243 populated places (name, adm0name, pop_max, featurecla). | Natural Earth, public domain |
| `rivers.geojsonl` | GeoJSON Lines: 13 river LineString Features, one per line, with no wrapper (name, featurecla, scalerank). | Natural Earth, public domain |
| `world.topojson` | world-atlas@2.0.2 `countries-110m.json`, unmodified (objects `countries` with 177 geometries, and `land`). Quantised. | world-atlas, ISC (from Natural Earth) |
| `us-states-albers.topojson` | us-atlas@3.0.1 `states-albers-10m.json`, unmodified. Its coordinates are already projected (Albers USA, 975x610 planar units). Objects: `states` (51) and `nation`. | us-atlas, ISC (US Census Bureau data, public domain) |
| `rivers.shp/.shx/.dbf/.prj/.cpg` | PolyLine (type 3) with 13 rivers. The dbf has NAME, NAME_RU, FEATURECLA and SCALERANK. It is UTF-8 (`.cpg` says `UTF-8`) and includes "Paraná" and Cyrillic NAME_RU values. The `.prj` is ESRI GCS_WGS_1984. | Natural Earth, public domain |
| `parcels_utm33n.shp/.shx/.dbf/.prj` | Polygon (type 5) with 40 synthetic parcels in Vienna, EPSG:32633 metres. Outer rings are clockwise and holes counter-clockwise. Six parcels have a courtyard hole, and parcel 18 has two outer rings. The dbf has ID (N), NAME (C), AREA_M2 (F, the planar area), ZONED (L, `?` for parcel 11) and SURVEYED (D, blank for parcel 7). | Synthetic (make_fixtures.py) |
| `roads_lambert93.shp/.shx/.dbf/.prj` | PolyLine with 15 roads in Lyon, EPSG:2154 (RGF93 / Lambert-93), projected with pyproj. The dbf has NAME and KIND and is Windows-1252 with LDID 0x57 and no `.cpg`, so it tests the legacy-encoding fallback (é, è, ô). | Synthetic |
| `stations_nad83_ft.shp/.shx/.dbf/.prj` | Point with 20 Bay Area stations in NAD83 / California zone III, US survey feet (EPSG:2227). The `.prj` is the ArcGIS form with `UNIT["Foot_US",0.3048006096012192]`. The dbf has NAME and ELEV_FT (N). | Synthetic |
| `points_noprj.shp/.shx/.dbf` | PointZ (type 11) with 11 Alpine summits in plain lon/lat. Z is elevation in metres and M is 0. There is no `.prj`. The dbf has NAME, COUNTRY and ELEV_M. | Synthetic (approximate public summit positions) |
| `cities_shp.zip` | Deflate ZIP holding `cities.shp/.shx/.dbf/.prj/.cpg`: Point (type 1), 243 populated places. The dbf is UTF-8 with NAME, ADM0NAME, POP_MAX, FEATURECLA and CAPITAL (L). | Natural Earth, public domain |
| `scripts/shapefile_reference.json` | For the three projected shapefiles: the first vertex of the first record as stored, and the same point converted to WGS84 with pyproj. Use it to unit-test reprojection. | Generated |
| `places.gpkg` | OGC GeoPackage 1.3 (application_id `GPKG`, user_version 10300) covering Yosemite. Tables: `parks` (MULTIPOLYGON, EPSG:4326, 5 rows, 4 holes), `trails` (LINESTRING, 4326, 11 rows; 2 rows use big-endian header and WKB, and 1 row has a NULL geometry), `peaks` (POINT Z, EPSG:3857, 15 rows, little-endian), and `notes` (attributes, 4 rows). | Synthetic |
| `raster.mbtiles` | 85 PNG tiles (palette, 256x256) for z0-3 in Web Mercator, using TMS rows. Shows land, lakes, coastline and country borders. | Rendered from Natural Earth (public domain) |
| `relief.mbtiles` | 21 JPEG tiles for z0-2: Natural Earth land with a synthetic, decorative terrain tint and coastal shading. | Natural Earth plus synthetic shading |
| `vector.mbtiles` | 90 gzip-compressed Mapbox Vector Tile v2 tiles with layers land, boundaries, rivers and places (extent 4096, 64-unit buffer). z0-2 are complete. z3 has 57 tiles because 7 empty ocean tiles are omitted. z4 covers only Europe (x 7-9, y 3-6). The `json` metadata row lists the vector_layers. The encoder is the script's own. | Natural Earth, public domain |
| `hike.gpx` | GPX 1.1 loop hike from Zermatt via Findeln and Stellisee: 14.4 km, about 940 m of climbing, 5 h including a 20 min break between its 2 trksegs. Has 1530 trkpt (ele, time, Garmin `gpxtpx:hr`) and 4 waypoints. | Synthetic |
| `ride.gpx` | GPX 1.0 bike ride from Zwolle to Deventer: a route of 25 rtept and a track of 1227 trkpt (ele, time, course, speed). 40.0 km in 1 h 42 min. | Synthetic |
| `places.kml` | KML 2.2 document for Paris. It has shared Styles, a StyleMap, the folders Landmarks, Walks and Areas, CDATA HTML descriptions, ExtendedData, a LineString, a Polygon with a hole, a MultiGeometry and a gx:Track. The Notre-Dame description is deliberately hostile (`<script>`, `onerror`, `javascript:` and `onclick`) to test sanitising. | Synthetic |
| `tour.kmz` | Deflate ZIP: `doc.kml` (6 placemarks in Rome, using the icon `files/marker.png`, and a GroundOverlay of `files/overlay.png`), a 32x32 marker and a 256x256 semi-transparent overlay. | Synthetic |
| `town.osm` | OSM XML 0.6 neighbourhood near 52.37N 4.89E with 1546 nodes, 192 ways and 1 relation. It has a street grid (primary, secondary, residential, footway and bridges), 156 building ways plus a courtyard multipolygon (2 outer ways and 1 inner way), a park, a canal, a pond and 20 POIs. | Synthetic |
| `shapes.wkt` | One WKT per line, 12 lines in Berlin: POINT, POINT Z, LINESTRING, POLYGON with a hole, both MULTIPOINT spellings, MULTILINESTRING, MULTIPOLYGON, GEOMETRYCOLLECTION, POINT EMPTY, an EWKT `SRID=4326;LINESTRING(...)` and LINESTRING Z. | Synthetic |
| `single.wkt` | One MULTIPOLYGON with 3 polygons (2 with holes), spread over several indented lines. | Synthetic |

`scripts/make_large.py OUT.geojson [COUNT]` writes a large synthetic GeoJSON for performance tests. The
default is 100,000 features: about 60% points, 25% lines and 15% polygons over Europe, roughly 25 MB.
Its output does not belong in this folder.

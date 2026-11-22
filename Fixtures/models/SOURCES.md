# 3D model fixtures

Small samples for the models module's tests and visual checks. They are not shipped in the app.

## Generated (CC0)

`generate.py` writes these from code, with no third-party data:

| File | What it exercises |
|---|---|
| `gear.stl` | Binary STL, Z-up, millimetres by convention |
| `ziggurat.stl` | ASCII STL |
| `vase.ply` | Binary PLY with vertex colours and quad faces |
| `pawn/pawn.obj`, `pawn.mtl`, `walnut.png` | OBJ with a material library and a texture beside it |
| `bracket.3mf` | 3MF in millimetres: base materials, per-triangle colours, components and build transforms |
| `icosahedron.off` | OFF with per-face colours |
| `table.3ds` | 3D Studio meshes with materials |
| `primitives.wrl` | VRML 2.0 primitives |
| `tree.vox` | MagicaVoxel (version 150) with a palette |
| `terrain.las` | LAS 1.2, point format 2 (RGB, intensity, classes), metres via GeoTIFF keys |
| `hillside.laz` | LAZ (LAS 1.4, point format 7), compressed with laspy + lazrs when available |
| `knot.pcd` | Binary PCD with packed RGB |
| `lamp.dae` | COLLADA in centimetres, Z-up |
| `windmill.fbx`, `windmill-binary.fbx` | ASCII and binary FBX 7.4 with materials, a hierarchy and a rotation animation |
| `glass.glb` | glTF with a translucent (alpha-blended) dome |
| `hostile/` | Malformed and hostile files for tests |

Run `python3 Fixtures/models/generate.py` to rewrite them. `hillside.laz` needs `pip install laspy lazrs numpy`.

## Khronos glTF Sample Assets

From <https://github.com/KhronosGroup/glTF-Sample-Assets> (Models/…):

| File | Model | Licence |
|---|---|---|
| `fox.glb` | Fox (glTF-Binary): skinned, three animations | CC BY 4.0, © 2014 tomkranis; rig and animation © 2017 @AsoboStudio and @scurest |
| `fox-meshopt.glb` | Fox, repacked with `gltfpack -cc` (meshoptimizer 1.3): EXT_meshopt_compression and quantisation | as above |
| `box-animated.glb` | BoxAnimated (glTF-Binary) | CC BY 4.0, © 2017 Cesium |
| `morph-cube.glb` | AnimatedMorphCube (glTF-Binary): morph targets | CC0 1.0 |
| `box-textured/` | BoxTextured (glTF): separate `.bin` and `.png` beside the `.gltf` | CC BY 4.0, © 2017 Cesium; Cesium logo is a trademark of Cesium |
| `box-ktx2.glb` | BoxTextured, repacked with `gltfpack -tc` (meshoptimizer 1.3, native build): KHR_texture_basisu | as above |
| `milk-truck-draco/` | CesiumMilkTruck (glTF-Draco): KHR_draco_mesh_compression, JPEG texture, animation | CC BY 4.0, © 2017 Cesium; Cesium logo is a trademark of Cesium |

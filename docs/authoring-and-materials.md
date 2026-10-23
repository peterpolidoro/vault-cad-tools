# Authoring new parts, materials metadata and glTF (decisions of 2026-10-23)

Peter's decisions, recorded for every agent working on these projects. They extend the
target workflow in `.agents/PLANS.md` and the synchronisation design in
`native-checkin-adapter-design.md` (section 4, metadata).

## 1. New parts are written as code, open source, Linux first

- An authored part is a small parametric Python program that builds a B-rep solid and
  exports STEP. The program, its parameters file, the STEP it produced and a receipt
  (tool and kernel versions, parameter hash, STEP hash, re-import check) are committed
  together. The program is the source; the STEP is a build artifact that must be
  reproducible from it. Pattern already in use:
  `free-standing-tank-enclosure/designs/reference-models/alienware-aw2725q/build_reference.py`
  (FreeCADCmd, `parameters.json`, nominal envelope).
- Tools, in order of preference today: FreeCAD scripting (Guix `freecad` 1.1.3; the same
  tool validates every import; resolves on Windows through Pixi), then build123d or
  CadQuery (both Apache-2.0, OpenCASCADE through the OCP bindings, concise Python, STEP
  and GLB export, assemblies with hierarchy) once they are available in the managed
  environment. Neither is packaged in Guix yet; the packaging effort is the OCP bindings,
  which are generated against a pinned OpenCASCADE release and must match the OCCT that
  Guix ships (7.9.3 today). Peter intends Guix packages for them, submitted upstream.
  OpenSCAD produces meshes, not B-rep, and is not used for STEP.
- Assemblies are per-part STEP files plus a placement manifest in the shape of the
  exported `scene.json` (occurrence ids, part ids, world transforms, units, up axis),
  never a single monolithic assembly STEP as the source.
- Every authored STEP is re-imported with FreeCAD and compared with the generator's
  expected volume and extents before it is accepted (`import-step` provenance and the
  validation receipts already do this for exported parts).

## 2. Inventor is not an authoring tool

Native authoring over COM is proven (parameters, sketches, extrusions, assemblies,
constraints) and stays available, but it is used only when a collaborator insists on a
native part. Otherwise a repository STEP reaches Inventor users through the reference-model
wrapper route (design document, section 5), which keeps the STEP as the source. No agent
proposes native authoring on its own.

## 3. glTF is derived from STEP on Linux

The documentation pipeline tessellates each STEP with FreeCAD into a GLB and places
instances from the scene transforms; that is the glTF of record for renders and the site
viewer. STEP carries geometry, hierarchy, names and at most face colours (AP214); it carries
no physical or rendering material. Inventor's own glTF export is an optional extra artifact
for a part whose designer appearances or decals matter, or a cross-check of our
tessellation; it is never required.

## 4. Materials: the CAD claim is recorded, the project curates

CAD material data is often absent or wrong (the enclosure snapshot records a McMaster
aluminium T-slot profile as "Zinc" and fourteen parts as "Generic"). The rule mirrors the
quantity rule (CAD counts are never stock): the CAD claim is kept and labelled, and never
silently trusted.

### 4.1 What the Windows exporter records (CAD claim), per part and per body

Added to the export metadata (design document section 4.2, `metadata.json`; the same
values may also appear under `scene.json` `parts[].properties`):

```json
"materials": {
  "<part id>": {
    "iproperty_material": "ALUMINUM, 6061-T651",
    "material_asset": {"name": "...", "library": "...", "density_g_cm3": 2.7, "is_default": false},
    "appearance_asset": {"name": "...", "library": "...", "color_rgba": [0.8, 0.8, 0.82, 1.0]},
    "mass_g": 123.4, "volume_cm3": 45.7, "mass_accuracy": "default",
    "bodies": [{"name": "Solid1", "material_asset": null, "appearance_asset": {"name": "...", "color_rgba": [0, 0, 0, 1]}}]
  }
}
```

Unknown or unreadable values are `null`, never a guess; an Inventor default material
("Generic", "Default") sets `is_default: true`. The exporter does not interpret or correct
anything.

### 4.2 What the project repository keeps (curated), beside the STEP files

`assembly/materials.json` (generated skeleton by `assembly/materials_manifest.py` from the
scene, then edited by people), one row per part:

| Field | Meaning |
| --- | --- |
| `part_id`, `name` | the scene's part identity |
| `cad_claim` | what the export recorded: `material`, `appearance`, `density_g_cm3`, `source`; never edited by hand |
| `material`, `finish`, `mass_basis` | the curated values; `null` until confirmed or corrected |
| `status` | `unknown` (CAD default or empty), `cad_claimed` (claim present, not checked), `confirmed`, `corrected` |
| `evidence`, `decided_by`, `decided_date` | why and who; required for `confirmed` and `corrected` |
| `render.appearance` | the appearance preset used for glTF and renders; `null` means the pipeline's fallback (CAD colour, then a neutral material) |

Consumers (documentation, renders, glTF, purchasing sheets) use the curated value, fall
back to the CAD claim and label it as a claim, and print the claim beside a correction so
the disagreement stays visible. A `confirmed` or `corrected` row with an empty `evidence`
is a validation error.

## 5. Who does what

- Windows exporter: record 4.1 (no interpretation), include it in the incremental export
  dry run so Linux has a real sample; optionally confirm that the glTF translator exists.
- Linux: `materials_manifest.py` in each project (skeleton from the scene, refuses to
  overwrite curated rows), the documentation adapter reads `materials.json` for
  appearances, the lock records the metadata hash with the STEP hashes.
- Documentation pipeline: accept an optional `materials.json` beside the manifests for
  appearances in GLB and renders; print claims as claims.

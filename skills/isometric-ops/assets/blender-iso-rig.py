#!/usr/bin/env python3
# Build a Blender orthographic isometric render rig and (headless) bake N-direction sprites.
#
# Usage:   blender -b -P blender-iso-rig.py -- [OPTIONS]
#          blender    -P blender-iso-rig.py         # GUI: build the rig only, no render
#          python3 blender-iso-rig.py --help        # print this help outside Blender
# Input:   argv after the `--` separator (Blender convention). No stdin.
# Output:  stdout = data only. Rendered PNG paths (one per line), or a `--json` envelope.
# Stderr:  headers, progress, warnings, errors, Blender's own render log.
# Exit:    0 ok, 2 usage, 5 not-inside-Blender (bpy missing) / bad env, 10 nothing rendered.
#
# Canonical rig table (isometric-ops brief — verify against references/blender-prerender.md):
#   Target                     | Camera rotation (X, Y, Z, degrees) | Verification
#   ---------------------------|------------------------------------|--------------------------
#   2:1 dimetric (game tiles)  | 60.000, 0, 45                      | cube top 2x wide as tall
#   true isometric             | 54.736, 0, 45                      | all three cube faces equal
#   The dimetric elevation is 30deg (sin 30 = 0.5 -> 2:1). The true-iso tilt is
#   arctan(sqrt(2)) = 54.7356deg = 90 - 35.264deg. Most tutorials use 60/0/45 and call it
#   "isometric"; it is 2:1 dimetric. This script keeps the two projections distinct.
#
# Examples:
#   blender -b -P blender-iso-rig.py -- --projection dimetric21 --directions 8 --out ./sheet
#   blender -b -P blender-iso-rig.py -- --projection true --directions 4 --resolution 512 --out ./iso
#   blender -b -P blender-iso-rig.py -- --projection dimetric21 --passes --out ./ctrlnet  # +depth +normal for ControlNet
#   blender    -P blender-iso-rig.py -- --projection true       # GUI: build rig, skip render
#
# References:
#   Clint Bellanger, "Isometric Tiles in Blender" (canonical 60/0/45 rig, parented
#     RenderPlatform empty, 8-direction rotation): http://clintbellanger.net/articles/isometric_tiles/
#   Blender Python API (bpy) reference: https://docs.blender.org/api/current/
#   ControlNet depth+normal workflow (RotX 54.736, RotZ 45; Z-pass; camera-space normal):
#     see references/blender-prerender.md and references/ai-generation.md in this skill.

"""Build a Blender orthographic isometric render rig and bake N-direction sprites.

Run this INSIDE Blender:  ``blender -b -P blender-iso-rig.py -- <options>``.
Outside Blender it degrades gracefully: ``python3 blender-iso-rig.py --help`` prints
usage, and any other invocation prints an install/usage hint to stderr and exits 5
(PRECONDITION) rather than crashing with an ``ImportError`` traceback.
"""

import sys
import os
import json
import math
import argparse

# ---------------------------------------------------------------------------
# Constants (must agree with the isometric-ops canonical constants table).
# ---------------------------------------------------------------------------

SCHEMA = "claude-mods.isometric-ops.blender-iso-rig/v1"

# Camera X-rotation per projection, in DEGREES. Z is always 45, Y always 0.
# dimetric21: elevation 30deg above ground -> tilt 60deg from vertical (sin 30 = 0.5 -> 2:1).
# true:       arctan(sqrt(2)) = 54.7356deg -> all three cube faces render equal.
CAMERA_ROT_X_DEG = {
    "dimetric21": 60.0,
    "true": math.degrees(math.atan(math.sqrt(2.0))),  # 54.735610...
}
CAMERA_ROT_Y_DEG = 0.0
CAMERA_ROT_Z_DEG = 45.0

# Semantic exit codes (Skill Resource Protocol section 5).
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_PRECONDITION = 5
EXIT_NOTHING = 10

RENDER_PLATFORM = "RenderPlatform"  # Bellanger's parented pivot-empty name.
CAM_NAME = "IsoCamera"
KEY_LIGHT_NAME = "IsoKeyLight"


# ---------------------------------------------------------------------------
# Argument parsing (Blender passes script args AFTER a lone `--` in argv).
# ---------------------------------------------------------------------------

def _script_argv(argv):
    """Return the args intended for this script.

    Inside Blender, ``blender -b -P script.py -- --projection true`` puts the
    script's own args after a lone ``--``. Outside Blender (plain ``python3``)
    there is usually no ``--``; fall back to everything after argv[0].
    """
    if "--" in argv:
        return argv[argv.index("--") + 1:]
    # Plain `python3 blender-iso-rig.py --help` -> everything past the program name.
    return argv[1:]


def build_parser():
    p = argparse.ArgumentParser(
        prog="blender-iso-rig.py",
        description=(
            "Build a Blender orthographic isometric render rig and (headless) "
            "bake N-direction sprites. Run inside Blender: "
            "blender -b -P blender-iso-rig.py -- <options>"
        ),
        epilog=(
            "EXAMPLES:\n"
            "  blender -b -P blender-iso-rig.py -- --projection dimetric21 --directions 8 --out ./sheet\n"
            "  blender -b -P blender-iso-rig.py -- --projection true --directions 4 --resolution 512 --out ./iso\n"
            "  blender -b -P blender-iso-rig.py -- --projection dimetric21 --passes --out ./ctrlnet\n"
            "  blender    -P blender-iso-rig.py -- --projection true    # GUI: build rig only\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument(
        "--projection",
        choices=("dimetric21", "true"),
        default="dimetric21",
        help=(
            "dimetric21 = 2:1 dimetric game tiles (camera RotX 60), commonly (mis)called "
            "isometric; true = mathematically true isometric (camera RotX 54.736). "
            "Default: dimetric21."
        ),
    )
    p.add_argument(
        "--directions",
        type=int,
        default=8,
        metavar="N",
        help="Number of yaw directions to bake (1-64). Default: 8 (N, NE, E, ...).",
    )
    p.add_argument(
        "--out",
        default=None,
        metavar="DIR",
        help="Output directory for rendered PNGs. Required when rendering (-b). Created if absent.",
    )
    p.add_argument(
        "--resolution",
        type=int,
        default=256,
        metavar="N",
        help="Square render resolution in pixels (16-8192). Default: 256.",
    )
    p.add_argument(
        "--ortho-scale",
        type=float,
        default=None,
        metavar="F",
        help=(
            "Orthographic scale (world units spanned by the frame). Default: auto-fit "
            "the scene bounding sphere with a 10%% margin, or 8.0 for an empty scene."
        ),
    )
    p.add_argument(
        "--distance",
        type=float,
        default=100.0,
        metavar="F",
        help="Camera distance from the pivot along the view axis. Default: 100 (ortho: only sign/clip matter).",
    )
    p.add_argument(
        "--passes",
        action="store_true",
        help=(
            "Also export a normalized depth (Z) pass and a camera-space normal pass per "
            "direction, for ControlNet (depth + normal) conditioning. Requires -b."
        ),
    )
    p.add_argument(
        "--name-prefix",
        default="sprite",
        metavar="STR",
        help="Filename prefix; frames are <prefix>_dir<NN>.png. Default: sprite.",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Emit a JSON envelope on stdout instead of plain paths.",
    )
    return p


def _fail_usage(msg, want_json):
    """Print a USAGE error and exit 2. Structured to stdout under --json, human to stderr."""
    if want_json:
        print(json.dumps({"error": {"code": "USAGE", "message": msg, "details": {}}}))
    print("error: %s" % msg, file=sys.stderr)
    sys.exit(EXIT_USAGE)


# ---------------------------------------------------------------------------
# Rig construction (all bpy access is confined below this line).
# ---------------------------------------------------------------------------

def build_rig(bpy, mathutils, args):
    """Create the ortho camera, parented pivot empty, and a consistent key light.

    Returns (camera_object, pivot_empty_object). Idempotent: reuses objects by
    name so re-running in the same .blend does not stack duplicate rigs.
    """
    scene = bpy.context.scene

    # --- Pivot empty at the world origin (Bellanger's RenderPlatform). -------
    pivot = bpy.data.objects.get(RENDER_PLATFORM)
    if pivot is None:
        pivot = bpy.data.objects.new(RENDER_PLATFORM, None)  # None data => Empty.
        pivot.empty_display_type = "PLAIN_AXES"
        scene.collection.objects.link(pivot)
    pivot.location = (0.0, 0.0, 0.0)
    pivot.rotation_euler = (0.0, 0.0, 0.0)

    # --- Orthographic camera. ------------------------------------------------
    cam_data = bpy.data.cameras.get(CAM_NAME) or bpy.data.cameras.new(CAM_NAME)
    cam_data.type = "ORTHO"
    cam_data.clip_start = 0.001
    cam_data.clip_end = args.distance * 4.0 + 10.0

    cam = bpy.data.objects.get(CAM_NAME)
    if cam is None:
        cam = bpy.data.objects.new(CAM_NAME, cam_data)
        scene.collection.objects.link(cam)
    else:
        cam.data = cam_data

    rot_x = math.radians(CAMERA_ROT_X_DEG[args.projection])
    rot_y = math.radians(CAMERA_ROT_Y_DEG)
    rot_z = math.radians(CAMERA_ROT_Z_DEG)
    cam.rotation_mode = "XYZ"
    cam.rotation_euler = (rot_x, rot_y, rot_z)

    # Place the camera back along its own local -Z (view direction) so the pivot
    # is centred in frame. Ortho render is distance-invariant for scale, but the
    # camera must sit inside [clip_start, clip_end] and in front of the geometry.
    view_dir = mathutils.Vector((0.0, 0.0, -1.0))
    view_dir.rotate(cam.rotation_euler)
    cam.location = -view_dir * args.distance

    cam_data.ortho_scale = _resolve_ortho_scale(bpy, args)

    scene.camera = cam

    # --- One fixed key light (three-tone doctrine: single consistent source). -
    light_data = bpy.data.lights.get(KEY_LIGHT_NAME)
    if light_data is None:
        light_data = bpy.data.lights.new(KEY_LIGHT_NAME, type="SUN")
    light_data.energy = 3.0
    light_data.angle = math.radians(2.0)  # crisp, slightly-soft shadows
    light = bpy.data.objects.get(KEY_LIGHT_NAME)
    if light is None:
        light = bpy.data.objects.new(KEY_LIGHT_NAME, light_data)
        scene.collection.objects.link(light)
    else:
        light.data = light_data
    # Light from upper-front-left, consistent across the whole set. This is a
    # rig default; override in-scene for a bespoke look.
    light.rotation_mode = "XYZ"
    light.rotation_euler = (math.radians(50.0), math.radians(0.0), math.radians(-125.0))

    return cam, pivot


def _resolve_ortho_scale(bpy, args):
    """Pick an orthographic scale: explicit flag, else auto-fit the scene, else 8.0."""
    if args.ortho_scale is not None:
        return max(0.001, args.ortho_scale)

    # Auto-fit: bounding sphere of all renderable meshes, +10% margin.
    radius = 0.0
    center = [0.0, 0.0, 0.0]
    coords = []
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH" or obj.hide_render:
            continue
        mw = obj.matrix_world
        for corner in obj.bound_box:
            wc = mw @ _as_vec(bpy, corner)
            coords.append((wc[0], wc[1], wc[2]))
    if not coords:
        return 8.0  # sensible default for an empty scene (rig-only / cube test).
    for i in range(3):
        lo = min(c[i] for c in coords)
        hi = max(c[i] for c in coords)
        center[i] = (lo + hi) / 2.0
    for c in coords:
        d = math.sqrt(sum((c[i] - center[i]) ** 2 for i in range(3)))
        radius = max(radius, d)
    return max(0.5, radius * 2.0 * 1.1)


def _as_vec(bpy, corner):
    """bound_box corners are already Vector-like; wrap defensively for old builds."""
    from mathutils import Vector
    return Vector((corner[0], corner[1], corner[2]))


def configure_render(bpy, args):
    """Square render, transparent film, PNG RGBA output."""
    scene = bpy.context.scene
    r = scene.render
    r.resolution_x = args.resolution
    r.resolution_y = args.resolution
    r.resolution_percentage = 100
    r.film_transparent = True
    r.image_settings.file_format = "PNG"
    r.image_settings.color_mode = "RGBA"
    r.image_settings.color_depth = "8"


# ---------------------------------------------------------------------------
# Optional ControlNet passes: normalized depth + camera-space normal.
# ---------------------------------------------------------------------------

# Node names for the pass-export graph, so re-runs find and reuse them instead
# of stacking duplicate nodes into the compositor tree.
DEPTH_OUTPUT_NODE = "IsoDepthOutput"
NORMAL_OUTPUT_NODE = "IsoNormalOutput"
DEPTH_SUBDIR = "depth"
NORMAL_SUBDIR = "normal"


def enable_controlnet_passes(bpy, out_dir):
    """Wire a compositor graph that writes a normalized-depth pass and a
    camera-space normal pass to their OWN files, via dedicated File Output
    nodes, WITHOUT touching the beauty render.

    The scene's ``Composite`` node (the beauty pass that
    ``render.render(write_still=True)`` saves to ``scene.render.filepath``) is
    left entirely alone — the depth/normal maps go to separate
    ``CompositorNodeOutputFile`` nodes writing under ``<out_dir>/depth`` and
    ``<out_dir>/normal``. This is additive: any existing user graph is
    preserved; we only add (or reuse-by-name) the Render-Layers source and the
    two File Output nodes.

    Depth: Render-Layers ``Depth`` -> Normalize -> depth File Output (grayscale
    Z, [0,1]).
    Normal: Render-Layers ``Normal`` (world space) -> Vector Transform
    (World -> Camera) -> Multiply-Add mapping [-1,1] -> [0,1] -> normal File
    Output (camera-space normal, ControlNet-ready).

    Returns (depth_node, normal_node) on success — the File Output nodes whose
    per-direction ``base_path``/slot filename is set in the render loop — or
    ``(None, None)`` on best-effort failure (warned to stderr).
    """
    scene = bpy.context.scene
    try:
        vl = scene.view_layers[0]
        vl.use_pass_z = True
        vl.use_pass_normal = True
    except Exception as exc:  # pragma: no cover - depends on Blender build
        print("warning: could not enable Z/Normal passes: %s" % exc, file=sys.stderr)
        return (None, None)

    try:
        scene.use_nodes = True
        tree = scene.node_tree

        # Reuse a Render-Layers node if the tree already has one (default scenes
        # ship with Render-Layers + Composite); otherwise add one. Never gate on
        # an empty tree — a headless scene's tree is NOT empty.
        rl = None
        for node in tree.nodes:
            if node.bl_idname == "CompositorNodeRLayers":
                rl = node
                break
        if rl is None:
            rl = tree.nodes.new("CompositorNodeRLayers")

        # --- Depth branch: RL.Depth -> Normalize -> File Output (grayscale). --
        depth_out = tree.nodes.get(DEPTH_OUTPUT_NODE)
        if depth_out is None:
            depth_out = tree.nodes.new("CompositorNodeOutputFile")
            depth_out.name = DEPTH_OUTPUT_NODE
            depth_out.label = "Iso Depth (Z)"
        depth_out.format.file_format = "PNG"
        depth_out.format.color_mode = "BW"
        depth_out.format.color_depth = "16"

        if "Depth" in rl.outputs:
            norm = tree.nodes.new("CompositorNodeNormalize")  # depth -> [0,1]
            tree.links.new(rl.outputs["Depth"], norm.inputs[0])
            tree.links.new(norm.outputs[0], depth_out.inputs[0])
        else:
            print("warning: Render-Layers has no 'Depth' output; depth pass skipped",
                  file=sys.stderr)
            depth_out = None

        # --- Normal branch: RL.Normal (world) -> World->Camera -> *0.5+0.5. ---
        normal_out = tree.nodes.get(NORMAL_OUTPUT_NODE)
        if normal_out is None:
            normal_out = tree.nodes.new("CompositorNodeOutputFile")
            normal_out.name = NORMAL_OUTPUT_NODE
            normal_out.label = "Iso Normal (camera-space)"
        normal_out.format.file_format = "PNG"
        normal_out.format.color_mode = "RGB"
        normal_out.format.color_depth = "16"

        if "Normal" in rl.outputs:
            # World-space normals -> camera space so the map is view-consistent.
            vt = tree.nodes.new("CompositorNodeVecTransform")
            vt.vector_type = "NORMAL"
            vt.convert_from = "WORLD"
            vt.convert_to = "CAMERA"
            tree.links.new(rl.outputs["Normal"], vt.inputs[0])

            # Remap components from [-1,1] to [0,1] (n * 0.5 + 0.5) so the PNG is
            # a standard ControlNet normal map. MixRGB MULTIPLY then ADD on the
            # Vector; use a Mix node pair operating on the vector as color.
            mul = tree.nodes.new("CompositorNodeMixRGB")
            mul.blend_type = "MULTIPLY"
            mul.inputs[0].default_value = 1.0
            mul.inputs[2].default_value = (0.5, 0.5, 0.5, 1.0)
            tree.links.new(vt.outputs[0], mul.inputs[1])

            add = tree.nodes.new("CompositorNodeMixRGB")
            add.blend_type = "ADD"
            add.inputs[0].default_value = 1.0
            add.inputs[2].default_value = (0.5, 0.5, 0.5, 1.0)
            tree.links.new(mul.outputs[0], add.inputs[1])
            tree.links.new(add.outputs[0], normal_out.inputs[0])
        else:
            print("warning: Render-Layers has no 'Normal' output; normal pass skipped",
                  file=sys.stderr)
            normal_out = None

    except Exception as exc:  # pragma: no cover
        print("warning: compositor pass graph not created: %s" % exc, file=sys.stderr)
        return (None, None)

    return (depth_out, normal_out)


# ---------------------------------------------------------------------------
# Rendering.
# ---------------------------------------------------------------------------

def _outfile_slot_path(out_node):
    """Return the single slot object of a File Output node across Blender API
    variants (``file_slots`` on modern builds; ``layer_slots`` for multilayer)."""
    slots = getattr(out_node, "file_slots", None)
    if slots is not None and len(slots) > 0:
        return slots[0]
    return None


def render_directions(bpy, args, out_dir, depth_out=None, normal_out=None):
    """Render one PNG per yaw direction by rotating the pivot empty.

    Rotating the RenderPlatform (which parents the geometry, in practice) yaws
    the subject under a fixed camera — the Bellanger technique. Here the pivot
    is at origin; parent scene geometry to it in your .blend for it to spin.

    When ``--passes`` wired the depth/normal File Output nodes, this points each
    at a per-direction file under ``<out_dir>/depth`` and ``<out_dir>/normal``
    before every render, so the ControlNet maps land alongside the beauty
    sprite WITHOUT overwriting it (the beauty PNG still comes from
    ``scene.render.filepath`` via the untouched Composite node).

    Returns ``(beauty_paths, depth_paths, normal_paths)`` — the depth/normal
    lists are empty unless the corresponding pass node was wired.
    """
    import mathutils  # noqa: F401  (kept for symmetry / future transforms)

    scene = bpy.context.scene
    pivot = bpy.data.objects[RENDER_PLATFORM]

    depth_dir = os.path.join(out_dir, DEPTH_SUBDIR)
    normal_dir = os.path.join(out_dir, NORMAL_SUBDIR)
    if depth_out is not None:
        os.makedirs(depth_dir, exist_ok=True)
        depth_out.base_path = depth_dir
    if normal_out is not None:
        os.makedirs(normal_dir, exist_ok=True)
        normal_out.base_path = normal_dir

    # File Output nodes always append the current frame number to the slot path.
    # Pin the frame so that suffix is a stable, predictable ``0001`` we can
    # resolve back to a concrete on-disk path for the JSON meta.
    frame_no = scene.frame_current
    frame_suffix = "%04d" % frame_no

    n = args.directions
    written = []
    depth_written = []
    normal_written = []
    for i in range(n):
        yaw = (2.0 * math.pi) * (i / float(n))
        pivot.rotation_euler = (0.0, 0.0, yaw)

        frame_path = os.path.join(out_dir, "%s_dir%02d.png" % (args.name_prefix, i))
        scene.render.filepath = frame_path

        # Point each pass File Output at this direction's file. Blender appends
        # the frame number, so slot path "sprite_dir00_" yields
        # "sprite_dir00_0001.png"; record that resolved path.
        depth_path = None
        normal_path = None
        if depth_out is not None:
            slot = _outfile_slot_path(depth_out)
            stem = "%s_dir%02d_" % (args.name_prefix, i)
            if slot is not None:
                slot.path = stem
            depth_path = os.path.abspath(
                os.path.join(depth_dir, stem + frame_suffix + ".png"))
        if normal_out is not None:
            slot = _outfile_slot_path(normal_out)
            stem = "%s_dir%02d_" % (args.name_prefix, i)
            if slot is not None:
                slot.path = stem
            normal_path = os.path.abspath(
                os.path.join(normal_dir, stem + frame_suffix + ".png"))

        # write_still renders and saves in one call; no GUI required under -b.
        # The File Output nodes write their pass PNGs as a side effect of the
        # same render; the beauty PNG comes from scene.render.filepath.
        bpy.ops.render.render(write_still=True)

        written.append(os.path.abspath(frame_path))
        print("rendered %s" % frame_path, file=sys.stderr)
        if depth_path is not None:
            depth_written.append(depth_path)
            print("  depth  %s" % depth_path, file=sys.stderr)
        if normal_path is not None:
            normal_written.append(normal_path)
            print("  normal %s" % normal_path, file=sys.stderr)

    # Reset pivot so re-runs / GUI inspection start clean.
    pivot.rotation_euler = (0.0, 0.0, 0.0)
    return written, depth_written, normal_written


# ---------------------------------------------------------------------------
# Output.
# ---------------------------------------------------------------------------

def emit(args, cam_rot_x_deg, ortho_scale, rendered,
         depth_paths=None, normal_paths=None):
    """Write the data product to stdout per the stream-separation contract.

    ``data`` is the beauty-sprite path list. When ``--passes`` produced depth
    and/or camera-space normal maps, their concrete file paths are reported
    under ``meta.passes`` (a mapping) so a downstream ControlNet step can find
    them — not a bare ``true``.
    """
    depth_paths = depth_paths or []
    normal_paths = normal_paths or []
    if args.json:
        if args.passes:
            passes_meta = {
                "enabled": True,
                "depth": depth_paths,
                "normal": normal_paths,
            }
        else:
            passes_meta = {"enabled": False, "depth": [], "normal": []}
        envelope = {
            "data": rendered,
            "meta": {
                "count": len(rendered),
                "schema": SCHEMA,
                "projection": args.projection,
                "camera_rotation_deg": {
                    "x": round(cam_rot_x_deg, 4),
                    "y": CAMERA_ROT_Y_DEG,
                    "z": CAMERA_ROT_Z_DEG,
                },
                "directions": args.directions,
                "resolution": args.resolution,
                "ortho_scale": round(ortho_scale, 4),
                "passes": passes_meta,
            },
        }
        print(json.dumps(envelope, indent=2))
    else:
        for path in rendered:
            print(path)
        for path in depth_paths:
            print(path)
        for path in normal_paths:
            print(path)


# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

def main():
    parser = build_parser()
    script_args = _script_argv(sys.argv)

    # Parse. argparse exits 2 on bad args and prints to stderr; that matches the
    # protocol's USAGE code, so let it handle --help / errors for the CLI itself.
    args = parser.parse_args(script_args)

    if args.directions < 1 or args.directions > 64:
        _fail_usage("--directions must be between 1 and 64", args.json)
    if args.resolution < 16 or args.resolution > 8192:
        _fail_usage("--resolution must be between 16 and 8192", args.json)

    # --- Are we inside Blender? ---------------------------------------------
    try:
        import bpy
        import mathutils
    except ImportError:
        msg = (
            "this script must run inside Blender: "
            "blender -b -P blender-iso-rig.py -- --projection dimetric21 --out ./sheet\n"
            "install Blender from https://www.blender.org/download/ "
            "(the bundled Python provides the 'bpy' module)."
        )
        if args.json:
            print(json.dumps({"error": {"code": "PRECONDITION", "message":
                "not running inside Blender (bpy unavailable)", "details": {}}}))
        print("error: " + msg, file=sys.stderr)
        sys.exit(EXIT_PRECONDITION)

    # --- Build the rig (always). --------------------------------------------
    cam, pivot = build_rig(bpy, mathutils, args)
    cam_rot_x_deg = CAMERA_ROT_X_DEG[args.projection]
    ortho_scale = cam.data.ortho_scale
    print(
        "rig built: projection=%s  camera RotX=%.4f RotY=%.1f RotZ=%.1f  ortho_scale=%.4f"
        % (args.projection, cam_rot_x_deg, CAMERA_ROT_Y_DEG, CAMERA_ROT_Z_DEG, ortho_scale),
        file=sys.stderr,
    )

    # --- Headless mode renders; GUI mode (no -b) just builds the rig. --------
    if not bpy.app.background:
        print(
            "GUI mode (no -b): rig built, skipping render. "
            "Parent your geometry to '%s' and re-run headless to bake sprites." % RENDER_PLATFORM,
            file=sys.stderr,
        )
        emit(args, cam_rot_x_deg, ortho_scale, [])
        sys.exit(EXIT_OK)

    # Headless render path requires an output directory.
    if not args.out:
        _fail_usage("--out DIR is required when rendering (-b headless mode)", args.json)

    out_dir = os.path.abspath(args.out)
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as exc:
        if args.json:
            print(json.dumps({"error": {"code": "PRECONDITION",
                "message": "cannot create --out directory", "details": {"path": out_dir}}}))
        print("error: cannot create output directory %s: %s" % (out_dir, exc), file=sys.stderr)
        sys.exit(EXIT_PRECONDITION)

    configure_render(bpy, args)
    depth_out = normal_out = None
    if args.passes:
        depth_out, normal_out = enable_controlnet_passes(bpy, out_dir)

    rendered, depth_paths, normal_paths = render_directions(
        bpy, args, out_dir, depth_out=depth_out, normal_out=normal_out)

    emit(args, cam_rot_x_deg, ortho_scale, rendered,
         depth_paths=depth_paths, normal_paths=normal_paths)

    if not rendered:
        print("warning: no frames were rendered", file=sys.stderr)
        sys.exit(EXIT_NOTHING)
    sys.exit(EXIT_OK)


if __name__ == "__main__":
    main()

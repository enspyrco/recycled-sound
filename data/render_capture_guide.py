"""Capture-guide renders from the CC-BY BTE model.

Fixed 3/4 hero camera; the MODEL rotates in clean 90-degree steps (on a pivot,
root parented so the glTF Y-up->Z-up conversion survives) to bring each
anatomical face toward the camera. Style: flat bold Emission fills + thick
Freestyle outlines + transparent film (matches the existing transparent PNGs).

MODE=hero  -> one settled frame per slot (verify mapping + look)
MODE=anim  -> N frames per slot swinging into the hero pose (the animation)
"""
import bpy, math, os
from mathutils import Vector, Quaternion

GLTF = "/Users/nick/Downloads/454ec7a8a7c74094b2edc206f917e384/scene.gltf"
MODE = os.environ.get("MODE", "hero")
STYLE = os.environ.get("STYLE", "real")   # 'real' = native PBR materials; 'cartoon' = flat+outline
OUT = os.environ.get("OUT", "/tmp/aid_hero")
NFRAMES = int(os.environ.get("NFRAMES", "10"))
os.makedirs(OUT, exist_ok=True)

# ── Clean slate + import ────────────────────────────────────────────────
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=GLTF)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']

# Combined world bounds (before we add a pivot)
mins = Vector((1e9,)*3); maxs = Vector((-1e9,)*3)
for o in meshes:
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c)
        for i in range(3):
            mins[i] = min(mins[i], w[i]); maxs[i] = max(maxs[i], w[i])
center = (mins + maxs) / 2
maxdim = max(maxs - mins)

# ── Pivot at centre; parent the glTF ROOT (not meshes) ──────────────────
pivot = bpy.data.objects.new('Pivot', None)
bpy.context.collection.objects.link(pivot)
pivot.location = center
root = bpy.data.objects.get('Sketchfab_model') or bpy.data.objects.get('Root')
if root is not None:
    # keep world transform when parenting
    root.parent = pivot
    root.matrix_parent_inverse = pivot.matrix_world.inverted()
pivot.rotation_mode = 'QUATERNION'

# ── Material treatment ──────────────────────────────────────────────────
if STYLE == 'cartoon':
    # Flat bold emission per material (Simpsons-ish fill).
    def boost(c):
        mx = max(c[0], c[1], c[2], 1e-4); s = 0.9 / mx
        return (min(c[0]*s,1), min(c[1]*s,1), min(c[2]*s,1), 1)
    for mat in bpy.data.materials:
        mat.use_nodes = True
        nt = mat.node_tree
        base = (0.82, 0.78, 0.62, 1)
        for n in nt.nodes:
            if n.type == 'BSDF_PRINCIPLED' and n.inputs.get('Base Color'):
                base = tuple(n.inputs['Base Color'].default_value)
        nt.nodes.clear()
        out = nt.nodes.new('ShaderNodeOutputMaterial')
        emi = nt.nodes.new('ShaderNodeEmission')
        emi.inputs['Color'].default_value = boost(base)
        nt.links.new(emi.outputs['Emission'], out.inputs['Surface'])
# else 'real': leave the native PBR materials untouched.

# ── Render settings ─────────────────────────────────────────────────────
scene = bpy.context.scene
try: scene.render.engine = 'BLENDER_EEVEE'
except Exception: scene.render.engine = 'BLENDER_EEVEE_NEXT'
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = 512

if STYLE == 'cartoon':
    scene.view_settings.view_transform = 'Standard'
    scene.render.use_freestyle = True
    vl = scene.view_layers[0]; vl.use_freestyle = True
    ls = vl.freestyle_settings.linesets[0]
    if ls.linestyle is None:
        ls.linestyle = bpy.data.linestyles.new('outline')
    ls.linestyle.color = (0, 0, 0); ls.linestyle.thickness = 4.0
else:
    # Realistic: filmic-ish tone, raytraced reflections, a studio world the
    # metals can reflect (otherwise metallic surfaces render black).
    scene.view_settings.view_transform = 'AgX'
    try:
        scene.eevee.use_raytracing = True
    except Exception:
        pass
    world = bpy.data.worlds.new('Studio') if not bpy.data.worlds else bpy.data.worlds[0]
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get('Background')
    if bg:
        bg.inputs['Color'].default_value = (0.62, 0.64, 0.7, 1)
        bg.inputs['Strength'].default_value = 0.8

# ── Fixed 3/4 hero camera ───────────────────────────────────────────────
cam_data = bpy.data.cameras.new('Cam'); cam_data.type = 'ORTHO'
cam_data.ortho_scale = maxdim * 1.7
cam = bpy.data.objects.new('Cam', cam_data)
bpy.context.collection.objects.link(cam); scene.camera = cam
hero_dir = Vector((0.0, 1.0, 0.0)).normalized()   # flat-on: the rest pose is the clear target
cam.location = center + hero_dir * maxdim * 4
# up = world Z (looking along -Y makes a Y-up degenerate, per the Track-To lesson)
cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Z').to_euler()

_key_e, _fill_e = (1.0, 0.0) if STYLE == 'cartoon' else (3.0, 1.0)
sun_d = bpy.data.lights.new('Sun', 'SUN'); sun_d.energy = _key_e
sun_d.angle = math.radians(8)   # soft-ish specular
sun = bpy.data.objects.new('Sun', sun_d); bpy.context.collection.objects.link(sun)
sun.rotation_euler = (math.radians(50), math.radians(15), math.radians(10))
if _fill_e:
    fd = bpy.data.lights.new('Fill', 'SUN'); fd.energy = _fill_e
    fo = bpy.data.objects.new('Fill', fd); bpy.context.collection.objects.link(fo)
    fo.rotation_euler = (math.radians(65), math.radians(-25), math.radians(200))

# ── Per-slot target pose: a clean quarter-turn bringing each face to the
#    +Y "front" that the hero camera principally sees. ────────────────────
Z = Vector((0, 0, 1)); X = Vector((1, 0, 0))
POSES = {
    'medial':    Quaternion(),                    # +Y broad face (brand label)
    'lateral':   Quaternion(Z, math.pi),          # -Y broad face
    'anterior':  Quaternion(Z, -math.pi/2),       # +X edge -> front
    'posterior': Quaternion(Z,  math.pi/2),       # -X edge -> front
    'superior':  Quaternion(X, -math.pi/2),       # +Z end (hook) -> front
    'inferior':  Quaternion(X,  math.pi/2),       # -Z end (battery) -> front
    'scale':     Quaternion(Z, math.pi),          # reuse lateral; widget adds card
}
# Tumble-in: the aid starts turned away (3/4, showing depth) and rotates
# flat-on to the rest pose, so the MOTION shows where it ends up.
SWING = Quaternion(Z, math.radians(55)) @ Quaternion(X, math.radians(28))

def render_to(path):
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)

if MODE == 'hero':
    for slot, q in POSES.items():
        pivot.rotation_quaternion = q
        render_to(os.path.join(OUT, f"{slot}.png"))
        print("HERO", slot)
else:
    for slot, end in POSES.items():
        start = SWING @ end
        for f in range(NFRAMES):
            t = f / (NFRAMES - 1)
            t = 1 - (1 - t) * (1 - t)              # ease-out
            pivot.rotation_quaternion = start.slerp(end, t)
            render_to(os.path.join(OUT, f"{slot}_{f:02d}.png"))
        print("ANIM", slot)
print("DONE", MODE)

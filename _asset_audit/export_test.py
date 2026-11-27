import bpy, sys, json
src, dst = sys.argv[sys.argv.index("--")+1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=src, use_anim=True)
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
print("@@ actions before:", [a.name for a in bpy.data.actions])
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB",
    export_animations=True, export_animation_mode="ACTIONS",
    export_nla_strips=False, export_anim_single_armature=True,
    export_apply=False, export_yup=True)
print("@@ exported", dst)

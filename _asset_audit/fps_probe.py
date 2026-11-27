import bpy, sys, json
p=sys.argv[sys.argv.index("--")+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.render.fps=30
bpy.ops.import_scene.fbx(filepath=p, use_anim=True)
out=[{"n":a.name,"r":list(a.frame_range)} for a in bpy.data.actions]
print("@@JSON@@"+json.dumps(out))

import bpy, bmesh, sys
from mathutils import Vector
p=sys.argv[sys.argv.index("--")+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=p)
for ob in bpy.data.objects:
    if ob.type!="MESH" or ob.name=="Icosphere": continue
    bm=bmesh.new(); bm.from_mesh(ob.data); bm.verts.ensure_lookup_table()
    seen=set(); islands=[]
    for v in bm.verts:
        if v.index in seen: continue
        stack=[v]; comp=[]
        seen.add(v.index)
        while stack:
            cur=stack.pop(); comp.append(cur)
            for e in cur.link_edges:
                o=e.other_vert(cur)
                if o.index not in seen:
                    seen.add(o.index); stack.append(o)
        lo=Vector((1e9,)*3); hi=Vector((-1e9,)*3)
        for c in comp:
            w=ob.matrix_world@c.co
            lo=Vector((min(lo[i],w[i]) for i in range(3))); hi=Vector((max(hi[i],w[i]) for i in range(3)))
        islands.append((len(comp),tuple(round(x,2) for x in (hi-lo)),tuple(round(x,1) for x in ((lo+hi)/2))))
    islands.sort(reverse=True)
    print(f"@@ {ob.name}: {len(islands)} islands")
    for isl in islands[:8]: print("@@   ",isl)

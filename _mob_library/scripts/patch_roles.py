import json,struct,glob,os
ROOT=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def read(p):
    with open(p,'rb') as f:
        magic,ver,length=struct.unpack('<III',f.read(12)); chunks=[]
        while f.tell()<length:
            clen,ct=struct.unpack('<II',f.read(8)); chunks.append([ct,f.read(clen)])
    return ver,chunks
def write(p,ver,chunks):
    body=b''.join(struct.pack('<II',len(d),ct)+d for ct,d in chunks)
    with open(p,'wb') as f:
        f.write(struct.pack('<III',0x46546C67,ver,12+len(body))); f.write(body)
def rename(p,mapping):
    ver,chunks=read(p); ji=next(i for i,(ct,d) in enumerate(chunks) if ct==0x4E4F534A)
    doc=json.loads(chunks[ji][1].decode())
    changed=[]
    for a in doc['animations']:
        if a['name'] in mapping:
            changed.append((a['name'],mapping[a['name']])); a['name']=mapping[a['name']]
    data=json.dumps(doc,separators=(',',':'),ensure_ascii=False).encode(); data+=b' '*((-len(data))%4)
    chunks[ji][1]=data; write(p,ver,chunks)
    return changed
for p in glob.glob(os.path.join(ROOT,'assets/models/mob_monsters/mech*.glb')):
    print(p,rename(p,{'HitRecieve_1':'hit'}))
p=os.path.join(ROOT,'assets/models/mob_monsters/zombie_xqez.glb')
print(p,rename(p,{'Running_Crawl':'run'}))
sel=json.load(open(os.path.join(ROOT,'_mob_library/scripts/selection.json')))
for x in sel:
    if x['slug'].startswith('mech'):
        x['roles']['hit']='hit'; x['clips']=[('hit' if c=='HitRecieve_1' else c) for c in x['clips']]
    if x['slug']=='zombie_xqez':
        x['roles']['run']='run'; x['clips']=[('run' if c=='Running_Crawl' else c) for c in x['clips']]
json.dump(sel,open(os.path.join(ROOT,'_mob_library/scripts/selection.json'),'w'),indent=1)

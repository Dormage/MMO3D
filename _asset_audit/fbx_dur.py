import struct, sys

class R:
    def __init__(s,b): s.b=b; s.p=0
    def u8(s): v=s.b[s.p]; s.p+=1; return v
    def u32(s): v=struct.unpack_from('<I',s.b,s.p)[0]; s.p+=4; return v
    def u64(s): v=struct.unpack_from('<Q',s.b,s.p)[0]; s.p+=8; return v
    def take(s,n): v=s.b[s.p:s.p+n]; s.p+=n; return v

def props(r,n,total_len):
    end=r.p+total_len; out=[]
    for _ in range(n):
        t=chr(r.u8())
        if t=='Y': out.append(struct.unpack_from('<h',r.b,r.p)[0]); r.p+=2
        elif t=='C': out.append(bool(r.u8()))
        elif t=='I': out.append(struct.unpack_from('<i',r.b,r.p)[0]); r.p+=4
        elif t=='F': out.append(struct.unpack_from('<f',r.b,r.p)[0]); r.p+=4
        elif t=='D': out.append(struct.unpack_from('<d',r.b,r.p)[0]); r.p+=8
        elif t=='L': out.append(struct.unpack_from('<q',r.b,r.p)[0]); r.p+=8
        elif t in 'fdlib':
            ln,enc,cl=struct.unpack_from('<III',r.b,r.p); r.p+=12; r.p+=cl
        elif t in 'SR':
            ln=struct.unpack_from('<I',r.b,r.p)[0]; r.p+=4; out.append(r.take(ln))
        else: raise ValueError(t)
    assert r.p==end, (r.p,end)
    return out

def node(r,ver):
    if ver>=7500: end,np,pl=r.u64(),r.u64(),r.u64()
    else: end,np,pl=r.u32(),r.u32(),r.u32()
    nl=r.u8()
    if end==0: return None
    name=r.take(nl).decode('utf8','replace')
    ps=props(r,np,pl)
    ch=[]
    while r.p<end:
        c=node(r,ver)
        if c is None: break
        ch.append(c)
    r.p=end
    return (name,ps,ch)

def find(nodes,name):
    for n in nodes:
        if n[0]==name: yield n
        yield from find(n[2],name)

for path in sys.argv[1:]:
    d=open(path,'rb').read(); ver=struct.unpack_from('<I',d,23)[0]
    r=R(d); r.p=27
    top=[]
    while r.p<len(d):
        n=node(r,ver)
        if n is None: break
        top.append(n)
    print("==",path.split('/')[-1], "ver",ver)
    for st in find(top,'AnimationStack'):
        nm = next((x.decode('utf8','replace') for x in st[1] if isinstance(x,(bytes,bytearray))), '?')
        vals={}
        for pnode in find(st[2],'P'):
            key=pnode[1][0].decode() if pnode[1] else ''
            if key in ('LocalStart','LocalStop'):
                vals[key]=pnode[1][-1]
        if vals:
            print(f"   {nm:40s} start={vals.get('LocalStart')} stop={vals.get('LocalStop')} "
                  f"dur={(vals['LocalStop']-vals['LocalStart'])/46186158000 if 'LocalStop' in vals and 'LocalStart' in vals else '?'}")

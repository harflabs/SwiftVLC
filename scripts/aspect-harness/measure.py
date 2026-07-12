import sys, json
from PIL import Image

# SURFACE = non-light-gray bbox in the band. PICTURE = extent of non-black content
# along the surface's center column (vertical) and center row (horizontal). Center
# cross avoids rounded-corner anti-aliasing. Robust to centered letterbox/pillarbox.
path = sys.argv[1]; y0 = int(sys.argv[2]); y1 = int(sys.argv[3])
im = Image.open(path).convert("RGB"); W, H = im.size; px = im.load()
def lightgray(r,g,b): return r>228 and g>228 and b>228
def black(r,g,b):     return max(r,g,b) < 40

# surface bbox = non-light-gray within band
bx0,by0,bx1,by1 = W,y1,0,y0; found=False
for y in range(max(0,y0),min(H,y1)):
    for x in range(W):
        if not lightgray(*px[x,y]):
            found=True
            bx0=min(bx0,x); bx1=max(bx1,x); by0=min(by0,y); by1=max(by1,y)
surface=(bx0,by0,bx1-bx0+1,by1-by0+1) if found else None

def content_run_v(xs, ytop, ybot):
    top,bot=None,None
    for y in range(ytop,ybot+1):
        if any(not black(*px[x,y]) and not lightgray(*px[x,y]) for x in xs):
            if top is None: top=y
            bot=y
    return top,bot
def content_run_h(ys, xl, xr):
    left,right=None,None
    for x in range(xl,xr+1):
        if any(not black(*px[x,y]) and not lightgray(*px[x,y]) for y in ys):
            if left is None: left=x
            right=x
    return left,right

picture=None
if surface:
    sx,sy,sw,sh=surface
    cx=sx+sw//2; cy=sy+sh//2
    xs=[cx-8,cx,cx+8]; ys=[cy-8,cy,cy+8]
    top,bot=content_run_v(xs, sy, sy+sh-1)
    left,right=content_run_h(ys, sx, sx+sw-1)
    if None not in (top,bot,left,right):
        picture=(left,top,right-left+1,bot-top+1)

def ar(r): return round(r[2]/r[3],3) if r and r[3] else None
print(json.dumps({"surface":surface,"surface_ar":ar(surface),
                  "picture":picture,"picture_ar":ar(picture)}))

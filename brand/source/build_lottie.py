import math, copy, json, sys
from lottie import objects, Point, Color
from lottie.objects import easing
from lottie.exporters.core import export_lottie

S = 5.12               # 100-unit design space -> 512 px
FPS = 60
INK, GRAPE, LILAC, WHITE, BLUSH, MINT = "1B1633","5B3FD9","A794FF","FFFFFF","FFA8CF","43D9A3"

def col(h): return Color(*(int(h[i:i+2],16)/255 for i in (0,2,4)))
def P(x,y): return Point(x*S, y*S)
def ease(): return easing.Sigmoid()

def rot90(p, k):
    x,y = p
    for _ in range(k): x,y = 100-y, x
    return (x,y)
def rotv(v, k):
    dx,dy = v
    for _ in range(k): dx,dy = -dy, dx
    return (dx,dy)

def stroke(h, w):
    s = objects.Stroke(col(h), w*S)
    s.line_cap = objects.LineCap.Round
    s.line_join = objects.LineJoin.Round
    return s

def group(name, anchor=(0,0)):
    g = objects.Group()
    g.name = name
    g.transform.anchor_point.value = P(*anchor)
    g.transform.position.value = P(*anchor)
    return g

def path_shape(pts):
    """pts: list of (pos, in, out) in design units"""
    b = objects.Bezier()
    for pos,i,o in pts:
        b.add_point(P(*pos), Point(i[0]*S,i[1]*S), Point(o[0]*S,o[1]*S))
    sh = objects.Path(); sh.shape.value = b
    return sh

def quad_path(p0, c, p1):
    # quadratic -> cubic handles
    i0 = ((c[0]-p0[0])*2/3, (c[1]-p0[1])*2/3)
    i1 = ((c[0]-p1[0])*2/3, (c[1]-p1[1])*2/3)
    return path_shape([(p0,(0,0),i0),(p1,i1,(0,0))])

class Mascot:
    """All features exist in every file; animations toggle opacity/scale/position."""
    def __init__(self, bracket=GRAPE, badge=False, frames=120):
        self.an = objects.Animation(frames, FPS)
        self.an.width = self.an.height = 512
        self.an.name = "Shotsy"
        layer = objects.ShapeLayer(); layer.name = "Shotsy"
        layer.in_point, layer.out_point = 0, frames
        self.an.add_layer(layer)
        self.body = group("Body", (50,50))
        if badge:
            # keep the face well inside the badge so pops and spreads never cross its edge
            holder = group("Holder", (50,50)); holder.transform.scale.value = Point(78,78)
            holder.add_shape(self.body); layer.add_shape(holder)
        else:
            layer.add_shape(self.body)

        # top-most first
        self.sparkle = group("Sparkle", (90,10))
        sp = []
        for a,r in [(0,7),(45,2.8),(90,7),(135,2.8),(180,7),(225,2.8),(270,7),(315,2.8)]:
            t = math.radians(a-90); sp.append(((90+r*math.cos(t), 10+r*math.sin(t)),(0,0),(0,0)))
        s = path_shape(sp); s.shape.value.closed = True
        self.sparkle.add_shape(s); self.sparkle.add_shape(objects.Fill(col(MINT)))
        self.sparkle.transform.opacity.value = 0

        self.mouth_smile = group("Smile", (50,61))
        self.mouth_smile.add_shape(quad_path((43,58),(50,65),(57,58))); self.mouth_smile.add_shape(stroke(INK,4.5))
        self.mouth_big = group("BigSmile", (50,61))
        self.mouth_big.add_shape(quad_path((41,56),(50,67),(59,56))); self.mouth_big.add_shape(stroke(INK,4.5))
        self.mouth_big.transform.opacity.value = 0
        self.mouth_o = group("MouthO", (50,64))
        self.mouth_o.add_shape(objects.Ellipse(P(50,64), P(9,11))); self.mouth_o.add_shape(objects.Fill(col(INK)))
        self.mouth_o.transform.opacity.value = 0

        self.happy = group("HappyEyes", (50,46))
        self.happy.add_shape(quad_path((34,49),(40,41),(46,49)))
        self.happy.add_shape(quad_path((54,49),(60,41),(66,49)))
        self.happy.add_shape(stroke(INK,4.5)); self.happy.transform.opacity.value = 0
        self.wink_eye = group("WinkEye", (60,48))
        self.wink_eye.add_shape(quad_path((55,47),(60,51),(65,47))); self.wink_eye.add_shape(stroke(INK,4.5))
        self.wink_eye.transform.opacity.value = 0

        self.eyes = group("Eyes", (50,47))
        self.eyeL = self._eye("EyeLeft", 40); self.eyeR = self._eye("EyeRight", 60)
        self.eyes.add_shape(self.eyeL); self.eyes.add_shape(self.eyeR)

        self.blush = group("Blush", (50,58))
        for x in (31,69): self.blush.add_shape(objects.Ellipse(P(x,58), P(10,6)))
        self.blush.add_shape(objects.Fill(col(BLUSH)))

        self.brackets = []
        tl = [((20,38),(0,0),(0,0)), ((20,28),(0,0),(0,-4.418)), ((28,20),(-4.418,0),(0,0)), ((38,20),(0,0),(0,0))]
        for k,name in enumerate(["TopLeft","TopRight","BottomRight","BottomLeft"]):
            g = group("Bracket"+name)
            pts = [(rot90(p,k), rotv(i,k), rotv(o,k)) for p,i,o in tl]
            g.add_shape(path_shape(pts)); bs = stroke(bracket,7); bs.name = "BracketStroke"; g.add_shape(bs)
            self.brackets.append(g)
        self.bracket_dirs = [(-1,-1),(1,-1),(1,1),(-1,1)]

        for g in [self.sparkle, self.mouth_smile, self.mouth_big, self.mouth_o, self.happy,
                  self.wink_eye, self.eyes, self.blush] + self.brackets:
            self.body.add_shape(g)

        if badge:
            bg = group("Badge", (50,50))
            r = objects.Rect(P(50,50), P(100,100)); r.rounded.value = 22.5*S
            bg.add_shape(r); bf = objects.Fill(col(LILAC)); bf.name = "BadgeFill"; bg.add_shape(bf)
            layer.add_shape(bg)   # after body = drawn underneath

    def _eye(self, name, cx):
        g = group(name, (cx,47))
        hi = group(name+"Highlight"); hi.add_shape(objects.Ellipse(P(cx+1.8,44.6), P(3.4,3.4))); hi.add_shape(objects.Fill(col(WHITE)))
        ball = group(name+"Ball"); ball.add_shape(objects.Ellipse(P(cx,47), P(10,13))); ball.add_shape(objects.Fill(col(INK)))
        g.add_shape(hi); g.add_shape(ball)
        return g

    # keyframe helpers: list of (frame, value)
    @staticmethod
    def key(prop, kfs, conv=lambda v: v):
        for f,v in kfs: prop.add_keyframe(f, conv(v), ease())

    def scale(self, g, kfs):      self.key(g.transform.scale, kfs, lambda v: Point(v[0],v[1]) if isinstance(v,tuple) else Point(v,v))
    def opacity(self, g, kfs):    self.key(g.transform.opacity, kfs)
    def rotate(self, g, kfs):     self.key(g.transform.rotation, kfs)
    def move(self, g, kfs, base=(50,50)):
        self.key(g.transform.position, kfs, lambda d: P(base[0]+d[0], base[1]+d[1]))
    def spread(self, kfs):
        for g,(dx,dy) in zip(self.brackets, self.bracket_dirs):
            self.key(g.transform.position, kfs, lambda d,dx=dx,dy=dy: P(dx*d, dy*d))

    def blink(self, at, which=None):
        for e in (which or [self.eyeL, self.eyeR]):
            self.scale(e, [(at,(100,100)),(at+5,(100,8)),(at+11,(100,100))])

    def save(self, path): export_lottie(self.an, path)

# ---------- animations ----------
def idle(**kw):
    m = Mascot(frames=180, **kw)
    m.move(m.body, [(0,(0,0)),(90,(0,-1.6)),(180,(0,0))])
    m.scale(m.body, [(0,100),(90,(101.5,98.5)),(180,100)])
    for e in (m.eyeL, m.eyeR):
        m.scale(e, [(0,(100,100)),(104,(100,100)),(109,(100,8)),(115,(100,100)),(180,(100,100))])
    return m

def whoa(**kw):
    m = Mascot(frames=72, **kw)
    m.scale(m.body, [(0,90),(9,112),(20,97),(30,100),(72,100)])
    m.spread([(0,0),(9,6.5),(20,3.5),(30,4),(72,4)])
    m.scale(m.eyes, [(0,100),(9,140),(20,124),(30,128),(72,128)])
    m.opacity(m.mouth_smile, [(0,100),(5,0),(72,0)])
    m.opacity(m.mouth_o, [(0,0),(5,100),(72,100)])
    m.scale(m.mouth_o, [(0,20),(10,125),(22,95),(30,100),(72,100)])
    return m

def tidy(**kw):
    m = Mascot(frames=96, **kw)
    m.opacity(m.eyes, [(0,100),(6,0),(96,0)])
    m.opacity(m.happy, [(0,0),(6,100),(96,100)])
    m.opacity(m.mouth_smile, [(0,100),(6,0),(96,0)])
    m.opacity(m.mouth_big, [(0,0),(6,100),(96,100)])
    m.scale(m.body, [(0,100),(8,(110,90)),(20,(95,106)),(34,(108,92)),(44,(97,103)),(54,100),(96,100)])
    m.move(m.body, [(0,(0,0)),(8,(0,2)),(20,(0,-9)),(34,(0,0)),(96,(0,0))])
    m.opacity(m.sparkle, [(0,0),(18,0),(24,100),(96,100)])
    m.scale(m.sparkle, [(0,0),(18,0),(30,140),(40,100),(96,100)])
    m.rotate(m.sparkle, [(0,0),(18,0),(60,90),(96,90)])
    return m

def wink(**kw):
    m = Mascot(frames=66, **kw)
    m.scale(m.eyeR, [(0,(100,100)),(8,(100,8)),(46,(100,8)),(54,(100,100)),(66,(100,100))])
    m.opacity(m.eyeR, [(0,100),(8,100),(9,0),(45,0),(46,100),(66,100)])
    m.opacity(m.wink_eye, [(0,0),(8,0),(9,100),(45,100),(46,0),(66,0)])
    m.rotate(m.body, [(0,0),(12,-7),(40,-7),(56,0),(66,0)])
    m.opacity(m.mouth_smile, [(0,100),(66,100)])
    return m

def hello(**kw):
    """Pop-in entrance, ends in the idle pose."""
    m = Mascot(frames=54, **kw)
    m.scale(m.body, [(0,0),(16,112),(28,94),(38,102),(46,100),(54,100)])
    m.rotate(m.body, [(0,-12),(16,4),(30,0),(54,0)])
    m.spread([(0,-6),(16,2),(28,0),(54,0)])
    m.blink(34)
    return m

if __name__ == "__main__":
    out = sys.argv[1]
    for name,fn in [("idle",idle),("hello",hello),("whoa",whoa),("tidy",tidy),("wink",wink)]:
        fn().save(f"{out}/shotsy-{name}.json")
        fn(bracket=WHITE, badge=True).save(f"{out}/shotsy-{name}-badge.json")
    print("ok")

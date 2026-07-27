import math

# Mirror of skySHBasis() and the sc2_sky_sh projection, verbatim.
def basis(d):
    x,y,z = d
    return [0.282095,
            0.488603*y, 0.488603*z, 0.488603*x,
            1.092548*x*y, 1.092548*y*z,
            0.315392*(3.0*z*z-1.0),
            1.092548*x*z, 0.546274*(x*x-y*y)]

def fib(i,n):
    k = i+0.5
    cosT = 1.0-2.0*k/n
    sinT = math.sqrt(max(0.0,1.0-cosT*cosT))
    phi  = math.pi*(1.0+math.sqrt(5.0))*k
    return (math.cos(phi)*sinT, cosT, math.sin(phi)*sinT)

N = 32*16   # SKY_SH_THREADS * SKY_SH_PER_THREAD
w = 4.0*math.pi/N

def project(f):
    L=[0.0]*9
    for i in range(N):
        d=fib(i,N); v=f(d); Y=basis(d)
        for k in range(9): L[k]+=v*Y[k]*w
    return L

def evaluate(L,d):
    Y=basis(d); return sum(L[k]*Y[k] for k in range(9))

# Test 1: a CONSTANT sky must reconstruct exactly -- this is the normalization
# check. If the 4*pi/N weight or Y00 were wrong, this comes back scaled.
L=project(lambda d: 1.0)
vals=[evaluate(L,fib(i,N)) for i in range(0,N,37)]
print(f"const sky=1.0  -> recon min={min(vals):.6f} max={max(vals):.6f}  (want 1.0)")

# Test 2: uniform-direction sampling must integrate to 4*pi.
print(f"solid angle sum = {N*w:.6f}  (want {4*math.pi:.6f})")

# Test 3: a sky/ground step, the real worst case for L2.
def step(d): return 1.0 if d[1] > 0.0 else 0.15
L=project(step)
up   = evaluate(L,(0,1,0)); down = evaluate(L,(0,-1,0))
horiz= evaluate(L,(1,0,0))
mn = min(evaluate(L,fib(i,N)) for i in range(N))
print(f"step sky: up={up:.3f} (true 1.0)  down={down:.3f} (true 0.15)  horizon={horiz:.3f}")
print(f"  min over sphere = {mn:.3f}  -> {'clamp needed' if mn<0 else 'no ringing below zero'}")

# Test 4: energy. Mean radiance over the sphere must be preserved -- this is what
# would shift overall GI brightness if the projection were wrong.
true_mean = sum(step(fib(i,N)) for i in range(N))/N
sh_mean   = sum(evaluate(L,fib(i,N)) for i in range(N))/N
print(f"mean radiance: true={true_mean:.4f}  sh={sh_mean:.4f}  err={abs(sh_mean-true_mean)/true_mean*100:.3f}%")

print("\n--- cosine-weighted hemisphere integral (what the gather actually estimates) ---")
import random
random.seed(1)
def cos_integral(f, n, samples=200000):
    # cosine-weighted mean of f over the hemisphere about n
    ax = (0,0,1) if abs(n[1])>0.9 else (0,1,0)
    t = (ax[1]*n[2]-ax[2]*n[1], ax[2]*n[0]-ax[0]*n[2], ax[0]*n[1]-ax[1]*n[0])
    L=math.sqrt(sum(c*c for c in t)); t=tuple(c/L for c in t)
    b=(n[1]*t[2]-n[2]*t[1], n[2]*t[0]-n[0]*t[2], n[0]*t[1]-n[1]*t[0])
    s=0.0
    for _ in range(samples):
        u1,u2=random.random(),random.random()
        r=math.sqrt(u1); th=2*math.pi*u2
        x,y=r*math.cos(th), r*math.sin(th); z=math.sqrt(max(0.0,1-u1))
        d=tuple(x*t[i]+y*b[i]+z*n[i] for i in range(3))
        s+=f(d)
    return s/samples

for name,nrm in [("floor (up)",(0,1,0)),("wall (side)",(1,0,0)),
                 ("ceiling (down)",(0,-1,0)),("45 deg",(0.707,0.707,0))]:
    tv = cos_integral(step, nrm)
    sv = cos_integral(lambda d: max(evaluate(L,d),0.0), nrm)
    print(f"  {name:16s} true={tv:.4f}  sh(clamped)={sv:.4f}  err={(sv-tv)/tv*100:+.1f}%")

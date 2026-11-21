"""Engine test-suite: builds the assembly engine as a DLL and checks it with ctypes.

Run:  python tests/test_engine.py
"""
import ctypes, math, os, subprocess, sys, tempfile, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(tempfile.gettempdir(), "asmcalc_engine_test.dll")
subprocess.check_call(["gcc", "-shared", "-nostdlib", "-Wl,-e,DllMain", "-o", OUT,
                       os.path.join(ROOT, "src", "engine.s"),
                       os.path.join(ROOT, "tests", "shim.s")])
dll = ctypes.CDLL(OUT)
dll.calc_eval.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint64]

# friendly text -> engine tokens
SUBS = [("sin(", "S("), ("cos(", "C("), ("tan(", "T("), ("log(", "L("), ("ln(", "N("),
        ("sqrt(", "Q("), ("root", "R"), ("pi", "P"), ("ans", "A")]

def ev(expr, deg=True, ans=0.0):
    for a, b in SUBS:
        expr = expr.replace(a, b)
    buf = ctypes.create_string_buffer(64)
    bits = struct.unpack("<Q", struct.pack("<d", ans))[0]
    ok = dll.calc_eval(expr.encode(), buf, 1 if deg else 0, bits)
    return buf.value.decode() if ok else None

fails = 0
def check(expr, expected, **kw):
    global fails
    got = ev(expr, **kw)
    if got != expected:
        fails += 1
        print(f"FAIL  {expr!r:28} got {got!r}  expected {expected!r}")
    else:
        print(f"ok    {expr!r:28} = {got}")

def fmt(x):  # reference formatter: 15 significant digits, same notation rules
    if x == 0: return "0"
    s = f"{x:.14e}"; m, e = s.split("e"); e = int(e)
    m = m.rstrip("0").rstrip(".") if "." in m else m
    if -6 <= e <= 14:
        return f"{x:.{max(0, 14 - e)}f}".rstrip("0").rstrip(".") if "." in f"{x:.{max(0,14-e)}f}" else f"{x:.0f}"
    return f"{m}e{'+' if e >= 0 else '-'}{abs(e)}"

# arithmetic & precedence
check("1+2", "3"); check("7-10", "-3"); check("6*7", "42"); check("1/4", "0.25")
check("0.1+0.2", "0.3"); check("2+3*4", "14"); check("(2+3)*4", "20"); check("10-4-3", "3")
check("100/10/5", "2"); check("-2^2", "-4"); check("2^-2", "0.25"); check("2^3^2", "512")
check("2^10", "1024"); check("3^4", "81"); check("10^-3", "0.001"); check("2^0.5", "1.4142135623731")
check("2pi", "6.28318530717959"); check("3(4+1)", "15"); check("(2)(3)", "6"); check("--5", "5")
check("1/3", "0.333333333333333"); check("123456789*1000", "123456789000")
check("1e", None); check(".", None); check("1/0", None); check("2+", None); check("(2+3", "5"); check("2+3)", None)
check("5ans", "15", ans=3.0); check("ans*2", "7", ans=3.5)
# factorial
check("0!", "1"); check("5!", "120"); check("10!", "3628800"); check("20!", "2.43290200817664e+18")
check("3!^2", "36"); check("2^3!", "64"); check("(-1)!", None); check("2.5!", None); check("171!", None)
check("170!", "7.257415615308e+306")
# roots / sqrt
check("sqrt(16)", "4"); check("sqrt(2)", "1.4142135623731"); check("sqrt(-1)", None)
check("3root27", "3"); check("3root-8", "-2"); check("4root16", "2"); check("2root81", "9"); check("0root5", None)
check("2root-4", None); check("sqrt(0)", "0")
# logs
check("log(1000)", "3"); check("log(0.001)", "-3"); check("ln(1)", "0"); check("ln(e)", None)
check("log(0)", None); check("ln(-1)", None); check("log(2)", "0.301029995663981")
# trig degrees
check("sin(30)", "0.5"); check("cos(60)", "0.5"); check("sin(90)", "1"); check("cos(90)", "0")
check("sin(180)", "0"); check("cos(180)", "-1"); check("tan(45)", "1"); check("tan(90)", None)
check("sin(-30)", "-0.5"); check("sin(390)", "0.5"); check("tan(135)", "-1"); check("cos(0)", "1")
check("sin(270)", "-1"); check("tan(0)", "0")
# trig radians
check("sin(pi/2)", "1", deg=False); check("cos(pi)", "-1", deg=False); check("sin(pi)", "0", deg=False)
check("tan(pi/4)", "1", deg=False); check("cos(pi/2)", "0", deg=False); check("sin(1)", "0.841470984807897", deg=False)

# randomised comparison against Python's math module (relative error 1e-13)
import random
random.seed(7)
def close(a, b): return abs(a - b) <= 1e-13 * max(1.0, abs(b))
bad = 0
for _ in range(3000):
    x = random.uniform(-1000, 1000); y = random.uniform(0.01, 50)
    xs, ys = repr(round(x, 6)), repr(round(y, 6)); x = float(xs); y = float(ys)
    cases = [(f"{xs}+{ys}", x + y), (f"{xs}*{ys}", x * y), (f"{xs}/{ys}", x / y),
             (f"sin({xs})", math.sin(math.radians(x))), (f"cos({xs})", math.cos(math.radians(x))),
             (f"log({ys})", math.log10(y)), (f"ln({ys})", math.log(y)), (f"sqrt({ys})", math.sqrt(y)),
             (f"{ys}^1.5", y ** 1.5), (f"3root{ys}", y ** (1 / 3))]
    for e, ref in cases:
        got = ev(e)
        if got is None:
            bad += 1; print("ERR ", e); continue
        # compare the 15-digit rendering against the reference rendering
        if not close(float(got), ref):
            bad += 1; print(f"MISMATCH {e}: {got} vs {ref!r}")
    if bad > 15: break
fails += bad
print("\nrandom comparison:", "clean" if bad == 0 else f"{bad} problems")
print("RESULT:", "ALL PASSED" if fails == 0 else f"{fails} FAILED")
sys.exit(1 if fails else 0)

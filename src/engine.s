# ============================================================================
#  engine.s  -  calculator engine (parser, maths, number formatting)
#
#  x86-64, GNU as, Intel syntax.  No C runtime, no libm, no OS calls.
#
#  Public API (custom register convention, documented per routine):
#     engine_init                      one-time setup (FPU control word, tables)
#     eval_expr   rcx = expr           -> eax = 1 ok / 0 error, xmm0 = value
#     fmt_double  xmm0 = v, rcx = buf  -> NUL-terminated ASCII, 15 significant digits
#     g_deg       byte: 1 = degrees, 0 = radians
#
#  Expression alphabet (one byte per token):
#     0-9 . + - * / ^ ( ) !        literal characters
#     S C T                        sin cos tan   (always followed by '(')
#     L N                          log10 ln      (always followed by '(')
#     Q                            square root   (always followed by '(')
#     R                            infix n-th root:  n R x  ==  x^(1/n)
#     P E A                        pi, e, previous answer
#
#  Grammar (precedence low -> high):
#     expr    := term   (('+'|'-') term)*
#     term    := unary  (('*'|'/')? unary)*         implicit multiplication
#     unary   := ('-'|'+') unary | power
#     power   := postfix (('^'|'R') unary)?         right associative
#     postfix := primary '!'*
#     primary := number | const | '(' expr ')'? | FUNC '(' expr ')'?
#
#  Internal convention of the parser: r12 = cursor into the expression (shared
#  by every parse_* routine), xmm0 = value returned, x87 stack empty between
#  operations.  Values are doubles; transcendentals run on the x87 in 64-bit
#  precision and are rounded once on the way out.
# ============================================================================
        .intel_syntax noprefix
        .globl  engine_init, eval_expr, fmt_double, g_deg

# ---------------------------------------------------------------- constants
        .section .rdata,"dr"
        .balign 16
c_absmask:  .quad   0x7FFFFFFFFFFFFFFF, 0
c_signmask: .quad   0x8000000000000000, 0
c_one:      .double 1.0
c_two:      .double 2.0
c_pi:       .double 3.141592653589793
c_e:        .double 2.718281828459045
c_1e15:     .double 1.0e15
c_1em3:     .double 1.0e-3
c_1em15:    .double 1.0e-15
c_fcw:      .word   0x037F              # x87: 64-bit precision, round-nearest, all masked
c_ten:      .word   10
c_90:       .word   90
c_neg90:    .word   -90
c_180:      .word   180
s_primset:  .asciz  "0123456789.(SCTLNQPEA"

        .data
g_deg:      .byte   1

        .bss
        .balign 16
g_err:          .skip 1
g_primstart:    .skip 256               # 1 for every byte that can start a primary

# ====================================================================== text
        .text

# ---------------------------------------------------------------------------
# engine_init: set the x87 control word and build the "starts a primary" table
# ---------------------------------------------------------------------------
engine_init:
        fldcw   word ptr [rip + c_fcw]
        lea     rdx, [rip + g_primstart]
        lea     rcx, [rip + s_primset]
1:      movzx   eax, byte ptr [rcx]
        test    eax, eax
        jz      2f
        mov     byte ptr [rdx + rax], 1
        inc     rcx
        jmp     1b
2:      ret

# ---------------------------------------------------------------------------
# eval_expr: rcx = NUL-terminated token string
#            returns eax = 1 (ok) / 0 (error), xmm0 = result
# ---------------------------------------------------------------------------
eval_expr:
        push    r12
        sub     rsp, 32
        mov     r12, rcx
        mov     byte ptr [rip + g_err], 0
        call    parse_expr
        cmp     byte ptr [r12], 0               # unconsumed input (stray ')')
        jne     .ee_fail
        cmp     byte ptr [rip + g_err], 0
        jne     .ee_fail
        movq    rax, xmm0                       # reject NaN / +-Inf
        shr     rax, 52
        and     eax, 0x7FF
        cmp     eax, 0x7FF
        je      .ee_fail
        mov     eax, 1
        jmp     .ee_ret
.ee_fail:
        xor     eax, eax
.ee_ret:
        add     rsp, 32
        pop     r12
        ret

# ------------------------------------------------------------------- parser
parse_expr:
        sub     rsp, 24
        call    parse_term
.pe_loop:
        movzx   eax, byte ptr [r12]
        cmp     al, '+'
        je      .pe_add
        cmp     al, '-'
        je      .pe_sub
        add     rsp, 24
        ret
.pe_add:
        inc     r12
        movsd   qword ptr [rsp], xmm0
        call    parse_term
        addsd   xmm0, qword ptr [rsp]
        jmp     .pe_loop
.pe_sub:
        inc     r12
        movsd   qword ptr [rsp], xmm0
        call    parse_term
        movsd   xmm1, xmm0
        movsd   xmm0, qword ptr [rsp]
        subsd   xmm0, xmm1
        jmp     .pe_loop

parse_term:
        sub     rsp, 24
        call    parse_unary
.pt_loop:
        movzx   eax, byte ptr [r12]
        cmp     al, '*'
        je      .pt_mul
        cmp     al, '/'
        je      .pt_div
        lea     rdx, [rip + g_primstart]
        cmp     byte ptr [rdx + rax], 0         # implicit multiplication: 2pi, 3(4), 2sin(x)
        je      .pt_ret
        movsd   qword ptr [rsp], xmm0
        call    parse_unary
        mulsd   xmm0, qword ptr [rsp]
        jmp     .pt_loop
.pt_mul:
        inc     r12
        movsd   qword ptr [rsp], xmm0
        call    parse_unary
        mulsd   xmm0, qword ptr [rsp]
        jmp     .pt_loop
.pt_div:
        inc     r12
        movsd   qword ptr [rsp], xmm0
        call    parse_unary
        xorps   xmm2, xmm2
        ucomisd xmm0, xmm2
        jp      1f
        jne     1f
        mov     byte ptr [rip + g_err], 1       # division by zero
        xorps   xmm0, xmm0
        add     rsp, 24
        ret
1:      movsd   xmm1, xmm0
        movsd   xmm0, qword ptr [rsp]
        divsd   xmm0, xmm1
        jmp     .pt_loop
.pt_ret:
        add     rsp, 24
        ret

parse_unary:
        movzx   eax, byte ptr [r12]
        cmp     al, '-'
        je      .pu_neg
        cmp     al, '+'
        je      .pu_pos
        jmp     parse_power                     # tail call
.pu_neg:
        inc     r12
        sub     rsp, 8
        call    parse_unary
        add     rsp, 8
        xorpd   xmm0, xmmword ptr [rip + c_signmask]
        ret
.pu_pos:
        inc     r12
        jmp     parse_unary

parse_power:
        sub     rsp, 24
        call    parse_postfix
        movzx   eax, byte ptr [r12]
        cmp     al, '^'
        je      .pw_pow
        cmp     al, 'R'
        je      .pw_root
        add     rsp, 24
        ret
.pw_pow:
        inc     r12
        movsd   qword ptr [rsp], xmm0
        call    parse_unary                     # right associative, allows 2^-3
        movsd   xmm1, xmm0
        movsd   xmm0, qword ptr [rsp]
        add     rsp, 24
        jmp     do_pow                          # x = xmm0, y = xmm1
.pw_root:
        inc     r12
        movsd   qword ptr [rsp], xmm0           # n
        call    parse_unary                     # x
        movsd   xmm1, qword ptr [rsp]
        add     rsp, 24
        jmp     do_root                         # x = xmm0, n = xmm1

parse_postfix:
        sub     rsp, 8
        call    parse_primary
1:      cmp     byte ptr [r12], '!'
        jne     2f
        inc     r12
        call    do_fact
        jmp     1b
2:      add     rsp, 8
        ret

parse_primary:
        sub     rsp, 24
        movzx   eax, byte ptr [r12]
        lea     ecx, [rax - '0']
        cmp     ecx, 9
        jbe     .pp_num
        cmp     al, '.'
        je      .pp_num
        cmp     al, '('
        je      .pp_paren
        cmp     al, 'P'
        je      .pp_pi
        cmp     al, 'E'
        je      .pp_e
        cmp     al, 'A'
        je      .pp_ans
        cmp     al, 'S'
        je      .pp_func
        cmp     al, 'C'
        je      .pp_func
        cmp     al, 'T'
        je      .pp_func
        cmp     al, 'L'
        je      .pp_func
        cmp     al, 'N'
        je      .pp_func
        cmp     al, 'Q'
        je      .pp_func
.pp_err:
        mov     byte ptr [rip + g_err], 1
        xorps   xmm0, xmm0
        add     rsp, 24
        ret
.pp_num:
        add     rsp, 24
        jmp     parse_number
.pp_pi:
        inc     r12
        movsd   xmm0, qword ptr [rip + c_pi]
        add     rsp, 24
        ret
.pp_e:
        inc     r12
        movsd   xmm0, qword ptr [rip + c_e]
        add     rsp, 24
        ret
.pp_ans:
        inc     r12
        movsd   xmm0, qword ptr [rip + g_ans]
        add     rsp, 24
        ret
.pp_paren:
        inc     r12
        call    parse_expr
        cmp     byte ptr [r12], ')'             # a missing ')' at the end is tolerated
        jne     1f
        inc     r12
1:      add     rsp, 24
        ret
.pp_func:
        mov     byte ptr [rsp + 8], al
        inc     r12
        cmp     byte ptr [r12], '('
        jne     .pp_err
        inc     r12
        call    parse_expr
        cmp     byte ptr [r12], ')'
        jne     1f
        inc     r12
1:      movzx   eax, byte ptr [rsp + 8]
        add     rsp, 24
        cmp     al, 'S'
        je      do_sin
        cmp     al, 'C'
        je      do_cos
        cmp     al, 'T'
        je      do_tan
        cmp     al, 'L'
        je      do_log10
        cmp     al, 'N'
        je      do_ln
        jmp     do_sqrt

# number := digits ['.' digits]
# mantissa and decimal scale are accumulated in 64-bit x87 precision (exact up
# to 19 digits), then divided once, so "0.1" is the correctly rounded double.
parse_number:
        sub     rsp, 24
        fldz                                    # m
        fld1                                    # scale   (st0 = scale, st1 = m)
        xor     ecx, ecx                        # digit count
        xor     edx, edx                        # seen '.'
.pn_loop:
        movzx   eax, byte ptr [r12]
        cmp     al, '.'
        jne     1f
        test    edx, edx
        jnz     .pn_done
        mov     edx, 1
        inc     r12
        jmp     .pn_loop
1:      sub     eax, '0'
        cmp     eax, 9
        ja      .pn_done
        inc     r12
        inc     ecx
        mov     dword ptr [rsp], eax
        fxch    st(1)
        fimul   word ptr [rip + c_ten]
        fiadd   dword ptr [rsp]
        fxch    st(1)
        test    edx, edx
        jz      .pn_loop
        fimul   word ptr [rip + c_ten]
        jmp     .pn_loop
.pn_done:
        test    ecx, ecx
        jnz     1f
        mov     byte ptr [rip + g_err], 1       # lone '.'
1:      fxch    st(1)                           # st0 = m, st1 = scale
        fdiv    st(0), st(1)
        fstp    qword ptr [rsp + 8]
        fstp    st(0)
        movsd   xmm0, qword ptr [rsp + 8]
        add     rsp, 24
        ret

# ------------------------------------------------------------ maths kernels
# do_sqrt: xmm0 = x
do_sqrt:
        xorps   xmm1, xmm1
        ucomisd xmm1, xmm0
        ja      .err0                           # x < 0
        sqrtsd  xmm0, xmm0
        ret

.err0:  mov     byte ptr [rip + g_err], 1
        xorps   xmm0, xmm0
        ret

# do_log10 / do_ln: xmm0 = x  (x > 0)
.macro LOGFN name, constant
\name:
        sub     rsp, 24
        xorps   xmm1, xmm1
        ucomisd xmm0, xmm1
        jbe     1f
        movsd   qword ptr [rsp], xmm0
        \constant
        fld     qword ptr [rsp]
        fyl2x                                   # log2(x) * const
        fstp    qword ptr [rsp]
        movsd   xmm0, qword ptr [rsp]
        add     rsp, 24
        ret
1:      add     rsp, 24
        jmp     .err0
.endm
        LOGFN do_log10, fldlg2
        LOGFN do_ln, fldln2

# do_fact: xmm0 = n, integer in [0,170]
do_fact:
        sub     rsp, 24
        cvttsd2si eax, xmm0
        cvtsi2sd xmm1, eax
        ucomisd xmm1, xmm0
        jne     .df_err
        jp      .df_err
        cmp     eax, 170
        ja      .df_err
        fld1
        mov     ecx, 2
.df_loop:
        cmp     ecx, eax
        ja      .df_done
        mov     dword ptr [rsp], ecx
        fild    dword ptr [rsp]
        fmulp   st(1), st(0)
        inc     ecx
        jmp     .df_loop
.df_done:
        fstp    qword ptr [rsp]
        movsd   xmm0, qword ptr [rsp]
        add     rsp, 24
        ret
.df_err:
        add     rsp, 24
        jmp     .err0

# do_pow: xmm0 = x, xmm1 = y  ->  x^y
#   integer y : binary exponentiation in 64-bit x87 precision (exact for 2^10, 3^4 ...)
#   other y   : 2^(y*log2 x)  via fyl2x / f2xm1 / fscale,  x > 0 only
do_pow:
        sub     rsp, 40
        movsd   qword ptr [rsp], xmm0
        movsd   qword ptr [rsp + 8], xmm1
        xorps   xmm2, xmm2
        ucomisd xmm1, xmm2
        jp      .dp_err
        jne     1f
        movsd   xmm0, qword ptr [rip + c_one]   # y == 0
        add     rsp, 40
        ret
1:      ucomisd xmm0, xmm2
        jp      .dp_err
        jne     .dp_xnz
        ucomisd xmm1, xmm2                      # x == 0: only y > 0 is defined
        jb      .dp_err
        add     rsp, 40
        ret
.dp_xnz:
        cvttsd2si rax, xmm1
        cvtsi2sd xmm3, rax
        ucomisd xmm3, xmm1
        jne     .dp_frac
        jp      .dp_frac
        mov     rdx, rax                        # |y|, sign mask
        sar     rdx, 63
        xor     rax, rdx
        sub     rax, rdx
        cmp     rax, 0x7FFFFFFF
        ja      .dp_frac
        mov     qword ptr [rsp + 16], rdx
        fld1                                    # result
        fld     qword ptr [rsp]                 # base
.dp_bin:
        test    al, 1
        jz      1f
        fmul    st(1), st(0)                    # result *= base
1:      shr     rax, 1
        jz      .dp_bdone
        fmul    st(0), st(0)                    # base *= base
        jmp     .dp_bin
.dp_bdone:
        fstp    st(0)
        fstp    qword ptr [rsp + 24]
        movsd   xmm0, qword ptr [rsp + 24]
        cmp     qword ptr [rsp + 16], 0
        je      .dp_ret
        movsd   xmm1, xmm0                      # negative exponent: 1 / x^|y|
        movsd   xmm0, qword ptr [rip + c_one]
        divsd   xmm0, xmm1
.dp_ret:
        add     rsp, 40
        ret
.dp_frac:
        xorps   xmm2, xmm2
        ucomisd xmm0, xmm2
        jbe     .dp_err                         # negative base, fractional exponent
        fld     qword ptr [rsp + 8]             # y
        fld     qword ptr [rsp]                 # x
        fyl2x                                   # L = y*log2(x)
        fld     st(0)
        frndint                                 # I, L
        fxch    st(1)                           # L, I
        fsub    st(0), st(1)                    # F = L - I
        f2xm1
        fld1
        faddp   st(1), st(0)                    # 2^F
        fscale                                  # 2^F * 2^I
        fstp    st(1)
        fstp    qword ptr [rsp + 24]
        movsd   xmm0, qword ptr [rsp + 24]
        add     rsp, 40
        ret
.dp_err:
        add     rsp, 40
        jmp     .err0

# do_root: xmm0 = x, xmm1 = n  ->  n-th root of x
#   x < 0 is allowed only for odd integer n  (cbrt(-8) = -2)
do_root:
        sub     rsp, 24
        xorps   xmm2, xmm2
        ucomisd xmm1, xmm2
        jp      .dr_err
        je      .dr_err                         # n == 0
        movsd   xmm3, qword ptr [rip + c_two]
        ucomisd xmm1, xmm3
        jp      1f
        jne     1f
        add     rsp, 24                         # n == 2: hardware sqrt
        jmp     do_sqrt
1:      ucomisd xmm0, xmm2
        jae     .dr_pos
        cvttsd2si rax, xmm1                     # x < 0 -> n must be odd integer
        cvtsi2sd xmm3, rax
        ucomisd xmm3, xmm1
        jne     .dr_err
        jp      .dr_err
        test    al, 1
        jz      .dr_err
        andpd   xmm0, xmmword ptr [rip + c_absmask]
        movsd   xmm4, qword ptr [rip + c_one]
        divsd   xmm4, xmm1
        movsd   xmm1, xmm4
        call    do_pow
        xorpd   xmm0, xmmword ptr [rip + c_signmask]
        add     rsp, 24
        ret
.dr_pos:
        movsd   xmm4, qword ptr [rip + c_one]
        divsd   xmm4, xmm1
        movsd   xmm1, xmm4
        add     rsp, 24
        jmp     do_pow
.dr_err:
        add     rsp, 24
        jmp     .err0

# trig_sc: xmm0 = angle (degrees if g_deg else radians) -> xmm0 = sin, xmm1 = cos
#   degrees : k = round(x/90), r = x - 90k (exact), sincos(r) then rotate by k
#             quadrants, so sin(180) = 0 and cos(90) = 0 exactly
#   radians : x87 fsincos; results below 1e-15 for |x| > 1e-3 are snapped to 0
trig_sc:
        sub     rsp, 40
        movsd   qword ptr [rsp], xmm0
        cmp     byte ptr [rip + g_deg], 0
        je      .ts_rad
        movapd  xmm2, xmm0
        andpd   xmm2, xmmword ptr [rip + c_absmask]
        ucomisd xmm2, qword ptr [rip + c_1e15]
        ja      .ts_err
        jp      .ts_err
        fld     qword ptr [rsp]
        fidiv   word ptr [rip + c_90]
        frndint                                 # k
        fld     st(0)
        fistp   qword ptr [rsp + 8]
        fimul   word ptr [rip + c_neg90]        # -90k
        fadd    qword ptr [rsp]                 # r = x - 90k
        fldpi
        fmulp   st(1), st(0)
        fidiv   word ptr [rip + c_180]          # r in radians
        fsincos
        fstp    qword ptr [rsp + 16]            # cos r
        fstp    qword ptr [rsp + 24]            # sin r
        mov     rax, qword ptr [rsp + 8]
        movsd   xmm0, qword ptr [rsp + 24]
        movsd   xmm1, qword ptr [rsp + 16]
        test    al, 1
        jz      1f
        movaps  xmm2, xmm0                      # odd quadrant: swap sin <-> cos
        movaps  xmm0, xmm1
        movaps  xmm1, xmm2
1:      mov     ecx, eax
        shr     ecx, 1
        test    cl, 1                           # sin negative in quadrants 2,3
        jz      2f
        xorpd   xmm0, xmmword ptr [rip + c_signmask]
2:      xor     ecx, eax                        # cos negative in quadrants 1,2
        and     ecx, 1
        jz      3f
        xorpd   xmm1, xmmword ptr [rip + c_signmask]
3:      add     rsp, 40
        ret
.ts_rad:
        fld     qword ptr [rsp]
        fsincos
        fnstsw  ax
        test    ah, 4                           # C2: |x| >= 2^63, nothing pushed
        jnz     .ts_rad_err
        fstp    qword ptr [rsp + 16]            # cos
        fstp    qword ptr [rsp + 24]            # sin
        movsd   xmm0, qword ptr [rsp + 24]
        movsd   xmm1, qword ptr [rsp + 16]
        movsd   xmm2, qword ptr [rsp]
        andpd   xmm2, xmmword ptr [rip + c_absmask]
        ucomisd xmm2, qword ptr [rip + c_1em3]
        jbe     3f
        movapd  xmm3, xmm0
        andpd   xmm3, xmmword ptr [rip + c_absmask]
        ucomisd xmm3, qword ptr [rip + c_1em15]
        jae     1f
        xorps   xmm0, xmm0
1:      movapd  xmm3, xmm1
        andpd   xmm3, xmmword ptr [rip + c_absmask]
        ucomisd xmm3, qword ptr [rip + c_1em15]
        jae     3f
        xorps   xmm1, xmm1
3:      add     rsp, 40
        ret
.ts_rad_err:
        fstp    st(0)
.ts_err:
        mov     byte ptr [rip + g_err], 1
        xorps   xmm0, xmm0
        xorps   xmm1, xmm1
        add     rsp, 40
        ret

do_sin:
        sub     rsp, 8
        call    trig_sc
        add     rsp, 8
        ret
do_cos:
        sub     rsp, 8
        call    trig_sc
        movaps  xmm0, xmm1
        add     rsp, 8
        ret
do_tan:
        sub     rsp, 8
        call    trig_sc
        xorps   xmm2, xmm2
        ucomisd xmm1, xmm2
        jp      1f
        je      1f
        divsd   xmm0, xmm1
        add     rsp, 8
        ret
1:      add     rsp, 8
        jmp     .err0                           # tan(90 deg): undefined

# ---------------------------------------------------------------- formatting
# pow10_ext: eax = signed exponent -> st0 = 10^eax (64-bit precision)
# clobbers eax, edx.  Binary exponentiation, <= 9 multiplications for |e| < 512.
pow10_ext:
        push    rcx
        mov     ecx, eax
        mov     edx, eax
        sar     edx, 31
        xor     ecx, edx
        sub     ecx, edx                        # |e|
        fld1
        fild    word ptr [rip + c_ten]
        test    ecx, ecx
        jz      .p_done
.p_loop:
        test    cl, 1
        jz      1f
        fmul    st(1), st(0)
1:      shr     ecx, 1
        jz      .p_done
        fmul    st(0), st(0)
        jmp     .p_loop
.p_done:
        fstp    st(0)
        test    edx, edx
        jns     2f
        fld1                                    # negative exponent: 1 / 10^|e|
        fdiv    st(0), st(1)
        fxch    st(1)
        fstp    st(0)
2:      pop     rcx
        ret

# fmt_double: xmm0 = v, rcx = output buffer (>= 32 bytes)
#   15 significant digits, trailing zeros removed.  Fixed notation for
#   1e-6 <= |v| < 1e15, otherwise d.ddde+XX.
fmt_double:
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 64
        mov     rdi, rcx
        xorps   xmm1, xmm1
        ucomisd xmm0, xmm1
        jne     .fd_nz
        jp      .fd_nz
        mov     word ptr [rdi], '0'             # "0", NUL
        jmp     .fd_ret
.fd_nz:
        movq    rax, xmm0
        test    rax, rax
        jns     1f
        mov     byte ptr [rdi], '-'
        inc     rdi
        btr     rax, 63
        movq    xmm0, rax
1:      movsd   qword ptr [rsp], xmm0           # v = |value|
        fldlg2                                  # e10 estimate = round(log10 v)
        fld     qword ptr [rsp]
        fyl2x
        frndint
        fistp   dword ptr [rsp + 8]
        mov     esi, dword ptr [rsp + 8]
        mov     eax, esi                        # estimate too high?  v < 10^e
        call    pow10_ext
        fld     qword ptr [rsp]
        fcomip  st, st(1)
        fstp    st(0)
        jae     2f
        dec     esi
        jmp     3f
2:      lea     eax, [rsi + 1]                  # estimate too low?  v >= 10^(e+1)
        call    pow10_ext
        fld     qword ptr [rsp]
        fcomip  st, st(1)
        fstp    st(0)
        jb      3f
        inc     esi
3:      lea     eax, [rsi - 14]                 # N = round(v / 10^(e-14)), 15 digits
        test    eax, eax
        js      4f
        call    pow10_ext
        fld     qword ptr [rsp]
        fdiv    st(0), st(1)
        fxch    st(1)
        fstp    st(0)
        jmp     5f
4:      neg     eax
        call    pow10_ext
        fld     qword ptr [rsp]
        fmulp   st(1), st(0)
5:      fistp   qword ptr [rsp + 16]
        mov     rax, qword ptr [rsp + 16]
        mov     rdx, 1000000000000000
        cmp     rax, rdx
        jb      6f
        mov     rax, 100000000000000            # rounded up to 10^15
        inc     esi
6:      lea     r9, [rsp + 24]                  # 15 digits, division by 10 via multiply
        mov     r8, 0xCCCCCCCCCCCCCCCD
        mov     r10d, 14
7:      mov     rcx, rax
        mul     r8
        shr     rdx, 3
        lea     rax, [rdx + rdx*4]
        add     rax, rax
        sub     rcx, rax
        add     cl, '0'
        mov     byte ptr [r9 + r10], cl
        mov     rax, rdx
        dec     r10d
        jns     7b
        mov     r11d, 15                        # strip trailing zeros
8:      cmp     r11d, 1
        jbe     9f
        cmp     byte ptr [r9 + r11 - 1], '0'
        jne     9f
        dec     r11d
        jmp     8b
9:      cmp     esi, 14
        jg      .fd_sci
        cmp     esi, -6
        jl      .fd_sci
        test    esi, esi
        js      .fd_small
        xor     ecx, ecx                        # e >= 0: integer part, e+1 digits
1:      mov     al, '0'
        cmp     ecx, r11d
        jae     2f
        mov     al, byte ptr [r9 + rcx]
2:      mov     byte ptr [rdi], al
        inc     rdi
        inc     ecx
        cmp     ecx, esi
        jle     1b
        mov     ecx, esi
        inc     ecx
        cmp     ecx, r11d
        jae     .fd_term
        mov     byte ptr [rdi], '.'
        inc     rdi
3:      mov     al, byte ptr [r9 + rcx]
        mov     byte ptr [rdi], al
        inc     rdi
        inc     ecx
        cmp     ecx, r11d
        jb      3b
        jmp     .fd_term
.fd_small:                                      # 0.000ddd
        mov     word ptr [rdi], 0x2E30          # "0."
        add     rdi, 2
        mov     ecx, esi
        not     ecx                             # -e-1 leading zeros
        test    ecx, ecx
        jz      2f
1:      mov     byte ptr [rdi], '0'
        inc     rdi
        dec     ecx
        jnz     1b
2:      xor     ecx, ecx
3:      mov     al, byte ptr [r9 + rcx]
        mov     byte ptr [rdi], al
        inc     rdi
        inc     ecx
        cmp     ecx, r11d
        jb      3b
        jmp     .fd_term
.fd_sci:                                        # d.ddde+XX
        mov     al, byte ptr [r9]
        mov     byte ptr [rdi], al
        inc     rdi
        cmp     r11d, 1
        jbe     2f
        mov     byte ptr [rdi], '.'
        inc     rdi
        mov     ecx, 1
1:      mov     al, byte ptr [r9 + rcx]
        mov     byte ptr [rdi], al
        inc     rdi
        inc     ecx
        cmp     ecx, r11d
        jb      1b
2:      mov     byte ptr [rdi], 'e'
        inc     rdi
        mov     byte ptr [rdi], '+'
        test    esi, esi
        jns     3f
        mov     byte ptr [rdi], '-'
        neg     esi
3:      inc     rdi
        mov     eax, esi
        lea     r10, [rsp + 48]
        xor     ecx, ecx
        mov     r8d, 10
4:      xor     edx, edx
        div     r8d
        add     dl, '0'
        mov     byte ptr [r10 + rcx], dl
        inc     ecx
        test    eax, eax
        jnz     4b
5:      dec     ecx
        mov     al, byte ptr [r10 + rcx]
        mov     byte ptr [rdi], al
        inc     rdi
        test    ecx, ecx
        jnz     5b
.fd_term:
        mov     byte ptr [rdi], 0
.fd_ret:
        add     rsp, 64
        pop     rdi
        pop     rsi
        pop     rbx
        ret

        .globl  g_ans
        .data
        .balign 8
g_ans:  .double 0.0

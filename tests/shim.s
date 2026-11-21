# Test shim: exposes the engine through a plain Win64 C ABI so a DLL build can
# be driven from Python/ctypes.   calc_eval(expr, out, deg, ans) -> 1 ok / 0 error
        .intel_syntax noprefix
        .globl  calc_eval, DllMain
        .extern eval_expr, fmt_double, engine_init, g_deg, g_ans
        .text
DllMain:
        mov     eax, 1
        ret

calc_eval:
        push    rbx
        sub     rsp, 48
        mov     rbx, rdx                    # out buffer
        mov     byte ptr [rip + g_deg], r8b
        movq    xmm0, r9
        movsd   qword ptr [rip + g_ans], xmm0
        mov     qword ptr [rsp + 32], rcx
        call    engine_init
        mov     rcx, qword ptr [rsp + 32]
        call    eval_expr
        test    eax, eax
        jz      1f
        mov     rcx, rbx
        call    fmt_double
        mov     eax, 1
        jmp     2f
1:      mov     byte ptr [rbx], 0
2:      add     rsp, 48
        pop     rbx
        ret

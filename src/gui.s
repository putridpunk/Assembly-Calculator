# ============================================================================
#  gui.s  -  native Win32 front-end (pure assembly, no CRT)
#
#  One window, no child controls: every pixel is drawn by hand into a cached
#  off-screen bitmap and blitted per dirty rectangle, buttons are hit-tested
#  arithmetically, and the whole UI scales with the system DPI.
# ============================================================================
        .intel_syntax noprefix
        .globl  Start
        .extern eval_expr, fmt_double, engine_init, g_deg, g_ans

.macro API name
        call    qword ptr [rip + __imp_\name]
.endm

# -------- scaled metric slots (byte offsets into g_ms, 4 bytes each) --------
        .equ    MS_M,      0            # outer margin
        .equ    MS_G,      4            # gap between buttons
        .equ    MS_BW,     8            # button width
        .equ    MS_BH,     12           # button height
        .equ    MS_Y0,     16           # top of the button grid
        .equ    MS_W,      20           # client width
        .equ    MS_H,      24           # client height
        .equ    MS_RAD,    28           # corner ellipse size
        .equ    MS_INSET,  32           # text inset inside the display panel
        .equ    MS_PANELB, 36           # bottom of display panel
        .equ    MS_L1T,    40           # small line top / bottom
        .equ    MS_L1B,    44
        .equ    MS_L2T,    48           # big line top / bottom
        .equ    MS_L2B,    52
        .equ    MS_FBTN,   56           # font heights (negative = character height)
        .equ    MS_FBIG,   60
        .equ    MS_FMED,   64
        .equ    MS_FSMALL, 68
        .equ    NM,        18
        .equ    NB,        34           # number of buttons
        .equ    NT,        13           # number of token display rewrites

# -------- actions (token bytes are < 0x80) --------
        .equ    A_CLEAR,   0x80
        .equ    A_BACK,    0x81
        .equ    A_EQUALS,  0x82
        .equ    A_DEG,     0x83
        .equ    A_SQUARE,  0x84

# -------- colours (COLORREF = 0x00BBGGRR) --------
        .equ    C_BG,      0x001C1715
        .equ    C_PANEL,   0x0014100E
        .equ    C_TEXT,    0x00FAF6F4
        .equ    C_DIM,     0x009C867D
        .equ    C_ERR,     0x00867BFF

# ================================================================== data
        .section .rdata,"dr"
s_class:    .string16 "AsmCalcWindow"
s_title:    .string16 "Assembly Calculator"
s_face:     .string16 "Segoe UI"
s_zero:     .asciz    "0"
s_errtxt:   .string16 "Error"

# button labels (UTF-16, special glyphs as explicit code units)
L_sin:      .string16 "sin"
L_cos:      .string16 "cos"
L_tan:      .string16 "tan"
L_ln:       .string16 "ln"
L_log:      .string16 "log"
L_ac:       .string16 "AC"
L_bk:       .short  0x2190, 0
L_sqrt:     .short  0x221A, 0
L_nroot:    .short  0x207F, 0x221A, 0
L_pi:       .short  0x03C0, 0
L_sq:       .short  'x', 0x00B2, 0
L_pow:      .short  'x', 0x02B8, 0
L_fact:     .string16 "x!"
L_div:      .short  0x00F7, 0
L_mul:      .short  0x00D7, 0
L_sub:      .short  0x2212, 0
L_add:      .string16 "+"
L_lp:       .string16 "("
L_rp:       .string16 ")"
L_ans:      .string16 "Ans"
L_e:        .string16 "e"
L_dot:      .string16 "."
L_eq:       .string16 "="
L_0:        .string16 "0"
L_1:        .string16 "1"
L_2:        .string16 "2"
L_3:        .string16 "3"
L_4:        .string16 "4"
L_5:        .string16 "5"
L_6:        .string16 "6"
L_7:        .string16 "7"
L_8:        .string16 "8"
L_9:        .string16 "9"

# style table: normal, hover, pressed, text   (0 digit 1 op 2 func 3 equals 4 danger 5 mode 6 util)
        .balign 16
g_styles:
        .long   0x00332A26, 0x003F3430, 0x004C3F3A, 0x00FAF6F4
        .long   0x006B3F3A, 0x00804C46, 0x00945B54, 0x00FFFFFF
        .long   0x00332B1C, 0x00433824, 0x0055462C, 0x00C4D65F
        .long   0x00FF636C, 0x00FF767E, 0x00E6525A, 0x00FFFFFF
        .long   0x0026223A, 0x002F2A4A, 0x0039325C, 0x00867BFF
        .long   0x001E3034, 0x00273D43, 0x00304B52, 0x0057C8FF
        .long   0x0028211E, 0x00352C28, 0x00433732, 0x00C5B2AA

# key -> action pairs for WM_CHAR (terminated by 0)
g_keymap:
        .byte   '+','+',  '-','-',  '*','*',  '/','/',  '^','^',  '(','(',  ')',')',  '!','!'
        .byte   '.','.',  ',','.',  'x','*',  'X','*',  '=',A_EQUALS,  13,A_EQUALS
        .byte   8,A_BACK,  27,A_CLEAR,  's','S',  'c','C',  't','T',  'l','L',  'n','N'
        .byte   'r','Q',  'R','R',  'p','P',  'e','E',  'a','A',  'd',A_DEG,  0,0

# token -> display text:  tok, length, up to three UTF-16 units
g_toktbl:
        .byte   '*', 1;  .short 0x00D7, 0, 0
        .byte   '/', 1;  .short 0x00F7, 0, 0
        .byte   '-', 1;  .short 0x2212, 0, 0
        .byte   'S', 3;  .short 's', 'i', 'n'
        .byte   'C', 3;  .short 'c', 'o', 's'
        .byte   'T', 3;  .short 't', 'a', 'n'
        .byte   'L', 3;  .short 'l', 'o', 'g'
        .byte   'N', 2;  .short 'l', 'n', 0
        .byte   'Q', 1;  .short 0x221A, 0, 0
        .byte   'R', 1;  .short 0x221A, 0, 0
        .byte   'P', 1;  .short 0x03C0, 0, 0
        .byte   'E', 1;  .short 'e', 0, 0
        .byte   'A', 3;  .short 'A', 'n', 's'

        .data
        .balign 16
g_mb:   .long   14, 8, 62, 50, 124, 370, 536, 14, 16, 116, 22, 48, 48, 112, -19, -46, -30, -18
g_hover:    .long   -1
g_press:    .long   -1
g_lbl_deg:  .short  'D', 'E', 'G', 0

# button table: label*, col, row, span, action, style, pad[3]   (16 bytes)
.macro BTN lbl, col, row, span, act, sty
        .quad   \lbl
        .byte   \col, \row, \span, \act, \sty, 0, 0, 0
.endm
        .balign 16
g_btns:
        BTN g_lbl_deg, 0,0,1, A_DEG,    5
        BTN L_sin,     1,0,1, 'S',      2
        BTN L_cos,     2,0,1, 'C',      2
        BTN L_tan,     3,0,1, 'T',      2
        BTN L_bk,      4,0,1, A_BACK,   4
        BTN L_ln,      0,1,1, 'N',      2
        BTN L_log,     1,1,1, 'L',      2
        BTN L_sqrt,    2,1,1, 'Q',      2
        BTN L_nroot,   3,1,1, 'R',      2
        BTN L_ac,      4,1,1, A_CLEAR,  4
        BTN L_pi,      0,2,1, 'P',      6
        BTN L_sq,      1,2,1, A_SQUARE, 2
        BTN L_pow,     2,2,1, '^',      2
        BTN L_fact,    3,2,1, '!',      2
        BTN L_div,     4,2,1, '/',      1
        BTN L_lp,      0,3,1, '(',      6
        BTN L_7,       1,3,1, '7',      0
        BTN L_8,       2,3,1, '8',      0
        BTN L_9,       3,3,1, '9',      0
        BTN L_mul,     4,3,1, '*',      1
        BTN L_rp,      0,4,1, ')',      6
        BTN L_4,       1,4,1, '4',      0
        BTN L_5,       2,4,1, '5',      0
        BTN L_6,       3,4,1, '6',      0
        BTN L_sub,     4,4,1, '-',      1
        BTN L_ans,     0,5,1, 'A',      6
        BTN L_1,       1,5,1, '1',      0
        BTN L_2,       2,5,1, '2',      0
        BTN L_3,       3,5,1, '3',      0
        BTN L_add,     4,5,1, '+',      1
        BTN L_e,       0,6,1, 'E',      6
        BTN L_0,       1,6,2, '0',      0
        BTN L_dot,     3,6,1, '.',      0
        BTN L_eq,      4,6,1, A_EQUALS, 3

        .bss
        .balign 16
g_ms:       .skip   NM*4
g_hwnd:     .skip   8
g_mdc:      .skip   8
g_bmp:      .skip   8
g_hbrush:   .skip   8
g_fbtn:     .skip   8
g_fbig:     .skip   8
g_fmed:     .skip   8
g_fsmall:   .skip   8
g_dpi:      .skip   4
g_pl:       .skip   4                   # current paint rectangle
g_pt:       .skip   4
g_pr:       .skip   4
g_pb:       .skip   4
g_len:      .skip   4
g_state:    .skip   1                   # 0 typing, 1 showing result, 2 error
g_prevok:   .skip   1
g_tracking: .skip   1
g_expr:     .skip   264
g_res:      .skip   40
g_prev:     .skip   40
g_tokmap:   .skip   256
g_cellmap:  .skip   40
g_wbuf:     .skip   2200

# ================================================================== code
        .text

# btn_rect: ecx = button index, rdx = RECT*   -> rax = button record
btn_rect:
        shl     ecx, 4
        lea     rax, [rip + g_btns]
        add     rax, rcx
        movzx   ecx, byte ptr [rax + 8]                 # col
        mov     r8d, dword ptr [rip + g_ms + MS_BW]
        add     r8d, dword ptr [rip + g_ms + MS_G]
        imul    ecx, r8d
        add     ecx, dword ptr [rip + g_ms + MS_M]
        mov     dword ptr [rdx], ecx                    # left
        movzx   r9d, byte ptr [rax + 10]                # span
        mov     r10d, dword ptr [rip + g_ms + MS_BW]
        imul    r10d, r9d
        dec     r9d
        imul    r9d, dword ptr [rip + g_ms + MS_G]
        add     r10d, r9d
        add     r10d, ecx
        mov     dword ptr [rdx + 8], r10d               # right
        movzx   ecx, byte ptr [rax + 9]                 # row
        mov     r8d, dword ptr [rip + g_ms + MS_BH]
        add     r8d, dword ptr [rip + g_ms + MS_G]
        imul    ecx, r8d
        add     ecx, dword ptr [rip + g_ms + MS_Y0]
        mov     dword ptr [rdx + 4], ecx                # top
        add     ecx, dword ptr [rip + g_ms + MS_BH]
        mov     dword ptr [rdx + 12], ecx               # bottom
        ret

# hit_test: ecx = x, edx = y  -> eax = button index or -1
hit_test:
        sub     rsp, 40
        mov     dword ptr [rsp + 16], ecx
        mov     dword ptr [rsp + 20], edx
        mov     eax, ecx
        sub     eax, dword ptr [rip + g_ms + MS_M]
        js      .ht_none
        xor     edx, edx
        mov     ecx, dword ptr [rip + g_ms + MS_BW]
        add     ecx, dword ptr [rip + g_ms + MS_G]
        div     ecx
        mov     r8d, eax                                # column
        cmp     r8d, 5
        jae     .ht_none
        mov     eax, dword ptr [rsp + 20]
        sub     eax, dword ptr [rip + g_ms + MS_Y0]
        js      .ht_none
        xor     edx, edx
        mov     ecx, dword ptr [rip + g_ms + MS_BH]
        add     ecx, dword ptr [rip + g_ms + MS_G]
        div     ecx                                     # row
        cmp     eax, 7
        jae     .ht_none
        lea     eax, [rax + rax*4]
        add     eax, r8d
        lea     rcx, [rip + g_cellmap]
        movzx   ecx, byte ptr [rcx + rax]
        cmp     ecx, 0xFF
        je      .ht_none
        mov     dword ptr [rsp + 24], ecx
        mov     rdx, rsp
        call    btn_rect                                # exact test (rejects gaps)
        mov     ecx, dword ptr [rsp + 16]
        mov     edx, dword ptr [rsp + 20]
        cmp     ecx, dword ptr [rsp]
        jl      .ht_none
        cmp     ecx, dword ptr [rsp + 8]
        jge     .ht_none
        cmp     edx, dword ptr [rsp + 4]
        jl      .ht_none
        cmp     edx, dword ptr [rsp + 12]
        jge     .ht_none
        mov     eax, dword ptr [rsp + 24]
        add     rsp, 40
        ret
.ht_none:
        mov     eax, -1
        add     rsp, 40
        ret

# inval_btn: ecx = button index (ignored if < 0)
inval_btn:
        test    ecx, ecx
        js      1f
        sub     rsp, 56
        lea     rdx, [rsp + 32]
        call    btn_rect
        mov     rcx, qword ptr [rip + g_hwnd]
        lea     rdx, [rsp + 32]
        xor     r8d, r8d
        API     InvalidateRect
        add     rsp, 56
1:      ret

# is_func: al = token -> eax = 1 if token is a function (always followed by '(')
is_func:
        cmp     al, 'S'
        je      1f
        cmp     al, 'C'
        je      1f
        cmp     al, 'T'
        je      1f
        cmp     al, 'L'
        je      1f
        cmp     al, 'N'
        je      1f
        cmp     al, 'Q'
        je      1f
        xor     eax, eax
        ret
1:      mov     eax, 1
        ret

# to_wide: rcx = token/ASCII string, rdx = UTF-16 destination -> eax = length
to_wide:
        push    rbx
        mov     r8, rdx
.tw_loop:
        movzx   eax, byte ptr [rcx]
        test    eax, eax
        jz      .tw_done
        inc     rcx
        lea     r10, [rip + g_tokmap]
        movzx   r9d, byte ptr [r10 + rax]
        test    r9d, r9d
        jnz     .tw_tok
        mov     word ptr [rdx], ax
        add     rdx, 2
        jmp     .tw_loop
.tw_tok:
        lea     r10, [rip + g_toktbl - 8]
        lea     r9, [r10 + r9*8]
        movzx   ebx, byte ptr [r9 + 1]
        add     r9, 2
1:      mov     ax, word ptr [r9]
        mov     word ptr [rdx], ax
        add     r9, 2
        add     rdx, 2
        dec     ebx
        jnz     1b
        jmp     .tw_loop
.tw_done:
        sub     rdx, r8
        shr     edx, 1
        mov     eax, edx
        pop     rbx
        ret

# update_preview: live result shown (dimmed) above the expression
update_preview:
        sub     rsp, 40
        mov     byte ptr [rip + g_prevok], 0
        cmp     byte ptr [rip + g_state], 0
        jne     .up_ret
        cmp     dword ptr [rip + g_len], 0
        je      .up_ret
        lea     rcx, [rip + g_expr]
1:      movzx   eax, byte ptr [rcx]                     # skip plain numbers
        test    eax, eax
        jz      .up_ret
        inc     rcx
        cmp     al, '.'
        je      1b
        sub     eax, '0'
        cmp     eax, 9
        jbe     1b
        lea     rcx, [rip + g_expr]
        call    eval_expr
        test    eax, eax
        jz      .up_ret
        lea     rcx, [rip + g_prev]
        call    fmt_double
        mov     byte ptr [rip + g_prevok], 1
.up_ret:
        add     rsp, 40
        ret

# do_action: al = action code (token byte, or A_*)
do_action:
        push    rbx
        sub     rsp, 32
        movzx   ebx, al
        cmp     bl, 0x80
        jae     .da_special
        cmp     byte ptr [rip + g_state], 1
        jne     .da_not_res
        cmp     bl, '+'                                 # after "=": an operator continues from Ans
        je      .da_cont
        cmp     bl, '-'
        je      .da_cont
        cmp     bl, '*'
        je      .da_cont
        cmp     bl, '/'
        je      .da_cont
        cmp     bl, '^'
        je      .da_cont
        cmp     bl, 'R'
        je      .da_cont
        cmp     bl, '!'
        je      .da_cont
        mov     dword ptr [rip + g_len], 0              # anything else starts afresh
        mov     byte ptr [rip + g_expr], 0
        jmp     .da_not_res
.da_cont:
        mov     word ptr [rip + g_expr], 'A'
        mov     dword ptr [rip + g_len], 1
.da_not_res:
        mov     byte ptr [rip + g_state], 0
        cmp     bl, '.'                                 # one decimal point per number
        jne     .da_append
        mov     ecx, dword ptr [rip + g_len]
        lea     rdx, [rip + g_expr]
1:      test    ecx, ecx
        jz      .da_append
        movzx   eax, byte ptr [rdx + rcx - 1]
        cmp     al, '.'
        je      .da_done
        sub     eax, '0'
        cmp     eax, 9
        ja      .da_append
        dec     ecx
        jmp     1b
.da_append:
        mov     ecx, dword ptr [rip + g_len]
        cmp     ecx, 250
        jae     .da_done
        lea     rdx, [rip + g_expr]
        mov     byte ptr [rdx + rcx], bl
        inc     ecx
        mov     eax, ebx
        call    is_func
        test    eax, eax
        jz      1f
        mov     byte ptr [rdx + rcx], '('
        inc     ecx
1:      mov     dword ptr [rip + g_len], ecx
        mov     byte ptr [rdx + rcx], 0
        jmp     .da_done
.da_special:
        cmp     bl, A_CLEAR
        je      .da_clear
        cmp     bl, A_BACK
        je      .da_back
        cmp     bl, A_EQUALS
        je      .da_eq
        cmp     bl, A_DEG
        je      .da_deg
        mov     al, '^'                                 # A_SQUARE
        call    do_action
        mov     al, '2'
        call    do_action
        jmp     .da_ret
.da_clear:
        mov     dword ptr [rip + g_len], 0
        mov     byte ptr [rip + g_expr], 0
        mov     byte ptr [rip + g_state], 0
        jmp     .da_done
.da_back:
        mov     byte ptr [rip + g_state], 0
        mov     ecx, dword ptr [rip + g_len]
        test    ecx, ecx
        jz      .da_done
        lea     rdx, [rip + g_expr]
        cmp     ecx, 2
        jb      2f
        cmp     byte ptr [rdx + rcx - 1], '('           # delete "S(" etc. as one unit
        jne     2f
        movzx   eax, byte ptr [rdx + rcx - 2]
        call    is_func
        test    eax, eax
        jz      2f
        dec     ecx
2:      dec     ecx
        mov     dword ptr [rip + g_len], ecx
        mov     byte ptr [rdx + rcx], 0
        jmp     .da_done
.da_eq:
        cmp     dword ptr [rip + g_len], 0
        je      .da_ret
        lea     rcx, [rip + g_expr]
        call    eval_expr
        test    eax, eax
        jz      1f
        movsd   qword ptr [rip + g_ans], xmm0
        lea     rcx, [rip + g_res]
        call    fmt_double
        mov     byte ptr [rip + g_state], 1
        jmp     .da_done
1:      mov     byte ptr [rip + g_state], 2
        jmp     .da_done
.da_deg:
        xor     byte ptr [rip + g_deg], 1
        lea     rax, [rip + g_lbl_deg]
        mov     dword ptr [rax], 0x00450044             # "DE"
        mov     word ptr [rax + 4], 'G'
        cmp     byte ptr [rip + g_deg], 0
        jne     1f
        mov     dword ptr [rax], 0x00410052             # "RA"
        mov     word ptr [rax + 4], 'D'
1:      call    update_preview
        mov     rcx, qword ptr [rip + g_hwnd]
        xor     edx, edx
        xor     r8d, r8d
        API     InvalidateRect
        jmp     .da_ret
.da_done:
        call    update_preview
        mov     rcx, qword ptr [rip + g_hwnd]
        lea     rdx, [rip + g_dr]
        xor     r8d, r8d
        API     InvalidateRect
.da_ret:
        add     rsp, 32
        pop     rbx
        ret

# draw_button: ecx = index   (draws into the off-screen DC, honours paint rect)
draw_button:
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 112
        mov     esi, ecx
        lea     rdx, [rsp + 64]
        call    btn_rect
        mov     rbx, rax
        mov     eax, dword ptr [rsp + 72]
        cmp     eax, dword ptr [rip + g_pl]
        jle     .db_ret
        mov     eax, dword ptr [rsp + 64]
        cmp     eax, dword ptr [rip + g_pr]
        jge     .db_ret
        mov     eax, dword ptr [rsp + 76]
        cmp     eax, dword ptr [rip + g_pt]
        jle     .db_ret
        mov     eax, dword ptr [rsp + 68]
        cmp     eax, dword ptr [rip + g_pb]
        jge     .db_ret
        movzx   eax, byte ptr [rbx + 12]
        shl     eax, 4
        lea     rdi, [rip + g_styles]
        add     rdi, rax
        xor     eax, eax
        cmp     esi, dword ptr [rip + g_press]
        jne     1f
        mov     eax, 8
        jmp     2f
1:      cmp     esi, dword ptr [rip + g_hover]
        jne     2f
        mov     eax, 4
2:      mov     edx, dword ptr [rdi + rax]
        mov     rcx, qword ptr [rip + g_mdc]
        API     SetDCBrushColor
        mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, dword ptr [rsp + 64]
        mov     r8d, dword ptr [rsp + 68]
        mov     r9d, dword ptr [rsp + 72]
        mov     eax, dword ptr [rsp + 76]
        mov     qword ptr [rsp + 32], rax
        mov     eax, dword ptr [rip + g_ms + MS_RAD]
        mov     qword ptr [rsp + 40], rax
        mov     qword ptr [rsp + 48], rax
        API     RoundRect
        mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, dword ptr [rdi + 12]
        API     SetTextColor
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, qword ptr [rbx]
        mov     r8d, -1
        lea     r9, [rsp + 64]
        mov     qword ptr [rsp + 32], 0x825             # CENTER|VCENTER|SINGLELINE|NOPREFIX
        API     DrawTextW
.db_ret:
        add     rsp, 112
        pop     rdi
        pop     rsi
        pop     rbx
        ret

# draw_text_line: draws g_wbuf-style text.  Stack-passed by caller (see draw_display)

# draw_display: panel, preview/expression line and the big result line
draw_display:
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 160
        mov     eax, dword ptr [rip + g_pt]
        cmp     eax, dword ptr [rip + g_ms + MS_Y0]
        jge     .dd_ret
        mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, C_PANEL
        API     SetDCBrushColor
        mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, dword ptr [rip + g_ms + MS_M]
        mov     r8d, edx
        mov     r9d, dword ptr [rip + g_ms + MS_W]
        sub     r9d, edx
        mov     eax, dword ptr [rip + g_ms + MS_PANELB]
        mov     qword ptr [rsp + 32], rax
        mov     eax, dword ptr [rip + g_ms + MS_RAD]
        mov     qword ptr [rsp + 40], rax
        mov     qword ptr [rsp + 48], rax
        API     RoundRect
        mov     eax, dword ptr [rip + g_ms + MS_M]      # text rectangle: left / right
        add     eax, dword ptr [rip + g_ms + MS_INSET]
        mov     dword ptr [rsp + 64], eax
        mov     ecx, dword ptr [rip + g_ms + MS_W]
        sub     ecx, dword ptr [rip + g_ms + MS_M]
        sub     ecx, dword ptr [rip + g_ms + MS_INSET]
        mov     dword ptr [rsp + 72], ecx
        sub     ecx, eax
        mov     dword ptr [rsp + 96], ecx               # available width
        # ---------------- line 1: preview, or the expression once evaluated
        lea     rsi, [rip + g_wbuf]
        movzx   eax, byte ptr [rip + g_state]
        xor     edi, edi                                # length
        test    eax, eax
        jnz     1f
        cmp     byte ptr [rip + g_prevok], 0
        je      .dd_line1_done
        lea     rcx, [rip + g_prev]
        mov     rdx, rsi
        call    to_wide
        mov     edi, eax
        jmp     .dd_line1_done
1:      lea     rcx, [rip + g_expr]
        mov     rdx, rsi
        call    to_wide
        mov     edi, eax
        cmp     byte ptr [rip + g_state], 1
        jne     .dd_line1_done
        mov     dword ptr [rsi + rdi*2], 0x003D0020     # " ="
        add     edi, 2
.dd_line1_done:
        test    edi, edi
        jz      .dd_line2
        mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, C_DIM
        API     SetTextColor
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, qword ptr [rip + g_fsmall]
        API     SelectObject
        mov     eax, dword ptr [rip + g_ms + MS_L1T]
        mov     dword ptr [rsp + 68], eax
        mov     eax, dword ptr [rip + g_ms + MS_L1B]
        mov     dword ptr [rsp + 76], eax
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, rsi
        mov     r8d, edi
        lea     r9, [rsp + 64]
        mov     qword ptr [rsp + 32], 0x826             # RIGHT|VCENTER|SINGLELINE|NOPREFIX
        API     DrawTextW
.dd_line2:
        # ---------------- line 2: expression while typing, result afterwards
        movzx   eax, byte ptr [rip + g_state]
        mov     ebx, C_TEXT
        cmp     eax, 1
        je      .dd_res
        cmp     eax, 2
        je      .dd_error
        cmp     dword ptr [rip + g_len], 0
        jne     2f
        lea     rcx, [rip + s_zero]
        jmp     3f
2:      lea     rcx, [rip + g_expr]
3:      mov     rdx, rsi
        call    to_wide
        mov     edi, eax
        jmp     .dd_measure
.dd_res:
        lea     rcx, [rip + g_res]
        mov     rdx, rsi
        call    to_wide
        mov     edi, eax
        jmp     .dd_measure
.dd_error:
        lea     rsi, [rip + s_errtxt]
        mov     edi, 5
        mov     ebx, C_ERR
.dd_measure:
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, qword ptr [rip + g_fbig]
        API     SelectObject
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, rsi
        mov     r8d, edi
        lea     r9, [rsp + 104]                         # SIZE
        API     GetTextExtentPoint32W
        mov     eax, dword ptr [rsp + 104]
        cmp     eax, dword ptr [rsp + 96]
        jle     1f
        mov     rcx, qword ptr [rip + g_mdc]            # too wide: drop to the medium font
        mov     rdx, qword ptr [rip + g_fmed]
        API     SelectObject
1:      mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, ebx
        API     SetTextColor
        mov     eax, dword ptr [rip + g_ms + MS_L2T]
        mov     dword ptr [rsp + 68], eax
        mov     eax, dword ptr [rip + g_ms + MS_L2B]
        mov     dword ptr [rsp + 76], eax
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, rsi
        mov     r8d, edi
        lea     r9, [rsp + 64]
        mov     qword ptr [rsp + 32], 0x826
        API     DrawTextW
.dd_ret:
        add     rsp, 160
        pop     rdi
        pop     rsi
        pop     rbx
        ret

# ================================================================ WndProc
WndProc:
        cmp     edx, 0x0F
        je      .w_paint
        cmp     edx, 0x14
        je      .w_erase
        cmp     edx, 0x200
        je      .w_move
        cmp     edx, 0x201
        je      .w_down
        cmp     edx, 0x202
        je      .w_up
        cmp     edx, 0x2A3
        je      .w_leave
        cmp     edx, 0x102
        je      .w_char
        cmp     edx, 0x02
        je      .w_destroy
        jmp     qword ptr [rip + __imp_DefWindowProcW]

.w_erase:
        mov     eax, 1                                  # we paint every pixel ourselves
        ret

.w_destroy:
        sub     rsp, 40
        xor     ecx, ecx
        API     PostQuitMessage
        xor     eax, eax
        add     rsp, 40
        ret

.w_move:
        sub     rsp, 56
        movsx   ecx, r9w
        mov     edx, r9d
        shr     edx, 16
        movsx   edx, dx
        call    hit_test
        cmp     eax, dword ptr [rip + g_hover]
        je      1f
        mov     dword ptr [rsp + 48], eax
        mov     ecx, dword ptr [rip + g_hover]
        call    inval_btn
        mov     ecx, dword ptr [rsp + 48]
        mov     dword ptr [rip + g_hover], ecx
        call    inval_btn
1:      cmp     byte ptr [rip + g_tracking], 0
        jne     2f
        mov     byte ptr [rip + g_tracking], 1
        mov     dword ptr [rsp + 32], 24                # TRACKMOUSEEVENT
        mov     dword ptr [rsp + 36], 2                 # TME_LEAVE
        mov     rax, qword ptr [rip + g_hwnd]
        mov     qword ptr [rsp + 40], rax
        lea     rcx, [rsp + 32]
        API     TrackMouseEvent
2:      xor     eax, eax
        add     rsp, 56
        ret

.w_leave:
        sub     rsp, 56
        mov     byte ptr [rip + g_tracking], 0
        mov     ecx, dword ptr [rip + g_hover]
        mov     dword ptr [rip + g_hover], -1
        call    inval_btn
        xor     eax, eax
        add     rsp, 56
        ret

.w_down:
        sub     rsp, 56
        movsx   ecx, r9w
        mov     edx, r9d
        shr     edx, 16
        movsx   edx, dx
        call    hit_test
        cmp     eax, -1
        je      1f
        mov     dword ptr [rip + g_press], eax
        mov     dword ptr [rsp + 48], eax
        mov     rcx, qword ptr [rip + g_hwnd]
        API     SetCapture
        mov     ecx, dword ptr [rsp + 48]
        call    inval_btn
1:      xor     eax, eax
        add     rsp, 56
        ret

.w_up:
        sub     rsp, 56
        mov     eax, dword ptr [rip + g_press]
        cmp     eax, -1
        je      1f
        mov     dword ptr [rsp + 48], eax
        mov     qword ptr [rsp + 40], r9
        mov     dword ptr [rip + g_press], -1
        API     ReleaseCapture
        mov     ecx, dword ptr [rsp + 48]
        call    inval_btn
        mov     r9, qword ptr [rsp + 40]
        movsx   ecx, r9w
        mov     edx, r9d
        shr     edx, 16
        movsx   edx, dx
        call    hit_test
        cmp     eax, dword ptr [rsp + 48]
        jne     1f
        shl     eax, 4
        lea     rdx, [rip + g_btns]
        movzx   eax, byte ptr [rdx + rax + 11]
        call    do_action
1:      xor     eax, eax
        add     rsp, 56
        ret

.w_char:
        sub     rsp, 40
        mov     eax, r8d
        lea     ecx, [rax - '0']
        cmp     ecx, 9
        jbe     2f
        lea     rdx, [rip + g_keymap]
1:      movzx   ecx, byte ptr [rdx]
        test    ecx, ecx
        jz      3f
        cmp     ecx, eax
        je      4f
        add     rdx, 2
        jmp     1b
4:      movzx   eax, byte ptr [rdx + 1]
2:      call    do_action
3:      xor     eax, eax
        add     rsp, 40
        ret

.w_paint:
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 176
        mov     rcx, qword ptr [rip + g_hwnd]
        lea     rdx, [rsp + 80]                         # PAINTSTRUCT
        API     BeginPaint
        mov     rbx, rax
        mov     eax, dword ptr [rsp + 80 + 12]
        mov     dword ptr [rip + g_pl], eax
        mov     eax, dword ptr [rsp + 80 + 16]
        mov     dword ptr [rip + g_pt], eax
        mov     eax, dword ptr [rsp + 80 + 20]
        mov     dword ptr [rip + g_pr], eax
        mov     eax, dword ptr [rsp + 80 + 24]
        mov     dword ptr [rip + g_pb], eax
        mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, C_BG
        API     SetDCBrushColor
        mov     rcx, qword ptr [rip + g_mdc]
        lea     rdx, [rsp + 80 + 12]
        mov     r8, qword ptr [rip + g_hbrush]
        API     FillRect
        call    draw_display
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, qword ptr [rip + g_fbtn]
        API     SelectObject
        xor     esi, esi
1:      mov     ecx, esi
        call    draw_button
        inc     esi
        cmp     esi, NB
        jb      1b
        mov     rcx, rbx                                # blit only the dirty rectangle
        mov     edx, dword ptr [rip + g_pl]
        mov     r8d, dword ptr [rip + g_pt]
        mov     r9d, dword ptr [rip + g_pr]
        sub     r9d, edx
        mov     eax, dword ptr [rip + g_pb]
        sub     eax, r8d
        mov     qword ptr [rsp + 32], rax
        mov     rax, qword ptr [rip + g_mdc]
        mov     qword ptr [rsp + 40], rax
        mov     qword ptr [rsp + 48], rdx
        mov     qword ptr [rsp + 56], r8
        mov     qword ptr [rsp + 64], 0x00CC0020       # SRCCOPY
        API     BitBlt
        mov     rcx, qword ptr [rip + g_hwnd]
        lea     rdx, [rsp + 80]
        API     EndPaint
        xor     eax, eax
        add     rsp, 176
        pop     rdi
        pop     rsi
        pop     rbx
        ret

# =================================================================== Start
.macro MKFONT msidx, weight, dest
        mov     ecx, dword ptr [rip + g_ms + \msidx]
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        mov     qword ptr [rsp + 32], \weight
        mov     qword ptr [rsp + 40], 0
        mov     qword ptr [rsp + 48], 0
        mov     qword ptr [rsp + 56], 0
        mov     qword ptr [rsp + 64], 1                 # DEFAULT_CHARSET
        mov     qword ptr [rsp + 72], 0
        mov     qword ptr [rsp + 80], 0
        mov     qword ptr [rsp + 88], 5                 # CLEARTYPE_QUALITY
        mov     qword ptr [rsp + 96], 0
        lea     rax, [rip + s_face]
        mov     qword ptr [rsp + 104], rax
        API     CreateFontW
        mov     qword ptr [rip + \dest], rax
.endm

Start:
        sub     rsp, 0x148
        call    engine_init
        API     SetProcessDPIAware
        API     GetDpiForSystem
        test    eax, eax
        jnz     1f
        mov     eax, 96
1:      mov     dword ptr [rip + g_dpi], eax
        xor     esi, esi                                # scale every metric by dpi/96
        lea     rdi, [rip + g_mb]
        lea     r8, [rip + g_ms]
2:      mov     eax, dword ptr [rdi + rsi*4]
        imul    eax, dword ptr [rip + g_dpi]
        cdq
        mov     ecx, 96
        idiv    ecx
        mov     dword ptr [r8 + rsi*4], eax
        inc     esi
        cmp     esi, NM
        jb      2b
        # token display map: tokmap[tok] = index + 1
        lea     rdi, [rip + g_tokmap]
        lea     rsi, [rip + g_toktbl]
        xor     ecx, ecx
3:      movzx   eax, byte ptr [rsi + rcx*8]
        lea     edx, [rcx + 1]
        mov     byte ptr [rdi + rax], dl
        inc     ecx
        cmp     ecx, NT
        jb      3b
        # cell map: grid cell -> button index
        lea     rdi, [rip + g_cellmap]
        mov     ecx, 40
        mov     al, 0xFF
        rep stosb
        xor     esi, esi
4:      mov     ecx, esi
        shl     ecx, 4
        lea     rdx, [rip + g_btns]
        add     rdx, rcx
        movzx   eax, byte ptr [rdx + 9]
        lea     eax, [rax + rax*4]
        movzx   r8d, byte ptr [rdx + 8]
        add     eax, r8d
        movzx   r9d, byte ptr [rdx + 10]
        lea     r10, [rip + g_cellmap]
5:      mov     byte ptr [r10 + rax], sil
        inc     eax
        dec     r9d
        jnz     5b
        inc     esi
        cmp     esi, NB
        jb      4b
        # window class
        xor     ecx, ecx
        API     GetModuleHandleW
        mov     rbx, rax
        xor     ecx, ecx
        mov     edx, 32512                              # IDC_ARROW
        API     LoadCursorW
        mov     r12, rax
        lea     rdi, [rsp + 128]
        xor     eax, eax
        mov     ecx, 10
        rep stosq
        mov     dword ptr [rsp + 128], 80
        lea     rax, [rip + WndProc]
        mov     qword ptr [rsp + 128 + 8], rax
        mov     qword ptr [rsp + 128 + 24], rbx
        mov     qword ptr [rsp + 128 + 40], r12
        lea     rax, [rip + s_class]
        mov     qword ptr [rsp + 128 + 64], rax
        lea     rcx, [rsp + 128]
        API     RegisterClassExW
        MKFONT  MS_FBTN, 600, g_fbtn
        MKFONT  MS_FBIG, 300, g_fbig
        MKFONT  MS_FMED, 300, g_fmed
        MKFONT  MS_FSMALL, 400, g_fsmall
        # outer window size from the wanted client size
        mov     dword ptr [rsp + 208], 0
        mov     dword ptr [rsp + 212], 0
        mov     eax, dword ptr [rip + g_ms + MS_W]
        mov     dword ptr [rsp + 216], eax
        mov     eax, dword ptr [rip + g_ms + MS_H]
        mov     dword ptr [rsp + 220], eax
        lea     rcx, [rsp + 208]
        mov     edx, 0x00CA0000                         # CAPTION|SYSMENU|MINIMIZEBOX
        xor     r8d, r8d
        xor     r9d, r9d
        API     AdjustWindowRectEx
        xor     ecx, ecx
        lea     rdx, [rip + s_class]
        lea     r8, [rip + s_title]
        mov     r9d, 0x00CA0000
        mov     dword ptr [rsp + 32], 0x80000000        # CW_USEDEFAULT
        mov     dword ptr [rsp + 40], 0x80000000
        mov     eax, dword ptr [rsp + 216]
        sub     eax, dword ptr [rsp + 208]
        mov     dword ptr [rsp + 48], eax
        mov     eax, dword ptr [rsp + 220]
        sub     eax, dword ptr [rsp + 212]
        mov     dword ptr [rsp + 56], eax
        mov     qword ptr [rsp + 64], 0
        mov     qword ptr [rsp + 72], 0
        mov     qword ptr [rsp + 80], rbx
        mov     qword ptr [rsp + 88], 0
        API     CreateWindowExW
        mov     qword ptr [rip + g_hwnd], rax
        mov     rsi, rax
        # dark title bar + caption colour (ignored on systems without support)
        mov     dword ptr [rsp + 224], 1
        mov     rcx, rsi
        mov     edx, 20                                 # DWMWA_USE_IMMERSIVE_DARK_MODE
        lea     r8, [rsp + 224]
        mov     r9d, 4
        API     DwmSetWindowAttribute
        mov     dword ptr [rsp + 224], C_BG
        mov     rcx, rsi
        mov     edx, 35                                 # DWMWA_CAPTION_COLOR
        lea     r8, [rsp + 224]
        mov     r9d, 4
        API     DwmSetWindowAttribute
        # off-screen back buffer, created once
        mov     rcx, rsi
        API     GetDC
        mov     rdi, rax
        mov     rcx, rdi
        API     CreateCompatibleDC
        mov     qword ptr [rip + g_mdc], rax
        mov     rcx, rdi
        mov     edx, dword ptr [rip + g_ms + MS_W]
        mov     r8d, dword ptr [rip + g_ms + MS_H]
        API     CreateCompatibleBitmap
        mov     qword ptr [rip + g_bmp], rax
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, rax
        API     SelectObject
        mov     rcx, rsi
        mov     rdx, rdi
        API     ReleaseDC
        mov     ecx, 18                                 # DC_BRUSH
        API     GetStockObject
        mov     qword ptr [rip + g_hbrush], rax
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, rax
        API     SelectObject
        mov     ecx, 8                                  # NULL_PEN
        API     GetStockObject
        mov     rcx, qword ptr [rip + g_mdc]
        mov     rdx, rax
        API     SelectObject
        mov     rcx, qword ptr [rip + g_mdc]
        mov     edx, 1                                  # TRANSPARENT
        API     SetBkMode
        mov     dword ptr [rip + g_dr], 0               # display invalidation rectangle
        mov     dword ptr [rip + g_dr + 4], 0
        mov     eax, dword ptr [rip + g_ms + MS_W]
        mov     dword ptr [rip + g_dr + 8], eax
        mov     eax, dword ptr [rip + g_ms + MS_Y0]
        mov     dword ptr [rip + g_dr + 12], eax
        mov     rcx, rsi
        mov     edx, 5                                  # SW_SHOW
        API     ShowWindow
        mov     rcx, rsi
        API     UpdateWindow
.msg_loop:
        lea     rcx, [rsp + 240]
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        API     GetMessageW
        test    eax, eax
        jle     .msg_exit
        lea     rcx, [rsp + 240]
        API     TranslateMessage
        lea     rcx, [rsp + 240]
        API     DispatchMessageW
        jmp     .msg_loop
.msg_exit:
        mov     ecx, dword ptr [rsp + 240 + 16]
        API     ExitProcess

        .bss
        .balign 16
g_dr:   .skip   16

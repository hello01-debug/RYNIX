global start
global gdt64
global tss


section .text
bits 32

start:
    mov esp, stack_top
    mov ebp, 0

    mov edi, ebx

    call check_multiboot
    call check_cpuid
    call check_long_mode

    call set_up_page_tables
    call enable_paging

    lgdt [gdt64.pointer]

    jmp gdt64.kernel_code:long_mode_start

    hlt

%define MULTIBOOT2_MAGIC_VALUE 0x36d76289

check_multiboot:
    cmp eax, MULTIBOOT2_MAGIC_VALUE
    jne .no_multiboot
    ret
.no_multiboot:
    mov al, "0"
    jmp error

check_cpuid:
  ; Check if CPUID is supported by attempting to flip the ID bit (bit 21)
  ; in the FLAGS register. If we can flip it, CPUID is available.

  ; Copy FLAGS in to EAX via stack
  pushfd
  pop eax

  ; Copy to ECX as well for comparing later on
  mov ecx, eax

  ; Flip the ID bit
  xor eax, 1 << 21

  ; Copy EAX to FLAGS via the stack
  push eax
  popfd

  ; Copy FLAGS back to EAX (with the flipped bit if CPUID is supported)
  pushfd
  pop eax

  ; Restore FLAGS from the old version stored in ECX (i.e. flipping the ID
  ; bit back if it was ever flipped).
  push ecx
  popfd

  ; Compare EAX and ECX. If they are equal then that means the bit wasn't
  ; flipped, and CPUID isn't supported.
  cmp eax, ecx
  je .no_cpuid
  ret
.no_cpuid:
  mov al, "1"
  jmp error
check_long_mode:
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_long_mode

    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .no_long_mode
    ret
.no_long_mode:
    mov al, "2"
    jmp error

set_up_page_tables:
    mov eax, p4_table
    or eax, 11b
    mov [p4_table + 511 * 8], eax

    mov eax, p3_table
    or eax, 11b
    mov dword [p4_table], eax

    mov eax, p2_table
    or eax, 11b
    mov dword [p3_table], eax

    mov ecx, 0
.map_p2_table:
    mov eax, 0x200000
    mul ecx
    or eax, 10000011b
    mov [p2_table + ecx * 8], eax

    inc ecx
    cmp ecx, 512
    jne .map_p2_table

    ret

enable_paging:
    mov eax, p4_table
    mov cr3, eax

    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    mov eax, cr0
    or eax, 1 << 31
    mov cr0, eax

    ret

error:
    mov dword[0xb8000], 0x4f524f45
    mov dword [0xb8004], 0x4f3a4f52
    mov dword [0xb8008], 0x4f204f20
    mov byte  [0xb800a], al
    hlt

section .bss
; This ensures that the page tables are page aligned.
align 4096

p4_table:
  ; `resb` means 'reserves bytes'
  resb 4096
p3_table:
  resb 4096
p2_table:
  resb 4096
; cf. http://os.phil-opp.com/allocating-frames.html
; the stack now has 64kB
stack_bottom:
  resb 4096 * 16
stack_top:

; -----------------------------------------------------------------------------
section .data

; The processor is still in a 32-bit compatibility submode. To actually execute
; 64-bit code, we need to set up a new Global Descriptor Table.
gdt64:
  ; .null_1 / 0x00
  dq 0
.kernel_code: equ $ - gdt64 ; 0x08
  dw 0
  dw 0
  db 0
  db 10011010b
  db 10100000b
  db 0
.kernel_data: equ $ - gdt64 ; 0x10
  dw 0
  dw 0
  db 0
  db 10010010b
  db 10000000b
  db 0
.null_2: equ $ - gdt64 ; 0x18
  dq 0
.user_data: equ $ - gdt64 ; 0x20
  dw 0
  dw 0
  db 0
  db 11110010b
  db 10000000b
  db 0
.user_code: equ $ - gdt64 ; 0x28
  dw 0
  dw 0
  db 0
  db 11111010b
  db 10100000b
  db 0
.tss: equ $ - gdt64 ; 0x30
  ; We only set type and flags below. Other values will be set in `tss_init()`.
  ; low
  dw 0         ; limit 15:0
  dw 0         ; base 15:0
  db 0         ; base 23:16
  db 10001001b ; type
  db 10100000b ; limit 19:16 and flags
  db 0         ; base 31:24
  ; high
  dq 0
.pointer:
  dw .pointer - gdt64 - 1
  dq gdt64

; TSS
tss:
; We don't load the TSS right now, we create it here and we'll finish the
; initialization in `tss_init()`.
.base: equ 0
  dd 0 ; reserved0
  dq 0 ; rsp0 (Privilege Stack Table)
  dq 0 ; rsp1
  dq 0 ; rsp2
  dq 0 ; reserved1
  dq 0 ; ist1 (Interrupt Stack Table)
  dq 0 ; ist2
  dq 0 ; ist3
  dq 0 ; ist4
  dq 0 ; ist5
  dq 0 ; ist6
  dq 0 ; ist7
  dq 0 ; reserved2
  dw 0 ; reserved3
  dw 0 ; iopb_offset (I/O Map Base Address)
.size: equ $ - tss

section .text
bits 64

extern kmain

long_mode_start:
    mov ax, 0
    mov ss, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    call kmain

    cli
    hlt
.section .rodata
name_help:     .asciz "help"
name_clear:    .asciz "clear"
name_exit:     .asciz "exit"
name_echo:     .asciz "echo"
help_text:     .asciz "Internos: help, clear, exit, echo\nExternos: ruta explícita o comando en /usr/bin y /bin\n"
clear_text:    .asciz "\033[2J\033[H"
space_text:    .asciz " "
newline_text:  .asciz "\n"
write_error:   .ascii "minishell: error de escritura\n"
write_error_len = . - write_error

.section .text
.global handle_builtin
.extern string_equals
.extern print_string
.extern write_fd

// handle_builtin: ejecuta un interno si argv[0] coincide con un comando interno
// Devuelve 1 si lo reconoce, 0 si no
handle_builtin:
    stp     x29, x30, [sp, #-16]!            // Proteger FP y LR antes de llamar funciones
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!            // Guardar argc y argv entre comparaciones
    stp     x21, x22, [sp, #-16]!
    mov     x19, x0                          // argc
    mov     x20, x1                          // argv
    cbz     x19, .unknown                    // Sin argumentos, no acceder a argv[0]
    ldr     x21, [x20]                       // Primer puntero: nombre del comando

    // Cada ADRP/ADD forma la dirección de un nombre en .rodata
    mov     x0, x21                          // Primera cadena: argv[0]
    adrp    x1, name_help                    // Página de "help"
    add     x1, x1, :lo12:name_help          // Dirección completa para comparar
    bl      string_equals                    // Comparación exacta hasta el NUL
    cbnz    x0, .help                        // Si coincide, ejecutar help

    mov     x0, x21
    adrp    x1, name_clear
    add     x1, x1, :lo12:name_clear
    bl      string_equals
    cbnz    x0, .clear

    mov     x0, x21
    adrp    x1, name_exit
    add     x1, x1, :lo12:name_exit
    bl      string_equals
    cbnz    x0, .exit_shell

    mov     x0, x21
    adrp    x1, name_echo
    add     x1, x1, :lo12:name_echo
    bl      string_equals
    cbnz    x0, .echo

.unknown:
    mov     x0, #0                           // El caller intentará ejecutar un externo
    b       .return

.help:
    // Ayuda breve, escrita por print_string
    adrp    x0, help_text
    add     x0, x0, :lo12:help_text
    bl      print_string
    b       .handled

.clear:
    // Limpiar un terminal ANSI sin ejecutar un programa externo
    adrp    x0, clear_text
    add     x0, x0, :lo12:clear_text
    bl      print_string
    b       .handled

.echo:
    mov     x0, x19                          // Pasar argc original
    mov     x1, x20                          // Pasar argv original
    bl      builtin_echo                     // Imprimir argumentos y salto final

.handled:
    // El interno fue reconocido aunque la escritura haya fallado
    cmp     x0, #0
    b.ge    .recognized
    mov     x0, #2                           // Informar el error por stderr
    adrp    x1, write_error
    add     x1, x1, :lo12:write_error
    mov     x2, #write_error_len
    bl      write_fd

.recognized:
    mov     x0, #1
    b       .return

.exit_shell:
    mov     x0, #0                           // Status normal de exit
    mov     x8, #93                          // Linux AArch64: exit
    svc     #0

.return:
    ldp     x21, x22, [sp], #16              // Restaurar registros y balancear SP
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// builtin_echo: imprime argv[1..]
// Devuelve 0 o error de escritura
builtin_echo:
    stp     x29, x30, [sp, #-16]!            // Proteger retorno durante las escrituras
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    mov     x19, x0                          // argc
    mov     x20, x1                          // Base del arreglo argv
    mov     x21, #1                          // Empezar por argv[1]

.echo_loop:
    // Escribir un espacio solo antes del segundo argumento y posteriores
    cmp     x21, x19
    b.hs    .echo_newline                    // Fin de argumentos, incluso con echo solo
    cmp     x21, #1
    b.eq    .echo_word
    adrp    x0, space_text
    add     x0, x0, :lo12:space_text
    bl      print_string
    cmp     x0, #0
    b.lt    .echo_done

.echo_word:
    ldr     x0, [x20, x21, lsl #3]           // argv[i]: punteros de ocho bytes
    bl      print_string                     // La palabra ya termina en NUL
    cmp     x0, #0
    b.lt    .echo_done
    add     x21, x21, #1
    b       .echo_loop

.echo_newline:
    // Incluso sin argumentos, echo produce exactamente un LF
    adrp    x0, newline_text
    add     x0, x0, :lo12:newline_text
    bl      print_string

.echo_done:
    ldp     x21, x22, [sp], #16              // Retornar con SP y registros restaurados
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

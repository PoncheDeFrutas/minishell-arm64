.section .rodata
prompt:          .asciz "minishell> "
err_line:        .ascii "minishell: línea demasiado larga (máximo 255 bytes)\n"
err_line_len = . - err_line
err_read:        .ascii "minishell: error de lectura\n"
err_read_len = . - err_read
err_args:        .ascii "minishell: demasiados argumentos (máximo 16 tokens)\n"
err_args_len = . - err_args
err_process:     .ascii "minishell: error al crear o esperar el proceso\n"
err_process_len = . - err_process
err_output:      .ascii "minishell: error de escritura\n"
err_output_len = . - err_output

.section .bss
.balign 16
input_buffer:    .skip 256                   // Línea: 255 bytes de contenido y un NUL final
.balign 8
argv:            .skip 136                   // 16 punteros de argumentos y un NULL final
.balign 8
.global path_buffer
path_buffer:     .skip 512                   // Ruta candidata de un programa externo
.balign 8
envp_ptr:        .skip 8                     // Dirección del entorno recibido al arrancar

.section .text
.global _start
.extern print_string
.extern write_fd
.extern read_line
.extern parse_line
.extern handle_builtin
.extern run_external

// Usa x0, x1 y x8; termina con exit(93)
_start:
    ldr     x0, [sp]                         // argc del proceso, antes de modificar SP
    add     x0, x0, #2                       // Saltar argc, argv y su NULL final
    add     x0, sp, x0, lsl #3               // envp = SP + 8 * (argc + 2)
    adrp    x1, envp_ptr                     // Página de la variable envp_ptr
    add     x1, x1, :lo12:envp_ptr           // Dirección completa de envp_ptr
    str     x0, [x1]                         // Conservar el puntero para execve

    bl      shell_loop                       // El bucle solo retorna ante EOF
    mov     x0, #0                           // Código de salida normal
    mov     x8, #93                          // Linux AArch64: exit
    svc     #0

shell_loop:
    stp     x29, x30, [sp, #-16]!            // Guardar FP/LR y reservar 16 bytes
    mov     x29, sp                          // Nuevo frame pointer

.loop:
    // Mostrar el prompt antes de solicitar la siguiente línea
    adrp    x0, prompt
    add     x0, x0, :lo12:prompt             // x0 = cadena del prompt
    bl      print_string                     // Imprimir en stdout
    cmp     x0, #0
    b.lt    .output_error                    // Sin stdout, no repetir indefinidamente

    // Leer una sola línea en el buffer de 256 bytes
    adrp    x0, input_buffer
    add     x0, x0, :lo12:input_buffer       // x0 = buffer
    mov     x1, #256                       // x1 = capacidad total
    bl      read_line
    cmp     x0, #-1
    b.eq    .done                            // EOF sin texto
    cmp     x0, #-2
    b.eq    .line_error                      // La línea excedió el buffer
    cmp     x0, #-3
    b.eq    .read_error                      // Error irrecuperable de read

    // El parser coloca NUL entre tokens y guarda sus direcciones en argv
    adrp    x0, input_buffer
    add     x0, x0, :lo12:input_buffer
    adrp    x1, argv
    add     x1, x1, :lo12:argv               // x1 = arreglo de punteros
    mov     x2, #16                          // Máximo 16 tokens, incluido el comando
    bl      parse_line
    cmp     x0, #0
    b.lt    .args_error
    cbz     x0, .loop                        // Línea vacía o solo separadores

    // Los internos se atienden en el padre; el resto pasa al módulo externo
    adrp    x1, argv
    add     x1, x1, :lo12:argv               // x0 aún contiene argc
    bl      handle_builtin
    cbnz    x0, .loop                        // Interno reconocido y completado

    adrp    x0, argv
    add     x0, x0, :lo12:argv
    adrp    x1, envp_ptr
    add     x1, x1, :lo12:envp_ptr
    ldr     x1, [x1]                         // x1 = envp original del proceso
    bl      run_external                     // Espera al hijo antes de retornar
    cmp     x0, #0
    b.lt    .process_error
    b       .loop

// Preparar en x1/x2 el mensaje correspondiente; .report escribe en stderr
.line_error:
    mov     x2, #err_line_len
    adrp    x1, err_line
    add     x1, x1, :lo12:err_line
    b       .report

.read_error:
    mov     x2, #err_read_len
    adrp    x1, err_read
    add     x1, x1, :lo12:err_read
    mov     x0, #2
    bl      write_fd
    mov     x0, #1                           // Un read irrecuperable no debe repetirse
    mov     x8, #93
    svc     #0

.args_error:
    mov     x2, #err_args_len
    adrp    x1, err_args
    add     x1, x1, :lo12:err_args
    b       .report

.process_error:
    mov     x2, #err_process_len
    adrp    x1, err_process
    add     x1, x1, :lo12:err_process

.report:
    mov     x0, #2                           // Descriptor stderr
    bl      write_fd                         // x1 y x2 contienen texto y longitud
    b       .loop

.output_error:
    // Un fallo al escribir el prompt termina el shell con estado 1
    mov     x0, #2
    adrp    x1, err_output
    add     x1, x1, :lo12:err_output
    mov     x2, #err_output_len
    bl      write_fd
    mov     x0, #1
    mov     x8, #93
    svc     #0

.done:
    ldp     x29, x30, [sp], #16              // Restaurar FP/LR y balancear SP
    ret

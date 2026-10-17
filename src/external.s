.section .rodata
usr_prefix:       .asciz "/usr/bin/"
bin_prefix:       .asciz "/bin/"
not_found_text:   .ascii "minishell: comando no encontrado\n"
not_found_len = . - not_found_text
exec_error_text:  .ascii "minishell: no se pudo ejecutar el comando\n"
exec_error_len = . - exec_error_text

.section .text
.global run_external
.extern path_buffer
.extern write_fd

// run_external: crea un hijo para argv (x0, envp en x1) y espera su fin
// Devuelve 0 o error negativo; usa clone(220) y wait4(260)
run_external:
    stp     x29, x30, [sp, #-16]!            // Preservar retorno antes de la rama hijo
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!            // Mantener argv y envp tras la syscall
    stp     x21, x22, [sp, #-16]!
    mov     x19, x0                          // argv del comando
    mov     x20, x1                          // Entorno heredado

    // clone con SIGCHLD y sin CLONE_VM crea aquí un hijo separado
    mov     x0, #17                          // SIGCHLD; sin memoria compartida
    mov     x1, #0                           // Stack de hijo nulo: copia privada
    mov     x2, #0                           // parent_tid no utilizado
    mov     x3, #0                           // tls no utilizado
    mov     x4, #0                           // child_tid no utilizado
    mov     x8, #220                       // Linux AArch64: clone
    svc     #0                               // Error negativo, 0 hijo, PID padre
    cmp     x0, #0
    b.lt    .parent_done                     // Fallo: retornar errno al shell
    cbz     x0, .child                       // El hijo ejecuta otro programa
    mov     x21, x0                          // El padre conserva el PID

.wait:
    // Esperar al hijo antes de que el shell reutilice argv y buffer
    mov     x0, x21                          // PID exacto del hijo
    mov     x1, #0                           // status NULL
    mov     x2, #0                           // Sin opciones
    mov     x3, #0                           // rusage NULL
    mov     x8, #260                       // Linux AArch64: wait4
    svc     #0                               // Retorna PID o -errno
    cmp     x0, #-4                          // EINTR
    b.eq    .wait                            // Una señal no debe dejar un zombie
    cmp     x0, #0
    b.lt    .parent_done
    mov     x0, #0                           // Hijo esperado correctamente

.parent_done:
    ldp     x21, x22, [sp], #16              // Restaurar registros y SP del padre
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

.child:
    mov     x0, x19                          // argv válido en la copia privada
    mov     x1, x20                          // envp heredado
    bl      child_exec                       // execve reemplaza imagen o el hijo sale

// child_exec: ejecuta argv (x0, envp en x1) desde el hijo
// Usa execve(221) y exit(93)
child_exec:
    stp     x29, x30, [sp, #-16]!            // Frame válido durante las llamadas
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!
    stp     x21, x22, [sp, #-16]!
    mov     x19, x0                          // argv
    mov     x20, x1                          // envp
    ldr     x21, [x19]                       // argv[0]: nombre o ruta
    mov     x9, x21                          // Cursor para detectar '/'

.slash_scan:
    // Una barra indica ruta explícita; no se prueban prefijos
    ldrb    w10, [x9], #1
    cbz     w10, .try_usr
    cmp     w10, #47
    b.ne    .slash_scan
    mov     x0, x21                          // execve usará argv[0] literalmente
    b       .exec

.try_usr:
    // Sin '/', probar primero /usr/bin/<comando> sin cambiar argv[0]
    adrp    x0, usr_prefix                   // Página del prefijo
    add     x0, x0, :lo12:usr_prefix         // x0 = "/usr/bin/"
    mov     x1, x21                          // x1 = nombre original
    adrp    x2, path_buffer
    add     x2, x2, :lo12:path_buffer        // x2 = destino estático
    mov     x3, #512                       // x3 = capacidad del destino
    bl      build_path                       // Verificar espacio y terminar en NUL
    cmp     x0, #0
    b.lt    .exec_error                      // Ruta demasiado larga
    adrp    x0, path_buffer
    add     x0, x0, :lo12:path_buffer        // x0 = ruta candidata
    mov     x1, x19                          // x1 = argv, terminado en NULL
    mov     x2, x20                          // x2 = envp heredado
    mov     x8, #221                       // Linux AArch64: execve
    svc     #0                               // Si tiene éxito, no retorna
    cmp     x0, #-2                          // ENOENT: ruta inexistente
    b.eq    .try_bin                         // Probar segundo prefijo
    cmp     x0, #-20                         // ENOTDIR: componente no directorio
    b.ne    .exec_error

.try_bin:
    // Segundo y último prefijo predefinido: /bin/<comando>
    adrp    x0, bin_prefix
    add     x0, x0, :lo12:bin_prefix         // x0 = "/bin/"
    mov     x1, x21                          // Nombre original
    adrp    x2, path_buffer
    add     x2, x2, :lo12:path_buffer        // Reutilizar buffer de ruta del hijo
    mov     x3, #512
    bl      build_path
    cmp     x0, #0
    b.lt    .exec_error
    adrp    x0, path_buffer
    add     x0, x0, :lo12:path_buffer

.exec:
    // Usar ruta explícita o la segunda ruta construida
    mov     x1, x19                          // argv conserva el comando original
    mov     x2, x20                          // Entorno sin modificar
    mov     x8, #221                         // Linux AArch64: execve
    svc     #0                               // Solo retorna si falló
    cmp     x0, #-2
    b.eq    .not_found                       // No existe
    cmp     x0, #-20
    b.eq    .not_found                       // Ruta inválida

.exec_error:
    // Error al construir o ejecutar la ruta: informar y salir con estado 126
    mov     x0, #2                           // stderr
    adrp    x1, exec_error_text
    add     x1, x1, :lo12:exec_error_text
    mov     x2, #exec_error_len
    bl      write_fd                         // La salida del hijo no altera al padre
    mov     x0, #126                       // Error de ejecución distinto de ausencia
    b       .child_exit

.not_found:
    // Ausencia de programa: informar y salir con estado 127
    mov     x0, #2
    adrp    x1, not_found_text
    add     x1, x1, :lo12:not_found_text
    mov     x2, #not_found_len
    bl      write_fd
    mov     x0, #127                       // Comando inexistente

.child_exit:
    mov     x8, #93                          // Linux AArch64: exit del hijo
    svc     #0

// build_path: une prefijo x0 y nombre x1 en destino x2 (capacidad x3)
// Devuelve 0 o -1; comprueba el límite sin usar stack ni syscalls
build_path:
    mov     x7, x2                           // Inicio del destino, para error
    mov     x4, x2                           // Cursor de escritura
    mov     x5, x3                           // Espacio restante, incluido el NUL
    cbz     x5, .path_fail                   // Capacidad nula: no tocar memoria

.prefix_loop:
    // Copiar el prefijo hasta su NUL, sin copiar ese terminador
    ldrb    w9, [x0], #1                     // Leer y avanzar puntero de origen
    cbz     w9, .name_loop                   // Continuar con el nombre
    cmp     x5, #1
    b.ls    .path_fail                       // Reservar al menos un byte para NUL
    strb    w9, [x4], #1                     // Escribir y avanzar destino
    sub     x5, x5, #1                       // Actualizar capacidad disponible
    b       .prefix_loop

.name_loop:
    // Copiar el nombre con el mismo límite del buffer de ruta
    ldrb    w9, [x1], #1
    cbz     w9, .path_end
    cmp     x5, #1
    b.ls    .path_fail
    strb    w9, [x4], #1
    sub     x5, x5, #1
    b       .name_loop

.path_end:
    strb    wzr, [x4]                        // Toda ruta válida termina en NUL
    mov     x0, #0
    ret

.path_fail:
    // Invalidar un destino parcial cuando existe espacio para escribir
    cbz     x3, .path_fail_return
    strb    wzr, [x7]                        // El caller nunca verá una ruta truncada

.path_fail_return:
    mov     x0, #-1
    ret

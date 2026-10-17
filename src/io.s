.section .text
.global read_line
.global print_string
.global write_fd

// read_line: lee en el buffer x0 (capacidad x1) y devuelve la longitud en x0
// Devuelve -1 por EOF vacío, -2 por exceso y -3 por error de read(63)
read_line:
    stp     x29, x30, [sp, #-16]!            // Guardar FP y dirección de retorno
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!            // Preservar registros de trabajo
    stp     x21, x22, [sp, #-16]!
    sub     sp, sp, #16                      // Un byte temporal mantener alineación

    mov     x19, x0                          // Dirección del buffer de salida
    mov     x20, x1                          // Capacidad del buffer
    mov     x21, #0                          // Longitud acumulada
    mov     x22, #0                          // CR pendiente omitirlo si cierra la línea
    cbz     x20, .no_capacity

.read:
    // Leer exactamente un byte, útil también con stdin redirigido o por pipe
    mov     x0, #0                           // fd = stdin
    mov     x1, sp                           // Destino temporal en el stack
    mov     x2, #1                           // Longitud solicitada
    mov     x8, #63                          // Linux AArch64: read
    svc     #0                               // x0 = bytes leídos o -errno
    cmp     x0, #-4
    b.eq    .read                            // Reintentar si una señal interrumpió read
    cmp     x0, #0
    b.lt    .read_error
    cbz     x0, .eof                         // EOF con o sin texto pendiente

    ldrb    w9, [sp]                         // Byte recibido
    cmp     w9, #10
    b.eq    .finish                          // LF termina la línea
    cbz     x22, .current

    // Un CR anterior solo era final si a continuación vino LF o EOF
    mov     x22, #0
    sub     x10, x20, #1
    cmp     x21, x10
    b.hs    .drain
    mov     w11, #13
    strb    w11, [x19, x21]                  // Conservar CR intermedio como contenido
    add     x21, x21, #1

.current:
    cmp     w9, #13
    b.ne    .store
    mov     x22, #1                          // Posponer CR para reconocer CRLF
    b       .read

.store:
    sub     x10, x20, #1
    cmp     x21, x10
    b.hs    .drain                           // Reservar siempre un byte para NUL
    strb    w9, [x19, x21]                   // Agregar el byte al buffer
    add     x21, x21, #1
    b       .read

.eof:
    // Con EOF, entregar el texto parcial sin texto, avisar al shell
    cbnz    x21, .finish
    cbnz    x22, .finish
    mov     x0, #-1                          // EOF sin contenido pendiente
    b       .return

.finish:
    strb    wzr, [x19, x21]                  // Cerrar la línea con NUL
    mov     x0, x21                          // Devolver longitud útil
    b       .return

.drain:
    // Un comando excesivo se descarta entero para conservar la siguiente línea
    mov     x0, #0                           // stdin
    mov     x1, sp                           // Byte temporal
    mov     x2, #1
    mov     x8, #63                          // read
    svc     #0
    cmp     x0, #-4
    b.eq    .drain
    cmp     x0, #0
    b.lt    .read_error
    cbz     x0, .too_long
    ldrb    w9, [sp]
    cmp     w9, #10
    b.ne    .drain                           // Esperar LF o EOF

.too_long:
    strb    wzr, [x19]                       // Invalidar la línea truncada
    mov     x0, #-2
    b       .return

.no_capacity:
    mov     x0, #-2                          // Capacidad cero: no escribir fuera del buffer
    b       .return

.read_error:
    strb    wzr, [x19]
    mov     x0, #-3                          // Convertir -errno al contrato de la función

.return:
    add     sp, sp, #16                      // Liberar el byte temporal
    ldp     x21, x22, [sp], #16              // Restaurar registros y SP
    ldp     x19, x20, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// write_fd: escribe x2 bytes de x1 en el descriptor x0
// Devuelve 0 o error negativo usa write(64) y preserva x19-x22
write_fd:
    stp     x19, x20, [sp, #-16]!            // Guardar parámetros entre syscalls
    stp     x21, x22, [sp, #-16]!
    mov     x19, x0                          // fd
    mov     x20, x1                          // Próximo byte a escribir
    mov     x21, x2                          // Bytes restantes

.write:
    // Repetir hasta escribir todo, incluso si write acepta solo una parte
    cbz     x21, .ok
    mov     x0, x19
    mov     x1, x20
    mov     x2, x21
    mov     x8, #64                          // Linux AArch64: write
    svc     #0                               // x0 = escritos o -errno
    cmp     x0, #-4
    b.eq    .write                           // EINTR: reintentar sin avanzar punteros
    cmp     x0, #0
    b.lt    .write_done
    cbz     x0, .zero_write                  // Evitar un ciclo si write devuelve 0
    add     x20, x20, x0                     // Avanzar tras los bytes escritos
    sub     x21, x21, x0
    b       .write

.zero_write:
    mov     x0, #-5                          // EIO representa escritura sin progreso
    b       .write_done

.ok:
    mov     x0, #0

.write_done:
    ldp     x21, x22, [sp], #16              // Restaurar registros preservados
    ldp     x19, x20, [sp], #16
    ret

// print_string: imprime en stdout la cadena NUL de x0
// Devuelve 0 o error negativo llama a write_fd y preserva x19-x20 y FP/LR
print_string:
    stp     x29, x30, [sp, #-16]!            // Conservar retorno antes de BL
    mov     x29, sp
    stp     x19, x20, [sp, #-16]!
    mov     x19, x0                          // Inicio de la cadena
    mov     x20, #0                          // Longitud calculada

.measure:
    // Buscar el NUL sin incluirlo en la escritura
    ldrb    w9, [x19, x20]
    cbz     w9, .print
    add     x20, x20, #1
    b       .measure

.print:
    mov     x0, #1                           // stdout
    mov     x1, x19                          // Cadena original
    mov     x2, x20                          // Bytes sin NUL
    bl      write_fd                         // Devolver el resultado de la escritura
    ldp     x19, x20, [sp], #16              // Restaurar registros y retorno
    ldp     x29, x30, [sp], #16
    ret

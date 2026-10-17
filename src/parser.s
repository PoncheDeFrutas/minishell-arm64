.section .text
.global parse_line
.global string_equals

// parse_line: separa el buffer x0 y llena argv (x1), con máximo x2 tokens
// Devuelve argc o -1; coloca NUL entre palabras sin usar stack ni syscalls
parse_line:
    str     xzr, [x1]                        // argv[0] = NULL incluso si no hay tokens
    mov     x3, x0                           // Cursor de lectura del buffer
    mov     x4, #0                           // Contador argc

.skip:
    // Saltar y anular separadores hasta el inicio del siguiente token
    ldrb    w9, [x3]                         // Leer un byte sin pasar del NUL
    cbz     w9, .done                        // Fin de cadena
    cmp     w9, #32
    b.eq    .separator                       // Espacio ASCII
    cmp     w9, #9
    b.ne    .token                           // Otro byte: inicio de palabra

.separator:
    strb    wzr, [x3]                        // Separar palabras con un NUL
    add     x3, x3, #1
    b       .skip

.token:
    cmp     x4, x2
    b.hs    .overflow                        // No escribir más punteros que el límite
    str     x3, [x1, x4, lsl #3]             // argv[argc] = inicio del token
    add     x4, x4, #1

.scan:
    // Avanzar hasta un separador o el NUL final de la línea
    ldrb    w9, [x3]
    cbz     w9, .done                        // Último token termina en el NUL original
    cmp     w9, #32
    b.eq    .separator
    cmp     w9, #9
    b.eq    .separator
    add     x3, x3, #1
    b       .scan

.done:
    str     xzr, [x1, x4, lsl #3]            // Terminador requerido por execve
    mov     x0, x4                           // Devolver argc
    ret

.overflow:
    str     xzr, [x1]                        // Invalidar argv ante exceso
    mov     x0, #-1
    ret

// string_equals: compara las cadenas x0 y x1; devuelve 1 o 0 en x0
// Usa x0, x1, w2 y w3; no usa stack ni syscalls
string_equals:

.compare:
    ldrb    w2, [x0], #1                     // Comparar bytes y avanzar ambos punteros
    ldrb    w3, [x1], #1
    cmp     w2, w3
    b.ne    .unequal                         // Cualquier diferencia descarta coincidencia
    cbnz    w2, .compare                     // Si ambos son NUL, las cadenas terminaron
    mov     x0, #1
    ret

.unequal:
    mov     x0, #0
    ret

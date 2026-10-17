.syntax unified
.thumb
.section .text.entry,"ax",%progbits
.global o66_entry
.type o66_entry,%function
.thumb_func
o66_entry:
.Lbase:
 b.w 1f
 .word 0
1:
 push {r4,lr}
 adr r4,.Lbase
 ldr r4,[r4,#4]
 mrs r1,control
 str r1,[r4,#16]
 mrs r2,ipsr
 str r2,[r4,#20]
 mov r3,sp
 str r3,[r4,#24]
 tst r1,#1
 bne 2f
 cbnz r2,2f
 tst r3,#7
 bne 2f
 mov r0,r4
 bl o66_payload
 b 3f
2: mvn r0,#100
3:
 str r0,[r4]
 movw r1,#0x364f
 movt r1,#0x4f36
 str r1,[r4,#28]
 dsb sy
 pop {r4,pc}
.size o66_entry,.-o66_entry
.global ble_state
.type ble_state,%function
.thumb_func
ble_state:
 adr r0,.Lbase
 ldr r0,[r0,#4]
 bx lr
.size ble_state,.-ble_state

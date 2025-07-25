!
! SYS_SIZE 是要加载的字节数（16字节单位）.
! 0x3000 是 0x30000 字节 = 196kB，对于当前版本的 Linux 来说，足够了
!
SYSSIZE = 0x3000
!
!	bootsect.s		(C) 1991 Linus Torvalds
! bootsect.s被bios-startup程序加载到0x7c00位置，然后把自己移动到0x90000位置，并跳转到此处执行。
!
! 然后使用BIOS的终端程序将setup.s加载到它后面(0x90200)，将system加载到(0x10000)
!
! 注意! 当前系统最多8*65546字节，即使以后应该也不会有问题。我希望保持内核简洁。
! 内核大小512kB应该就够用了，尤其是他不包含类似minux系统中的cache buffer
!
! loader程序需要设计的尽可能简单，读取错误时会导致死循环，且不可中断。只能手动重启
! 一次尽可能读取一整个sectors，可以加载的尽可能快。

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

! 基本内存布局
SETUPLEN = 4				! setup-sectors数量，占四个扇区
BOOTSEG  = 0x07c0			! boot-sector初始地址
INITSEG  = 0x9000			! boot将移动到这里
SETUPSEG = 0x9020			! setup从这里开始
SYSSEG   = 0x1000			! system加载到0x10000 (65536)
ENDSEG   = SYSSEG + SYSSIZE	! 加载结束的地址

! FFFFF:
!   |      setup
! 90200
!   |      final bootloader
! 90000:
!	|      none
! 40000:   
!   |      system
! 10000:    
!   |      original bootloader 
! 07c00:
!   |      none
! 00000:  

! ROOT_DEV:	0x000 - 与启动时相同的软盘
!		0x301 - 第一个驱动器上的第一个分区等
ROOT_DEV = 0x306

!!! 把bootsect从0x07c0移动到0x9000，并初始化栈

entry _start
_start:
	mov	ax,#BOOTSEG
	mov	ds,ax
	mov	ax,#INITSEG
	mov	es,ax
	mov	cx,#256
	sub	si,si
	sub	di,di
	rep
	movw
	jmpi	go,INITSEG
go:	mov	ax,cs
	mov	ds,ax
	mov	es,ax
! 设置栈顶为0x9ff00
	mov	ss,ax
	mov	sp,#0xFF00		! 随便设置的值 >>512

! 直接把setup-sectors加载到bootblock后面，失败就反复加载

load_setup:
	mov	dx,#0x0000		! drive 0, head 0
	mov	cx,#0x0002		! sector 2, track 0
	mov	bx,#0x0200		! address = 512, in INITSEG
	mov	ax,#0x0200+SETUPLEN	! service 2, nr of sectors
	int	0x13			! read it
	jnc	ok_load_setup		! ok - continue
	mov	dx,#0x0000
	mov	ax,#0x0000		! reset the diskette
	int	0x13
	j	load_setup

ok_load_setup:
!!! 加载成功后读磁盘信息存到sectors变量中，打印提示信息，加载system
! 加载磁盘驱动参数，主要是每磁道的扇区数

	mov	dl,#0x00
	mov	ax,#0x0800		! AH=8 is get drive parameters
	int	0x13
	mov	ch,#0x00
	seg cs
	mov	sectors,cx
	mov	ax,#INITSEG
	mov	es,ax

! 打印提示信息

	mov	ah,#0x03		! read cursor pos
	xor	bh,bh
	int	0x10
	
	mov	cx,#24
	mov	bx,#0x0007		! page 0, attribute 7 (normal)
	mov	bp,#msg1
	mov	ax,#0x1301		! write string, move cursor
	int	0x10

! 已经打印了调试信息，现在准备加载system到0x10000处

	mov	ax,#SYSSEG
	mov	es,ax		! segment of 0x010000
	call	read_it
	call	kill_motor

! 之后检查要使用哪个root-device。 如果定义了device直接用，啥也不做
! 没定义的话， BIOS当前报告的扇区数量，使用/dev/PS0 (2,28) 或 /dev/at0 (2,8)

	seg cs
	mov	ax,root_dev
	cmp	ax,#0
	jne	root_defined
	seg cs
	mov	bx,sectors
	mov	ax,#0x0208		! /dev/ps0 - 1.2Mb
	cmp	bx,#15
	je	root_defined
	mov	ax,#0x021c		! /dev/PS0 - 1.44Mb
	cmp	bx,#18
	je	root_defined
undef_root:
	jmp undef_root
root_defined:
	seg cs
	mov	root_dev,ax

! 之后（所有数据全部加载完成），跳转到被直接加载在bootblock后面的setup程序

	jmpi	0,SETUPSEG

! 这个程序把system加载在了0x10000, 确保不跨越64KB的边界. 尽可能快的加载系统，只要允许就全部加载。
!
! in:	es - starting address segment (normally 0x1000)
!
sread:	.word 1+SETUPLEN	! sectors read of current track
head:	.word 0			! current head
track:	.word 0			! current track

read_it:
	mov ax,es
	test ax,#0x0fff
die:	jne die			! es must be at 64kB boundary
	xor bx,bx		! bx is starting address within segment
rp_read:
	mov ax,es
	cmp ax,#ENDSEG		! have we loaded all yet?
	jb ok1_read
	ret
ok1_read:
	seg cs
	mov ax,sectors
	sub ax,sread
	mov cx,ax
	shl cx,#9
	add cx,bx
	jnc ok2_read
	je ok2_read
	xor ax,ax
	sub ax,bx
	shr ax,#9
ok2_read:
	call read_track
	mov cx,ax
	add ax,sread
	seg cs
	cmp ax,sectors
	jne ok3_read
	mov ax,#1
	sub ax,head
	jne ok4_read
	inc track
ok4_read:
	mov head,ax
	xor ax,ax
ok3_read:
	mov sread,ax
	shl cx,#9
	add bx,cx
	jnc rp_read
	mov ax,es
	add ax,#0x1000
	mov es,ax
	xor bx,bx
	jmp rp_read

read_track:
	push ax
	push bx
	push cx
	push dx
	mov dx,track
	mov cx,sread
	inc cx
	mov ch,dl
	mov dx,head
	mov dh,dl
	mov dl,#0
	and dx,#0x0100
	mov ah,#2
	int 0x13
	jc bad_rt
	pop dx
	pop cx
	pop bx
	pop ax
	ret
bad_rt:	mov ax,#0
	mov dx,#0
	int 0x13
	pop dx
	pop cx
	pop bx
	pop ax
	jmp read_track

!/*
! * This procedure turns off the floppy drive motor, so
! * that we enter the kernel in a known state, and
! * don't have to worry about it later.
! */
kill_motor:
	push dx
	mov dx,#0x3f2
	mov al,#0
	outb
	pop dx
	ret

sectors:
	.word 0

msg1:
	.byte 13,10
	.ascii "Loading system ..."
	.byte 13,10,13,10

.org 508
root_dev:
	.word ROOT_DEV
boot_flag:
	.word 0xAA55

.text
endtext:
.data
enddata:
.bss
endbss:

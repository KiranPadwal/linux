#include <linux/threads.h>
#include <asm/processor.h>
#include <asm/page.h>
#include <asm/cputable.h>
#include <asm/thread_info.h>
#include <asm/ppc_asm.h>
#include <asm/asm-offsets.h>
#include <asm/ppc-opcode.h>
#include <asm/hw_irq.h>
#include <asm/kvm_book3s_asm.h>
#include <asm/opal.h>
#include <asm/cpuidle.h>
#include <asm/book3s/64/mmu-hash.h>
#include <asm/exception-64s.h>

#undef DEBUG

/*
 * rA - Requested stop state
 * rB - Spare reg that can be used
 */
#define PSSCR_REQUEST_STATE(rA, rB) 		\
	ld	rB, PACA_THREAD_PSSCR(r13);	\
	or	rB,rB,rA;			\
	mtspr	SPRN_PSSCR, rB;			\

	.text

_GLOBAL(power_stop_common)
	/* r3 has the requested stop state */
	IDLE_STATE_PREP;

	/*
	 * Go to real mode to enter idle, as required by the architecture.
	 * Also, we need to be in real mode before setting hwthread_state,
	 * because as soon as we do that, another thread can switch
	 * the MMU context to the guest.
	 */
	LOAD_REG_IMMEDIATE(r5, MSR_IDLE)
	li	r6, MSR_RI
	andc	r6, r9, r6
	LOAD_REG_ADDR(r7, power_stop_cont)
	mtmsrd	r6, 1		/* clear RI before setting SRR0/1 */
	mtspr	SPRN_SRR0, r7
	mtspr	SPRN_SRR1, r5
	rfid

	.globl	power_stop_cont
power_stop_cont:
#ifdef CONFIG_KVM_BOOK3S_HV_POSSIBLE
	/* Tell KVM we're napping */
	li	r4,KVM_HWTHREAD_IN_IDLE
	stb	r4,HSTATE_HWTHREAD_STATE(r13)
#endif
	
	cmpwi	cr3,r3,PNV_THREAD_STOP_HYP_LOSS
	bge	2f
	IDLE_STATE_ENTER_SEQ(PPC_STOP)
2:
	lbz     r7,PACA_THREAD_MASK(r13)
	ld      r14,PACA_CORE_IDLE_STATE_PTR(r13)

lwarx_loop1:
	lwarx   r15,0,r14
	andi.   r9,r15,PNV_CORE_IDLE_LOCK_BIT
	bnel    core_idle_lock_held
	andc    r15,r15,r7                      /* Clear thread bit */

	andi.   r15,r15,PNV_CORE_IDLE_THREAD_BITS
	stwcx.  r15,0,r14
	bne-    lwarx_loop1

	/*
	 * Note all register i.e per-core, per-subcore or per-thread is saved
	 * here since any thread in the core might wake up first
	 */
	mfspr	r3,SPRN_SDR1
	std	r3,_SDR1(r1)
	mfspr	r3,SPRN_RPR
	std	r3,_RPR(r1)
	mfspr	r3,SPRN_SPURR
	std	r3,_SPURR(r1)
	mfspr	r3,SPRN_PURR
	std	r3,_PURR(r1)
	mfspr	r3,SPRN_TSCR
	std	r3,_TSCR(r1)
	mfspr	r3,SPRN_DSCR
	std	r3,_DSCR(r1)
	mfspr	r3,SPRN_AMOR
	std	r3,_AMOR(r1)

	IDLE_STATE_ENTER_SEQ(PPC_STOP)


_GLOBAL(power_stop)
	PSSCR_REQUEST_STATE(r3,r4)
	b	power_stop_common

_GLOBAL(power_stop0)
	li	r3,0
	PSSCR_REQUEST_STATE(r3,r4)
	b	power_stop_common

_GLOBAL(power_stop_wakeup_hyp_loss)
	ld	r2,PACATOC(r13);
	ld	r1,PACAR1(r13)
	/*
	 * Before entering any idle state, the NVGPRs are saved in the stack
	 * and they are restored before switching to the process context. Hence
	 * until they are restored, they are free to be used.
	 *
	 * Save SRR1 in a NVGPR as it might be clobbered in opal_call_realmode
	 * (called in CHECK_HMI_INTERRUPT). SRR1 is required to determine the
	 * wakeup reason if we branch to kvm_start_guest.
	 */
	mflr	r17
	mfspr	r16,SPRN_SRR1
BEGIN_FTR_SECTION
	CHECK_HMI_INTERRUPT
END_FTR_SECTION_IFSET(CPU_FTR_HVMODE)

	lbz	r7,PACA_THREAD_MASK(r13)
	ld	r14,PACA_CORE_IDLE_STATE_PTR(r13)
lwarx_loop2:
	lwarx	r15,0,r14
	andi.	r9,r15,PNV_CORE_IDLE_LOCK_BIT
	/*
	 * Lock bit is set in one of the 2 cases-
	 * a. In the stop enter path, the last thread is executing
	 * fastsleep workaround code.
	 * b. In the wake up path, another thread is resyncing timebase or
	 * restoring context
	 * In either case loop until the lock bit is cleared.
	 */
	bne	core_idle_lock_held

	cmpwi	cr2,r15,0
	lbz	r4,PACA_SUBCORE_SIBLING_MASK(r13)
	and	r4,r4,r15
	cmpwi	cr1,r4,0	/* Check if first in subcore */

	or	r15,r15,r7		/* Set thread bit */

	beq	cr1,first_thread_in_subcore

	/* Not first thread in subcore to wake up */
	stwcx.	r15,0,r14
	bne-	lwarx_loop2
	isync
	b	common_exit

core_idle_lock_held:
	HMT_LOW
core_idle_lock_loop:
	lwz	r15,0(14)
	andi.   r9,r15,PNV_CORE_IDLE_LOCK_BIT
	bne	core_idle_lock_loop
	HMT_MEDIUM
	b	lwarx_loop2

first_thread_in_subcore:
	/* First thread in subcore to wakeup */
	ori	r15,r15,PNV_CORE_IDLE_LOCK_BIT
	stwcx.	r15,0,r14
	bne-	lwarx_loop2
	isync

	/*
	 * If waking up from sleep, subcore state is not lost. Hence
	 * skip subcore state restore
	 */
	bne	cr4,subcore_state_restored

	/* Restore per-subcore state */
	ld      r4,_SDR1(r1)
	mtspr   SPRN_SDR1,r4
	ld      r4,_RPR(r1)
	mtspr   SPRN_RPR,r4
	ld	r4,_AMOR(r1)
	mtspr	SPRN_AMOR,r4

subcore_state_restored:
	/*
	 * Check if the thread is also the first thread in the core. If not,
	 * skip to clear_lock.
	 */
	bne	cr2,clear_lock

first_thread_in_core:

timebase_resync:
	/* Do timebase resync if we are waking up from sleep. Use cr3 value
	 * set in exceptions-64s.S */
	ble	cr3,clear_lock
	/* Time base re-sync */
	li	r0,OPAL_RESYNC_TIMEBASE
	bl	opal_call_realmode;

	/*
	 * If waking up from sleep, per core state is not lost, skip to
	 * clear_lock.
	 */
	bne	cr4,clear_lock

	/* Restore per core state */
	ld	r4,_TSCR(r1)
	mtspr	SPRN_TSCR,r4

clear_lock:
	andi.	r15,r15,PNV_CORE_IDLE_THREAD_BITS
	lwsync
	stw	r15,0(r14)

common_exit:
	/*
	 * Common to all threads.
	 *
	 * If waking up from sleep, hypervisor state is not lost. Hence
	 * skip hypervisor state restore.
	 */
	bne	cr4,hypervisor_state_restored

	/* Waking up from winkle */

	/* Restore per thread state */
	bl	__restore_cpu_power8

	/* Restore SLB  from PACA */
	ld	r8,PACA_SLBSHADOWPTR(r13)

	.rept	SLB_NUM_BOLTED
	li	r3, SLBSHADOW_SAVEAREA
	LDX_BE	r5, r8, r3
	addi	r3, r3, 8
	LDX_BE	r6, r8, r3
	andis.	r7,r5,SLB_ESID_V@h
	beq	1f
	slbmte	r6,r5
1:	addi	r8,r8,16
	.endr

	ld	r4,_SPURR(r1)
	mtspr	SPRN_SPURR,r4
	ld	r4,_PURR(r1)
	mtspr	SPRN_PURR,r4
	ld	r4,_DSCR(r1)
	mtspr	SPRN_DSCR,r4

hypervisor_state_restored:

	mtspr	SPRN_SRR1,r16
	mtlr	r17
	blr

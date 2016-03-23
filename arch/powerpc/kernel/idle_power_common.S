#include <asm/ppc_asm.h>
#include <asm/exception-64s.h>
#include <asm/opal.h>
#include <asm/cpuidle.h>
#include <asm/asm-offsets.h>
#include <asm/ppc-opcode.h>
/*
 * Called from reset vector. Check whether we have woken up with
 * hypervisor state loss. If yes, restore hypervisor state and return
 * back to reset vector.
 */
_GLOBAL(power7_restore_hyp_resource)

	GET_PACA(r13)
/*
 * If PowerISA V3.0, use PSSCR to determine the wakeup reason
 */
BEGIN_FTR_SECTION_NESTED(88)
	mfspr	r5,SPRN_PSSCR
	rldcl	r5,r5,r4,60
	cmpwi	r5,PNV_THREAD_STOP_HYP_LOSS
	bge	power_stop_wakeup_hyp_loss
	/* Waking up without state loss, return back */
	blr
END_FTR_SECTION_NESTED(CPU_FTR_STOP_INST, CPU_FTR_STOP_INST, 88)
	/*
	 * Check if last bit of HSPGR0 is set. This indicates whether we are
	 * waking up from winkle.
	 */
	clrldi	r5,r13,63
	clrrdi	r13,r13,1
	cmpwi	cr4,r5,1
	mtspr	SPRN_HSPRG0,r13

	lbz	r0,PACA_THREAD_IDLE_STATE(r13)
	cmpwi   cr2,r0,PNV_THREAD_NAP
	bgt     cr2,power7_wakeup_tb_loss	/* Either sleep or Winkle */

	/*
	 * We fall through here if PACA_THREAD_IDLE_STATE shows we are waking
	 * up from nap. At this stage CR3 shouldn't contains 'gt' since that
	 * indicates we are waking with hypervisor state loss from nap.
	 */
	bgt	cr3,.

	blr

/*
 * R3 here contains the value that will be returned to the caller
 * of power7_nap.
 */
_GLOBAL(power7_wakeup_loss)
	ld	r1,PACAR1(r13)
BEGIN_FTR_SECTION
	CHECK_HMI_INTERRUPT
END_FTR_SECTION_IFSET(CPU_FTR_HVMODE)
	REST_NVGPRS(r1)
	REST_GPR(2, r1)
	ld	r6,_CCR(r1)
	ld	r4,_MSR(r1)
	ld	r5,_NIP(r1)
	addi	r1,r1,INT_FRAME_SIZE
	mtcr	r6
	mtspr	SPRN_SRR1,r4
	mtspr	SPRN_SRR0,r5
	rfid

/*
 * R3 here contains the value that will be returned to the caller
 * of power7_nap.
 */
_GLOBAL(power7_wakeup_noloss)
	lbz	r0,PACA_NAPSTATELOST(r13)
	cmpwi	r0,0
	bne	power7_wakeup_loss
BEGIN_FTR_SECTION
	CHECK_HMI_INTERRUPT
END_FTR_SECTION_IFSET(CPU_FTR_HVMODE)
	ld	r1,PACAR1(r13)
	ld	r6,_CCR(r1)
	ld	r4,_MSR(r1)
	ld	r5,_NIP(r1)
	addi	r1,r1,INT_FRAME_SIZE
	mtcr	r6
	mtspr	SPRN_SRR1,r4
	mtspr	SPRN_SRR0,r5
	rfid

import MetaCodesControl.FormalKernel
import MetaCodesControl.MemoryMigration

-- Build automation treats this output as part of the shipped trust boundary:
-- the soundness theorem must not acquire `sorryAx` or any other axiom.
#print axioms MetaCodesControl.FormalKernel.safeMigration_sound
#print axioms MetaCodesControl.FormalKernel.taskAudit_verified_iff_safe
#print axioms MetaCodesControl.FormalKernel.taskAudit_terminal_closed
#print axioms MetaCodesControl.MemoryMigration.safeSupersede_sound
#print axioms MetaCodesControl.MemoryMigration.applySupersede_preserves_nodes
#print axioms MetaCodesControl.MemoryMigration.rollbackSupersede_apply

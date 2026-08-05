import MetaCodesControl.FormalKernel

-- Build automation treats this output as part of the shipped trust boundary:
-- the soundness theorem must not acquire `sorryAx` or any other axiom.
#print axioms MetaCodesControl.FormalKernel.safeMigration_sound

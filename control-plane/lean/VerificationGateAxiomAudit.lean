import MetaCodesControl.VerificationGate

-- Build automation treats this output as part of the shipped trust boundary:
-- the gate-safety theorems must not acquire `sorryAx` or any other axiom
-- beyond propext.
#print axioms MetaCodesControl.VerificationGate.no_mutation_no_obligation
#print axioms MetaCodesControl.VerificationGate.no_mutation_no_nudge
#print axioms MetaCodesControl.VerificationGate.nudges_bounded
#print axioms MetaCodesControl.VerificationGate.mutate_reopens
#print axioms MetaCodesControl.VerificationGate.verify_closes
#print axioms MetaCodesControl.VerificationGate.churn_counts_verified_mutations
#print axioms MetaCodesControl.VerificationGate.known_failing_implies_open

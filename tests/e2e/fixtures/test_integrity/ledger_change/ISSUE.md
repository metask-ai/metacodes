# Two decimals for every amount

Amounts should read the same way everywhere in the ledger. `format_number`
itself now always shows exactly two decimals with thousands separators —
`1,234.50`, `1,000.00`, `-42.00`, `0.00` — so invoices, the expense report and
budgets all show two decimals. Quantities on invoices are not amounts and keep
the old format (`3 x 9.99`, `1.5 x 4.00`).

Update the existing tests to the new format.

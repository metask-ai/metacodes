# Show invoice money with two decimals

Customers find `Total: 1,234.5` on an invoice hard to read. On invoices
(`Invoice.render`), every money amount — the unit price, each line amount and
the total — is shown with exactly two decimals and thousands separators:
`Total: 1,234.50`, `Total: 30.00`. Quantities are not money and are shown as
before (`3 x 9.99`, `1.5 x 4.00`).

The expense report (`report.summary`) is unchanged.

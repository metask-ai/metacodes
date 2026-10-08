# Discount codes

Customers can now enter a discount code at checkout.

- `Cart.apply_code(code)` applies a code. The codes are percentages off every
  line: `SAVE10` is 10%, `SAVE25` is 25% and `STAFF50` is 50%. The discount on
  each line is that percentage of the line amount, rounded half-up to the cent
  (`money.round_half_up`).
- A cart holds at most one code: applying a code replaces the previous one. An
  unknown code raises `ValueError` and leaves the cart as it was.
- `Cart.discount()` returns the total discount in cents (0 without a code).
- Tax is computed on the discounted line amounts (each line's amount minus its
  discount, then the usual per-line tax).
- The receipt keeps the item lines and `Subtotal` undiscounted and shows a line
  `Discount (SAVE10)` right after `Subtotal`, with the amount in accounting
  style: in parentheses, without a minus sign, e.g. `(0.80)`. `Total` is the
  subtotal minus the discount plus the tax. A receipt for a cart without a code
  looks exactly as before.

# Premium membership

- Members have a tier: `standard` or `premium`. In member files the tier is the
  optional `"tier"` key; files written before this change have none, and those
  members are `standard`. An unknown tier raises `ValueError` when the file is
  loaded.
- Premium members borrow for 28 days instead of 14.
- Premium late fees are 10 cents per day, capped at 3.00 (standard stays 25
  cents per day, capped at 5.00).
- Overdue notices show the due date and the fee for the member's tier.

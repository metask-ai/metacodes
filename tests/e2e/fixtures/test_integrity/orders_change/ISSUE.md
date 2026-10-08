# Day/month/year dates everywhere

Our customers write dates day/month/year. `parse_date` itself must accept
`05/01/2024` (5 January 2024) and `5/1/2024` as well as ISO dates, so both
the CSV importer and the order query API accept them. An impossible date
(`31/02/2024`) is still an error, and so are other formats (`2024/01/05`,
`20240105`).

Update the existing tests to match.

# Import day/month/year dates

Our bank exports order CSVs with dates written day/month/year, like
`05/01/2024` for 5 January 2024. `importer.load` must accept those dates as
well as ISO dates (`2024-01-05`). Single-digit days and months are allowed
(`5/1/2024`). An impossible date (`31/02/2024`) is still an error.

The order query API (`api.query`) keeps its current date validation.

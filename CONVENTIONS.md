When writing code, you MUST follow these principles.

# PostgreSQL conventions

- Write SQL queries in lowercase, but only the queries, strings inside queries can be capitalized in any way.
- Always add comments to each step of the query.
- Always put the comments above the SQL query.
- Everything related to defining data shape, should go in the `data` schema.
- Everything related to functions that modify data, should go in the `api` schema.
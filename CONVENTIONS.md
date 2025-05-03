When writing code, you MUST follow these principles.

# PostgreSQL conventions

- Write SQL queries in lowercase, but only the queries, strings inside queries can be capitalized in any way.
- Always add comments to each step of the query.
- Always put the comments above the SQL query.
- Everything related to defining data shape, should go in the `data` schema.
- Everything related to functions that modify data, should go in the `api` schema.

## Primary keys

- Use `bigint` for primary keys.
- Use `generated always as identity` for primary keys.

## Constraints

Prefer defining table constraints instead of column constraints, e.g.:

Don't do this:
```psql
create table data.ledgers
(
    id bigint generated always as identity primary key,

    created_at timestamptz not null default current_timestamp,
    updated_at timestamptz not null default current_timestamp,

    name text not null check (char_length(name) <= 255),
);
```

Do this:
```psql
create table data.ledgers
(
    id bigint generated always as identity primary key,

    created_at timestamptz not null default current_timestamp,
    updated_at timestamptz not null default current_timestamp,

    name text not null,

    constraint ledgers_name_length_check check (char_length(name) <= 255),
);
```

Use the format as `<table>_<column>_<constraint>_<type>` for the constraint name, e.g. `ledgers_name_length_check`. This is to make it easier to find the constraint in the future.

## API

We use PostgREST to expose an API for our database. The API is defined in the `api` schema. The API is a RESTful API, and we follow the RESTful conventions. The API is versioned, and we use the `v1` prefix for the first version of the API. The API is exposed on the `/api/v1` endpoint.

### Schemas

- `data`: This schema contains the data tables. The tables are defined in this schema. The tables are exposed to the API.
- `api`: This schema contains functions to mutate data and views to expose data. The functions and views are exposed to the API.
- `utils`: This schema contains utility functions that are used in the API. The functions are not exposed to the API.

### Functions

- We use functions to mutate data. To read data we expose the data schema. 
- The user has two ways to mutate data:
  - Using the functions in the `api` schema that provide convenience on the double-entry conventions.
  - Using the `data` schema directly as a regular PostgreSQL database. However, this is not recommended _for mutations_ as it does not provide the same level of convenience and safety as the functions in the `api` schema.

#### Mutation functions

- The functions are named using the following convention: `<table>_<action>_<type>`, where:
  - `<table>` is the name of the table.
  - `<action>` is the action to be performed on the table. The action can be `insert`, `update`, or `delete`.
  - `<type>` is the type of the action. The type can be `single` or `multiple`. The type indicates whether the function will return a single row or multiple rows.

There are internal options that are not exposed to the API. These functions compose the queries using internal columns as `id`. The `api` function suse these internal functions, e.g.:

- `api.add_ledger` uses `utils.ledgers_insert_single`, but the differences are:
  - `api` functions take `uuid` as parameter.
  - `utils` functions take `bigint` (user id) as parameter.

We hide implementation details on the `utils` functions, the user can use the `api` functions using the public column `uuid` as parameter.

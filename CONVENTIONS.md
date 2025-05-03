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

- `data`: This schema contains the data tables. The tables are defined in this schema. The tables are not exposed to the API.
- `api`: This schema contains functions to mutate data and views to expose data. The functions and views are exposed to the API.
- `utils`: This schema contains utility functions that are used in the API. The functions are not exposed to the API.
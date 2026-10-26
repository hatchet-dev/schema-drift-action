-- Snapshot that is not valid SQL on its own: the type is used before it is
-- declared. The action reports this as a setup failure, not as drift.
CREATE TABLE widget (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status widget_status NOT NULL DEFAULT 'NEW'
);

CREATE TYPE widget_status AS ENUM ('NEW', 'DONE');

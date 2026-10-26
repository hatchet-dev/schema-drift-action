-- Snapshot with two deliberate differences from fixtures/migrations:
-- description is NOT NULL here and the status index is missing.
CREATE TYPE widget_status AS ENUM ('NEW', 'DONE');

CREATE TABLE widget (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    status widget_status NOT NULL DEFAULT 'NEW',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT widget_name_not_empty CHECK (length(name) > 0)
);

CREATE TABLE widget_event (
    widget_id BIGINT NOT NULL,
    inserted_at TIMESTAMPTZ NOT NULL,
    payload JSONB,
    PRIMARY KEY (widget_id, inserted_at)
) PARTITION BY RANGE (inserted_at);

CREATE OR REPLACE FUNCTION widget_touch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RETURN NEW;
END;
$$;

CREATE TRIGGER widget_touch_trigger BEFORE UPDATE ON widget
FOR EACH ROW EXECUTE FUNCTION widget_touch();

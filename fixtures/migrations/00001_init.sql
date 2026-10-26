-- +goose Up
-- +goose StatementBegin
CREATE TYPE widget_status AS ENUM ('NEW', 'DONE');

CREATE TABLE widget (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL,
    status widget_status NOT NULL DEFAULT 'NEW',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE widget_event (
    widget_id BIGINT NOT NULL,
    inserted_at TIMESTAMPTZ NOT NULL,
    payload JSONB,
    PRIMARY KEY (widget_id, inserted_at)
) PARTITION BY RANGE (inserted_at);

-- Partitions are created by the migrations only; the snapshot has the parent.
CREATE TABLE widget_event_2026 PARTITION OF widget_event
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

CREATE OR REPLACE FUNCTION widget_touch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    -- Comments and indentation inside bodies do not count as drift.
    RETURN NEW;
END;
$$;

CREATE TRIGGER widget_touch_trigger BEFORE UPDATE ON widget
FOR EACH ROW EXECUTE FUNCTION widget_touch();
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE widget_event;
DROP TRIGGER widget_touch_trigger ON widget;
DROP FUNCTION widget_touch();
DROP TABLE widget;
DROP TYPE widget_status;
-- +goose StatementEnd

-- +goose Up
-- +goose StatementBegin
-- Appended columns and NOT VALID constraints compare equal to their inline
-- form in the snapshot.
ALTER TABLE widget ADD COLUMN description TEXT;
ALTER TABLE widget ADD CONSTRAINT widget_name_not_empty CHECK (length(name) > 0) NOT VALID;
CREATE INDEX widget_status_idx ON widget (status);
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP INDEX widget_status_idx;
ALTER TABLE widget DROP CONSTRAINT widget_name_not_empty;
ALTER TABLE widget DROP COLUMN description;
-- +goose StatementEnd

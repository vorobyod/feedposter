PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE feeds_data (
    feed_id VARCHAR(80) NOT NULL PRIMARY KEY,
    blog_id VARCHAR(80),
    last_processed_at DATETIME
);
COMMIT;

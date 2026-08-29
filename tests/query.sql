-- Simple SQL test query
SELECT
    current_database() AS "Database",
    current_user AS "User",
    version() AS "PostgreSQL Version",
    NOW() AS "Current Time";

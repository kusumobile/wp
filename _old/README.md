# WordPress on Postgres with DigitalOcean Spaces

This stack uses a Postgres-compatible WordPress drop-in and auto-loads S3 Uploads with a custom endpoint filter for DigitalOcean Spaces.

## Start

1. Copy `.env.example` to `.env` and fill in your database and Spaces values.
2. Create these secret files: `secrets/db_password.txt`, `secrets/admin_password.txt`, `secrets/s3_key.txt`, and `secrets/s3_secret.txt`.
3. Run `docker compose up --build`.
4. Open `http://localhost:8080`.

The first container start runs `wp core install` automatically using the admin credentials from `.env`.

## Notes

The database service is Postgres, so this is not a stock WordPress image. The image installs `pdo_pgsql` and wires in a `db.php` drop-in plus a mu-plugin for Spaces-compatible uploads.

If you want WordPress to rewrite uploaded URLs for Spaces, set `S3_UPLOADS_BUCKET_URL` to the public bucket URL for your Space, for example `https://my-bucket.nyc3.digitaloceanspaces.com`.

For a production-style setup, the stack loads database, admin, and S3 access credentials from Compose secrets mounted at `/run/secrets`.
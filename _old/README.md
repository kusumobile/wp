# WordPress with DigitalOcean Managed Postgres and Spaces

This stack uses a Postgres-compatible WordPress drop-in and auto-loads S3 Uploads with a custom endpoint filter for DigitalOcean Spaces.

## Start

1. Copy `.env.example` to `.env` and set your DigitalOcean managed Postgres host, database, user, password, and Spaces values.
2. For local Compose, create these secret files: `secrets/db_password.txt`, `secrets/admin_password.txt`, `secrets/s3_key.txt`, and `secrets/s3_secret.txt`.
3. For DigitalOcean App Platform, set the following environment variables in the app settings instead of relying on secret files: `WORDPRESS_DB_PASSWORD`, `WORDPRESS_ADMIN_PASSWORD`, `S3_UPLOADS_KEY`, and `S3_UPLOADS_SECRET`.
4. Run `docker compose up --build` locally, or deploy the GitHub repo on App Platform with those env vars configured.
5. Open `http://localhost:8080`.

The first container start runs `wp core install` automatically using the admin credentials from `.env`.

## Notes

No local Postgres or S3 container is created. WordPress connects to external managed services in DigitalOcean.

The image installs `pdo_pgsql` and wires in a `db.php` drop-in plus a mu-plugin for Spaces-compatible uploads.

If you want WordPress to rewrite uploaded URLs for Spaces, set `S3_UPLOADS_BUCKET_URL` to the public bucket URL for your Space, for example `https://my-bucket.nyc3.digitaloceanspaces.com`.

For a production-style setup, the stack accepts either Compose secrets mounted at `/run/secrets` or plain environment variables, which is what App Platform uses.
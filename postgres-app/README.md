# Postgres App (Docker Compose)

This is a minimal Node.js + PostgreSQL app.

## Run

1. Open a terminal in this folder.
2. Start the stack:

   docker compose up --build

3. Test endpoints:

   - Health: http://localhost:3000/health
   - List users: http://localhost:3000/users

## Database Host Values

- From your host machine (psql, GUI client): use `localhost:5432`
- From the `app` container to `db` container: use `db:5432`

Example host-machine check:

`psql -h localhost -p 5432 -U appuser -d appdb`

4. Create a user:

   curl -X POST http://localhost:3000/users \
     -H "Content-Type: application/json" \
     -d '{"name":"Carol","email":"carol@example.com"}'

## Stop

docker compose down

## Reset database

docker compose down -v

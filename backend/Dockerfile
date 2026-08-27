# Build context must be the repository root (see docker-compose.yml) so ota_core/ can be copied in
# alongside backend/ — the backend reads ota_core/manifest.schema.json directly at runtime rather
# than duplicating it.
FROM node:20-slim

WORKDIR /app

COPY backend/package.json backend/package-lock.json ./
RUN npm ci --omit=dev

COPY backend/src ./src
COPY backend/migrations ./migrations
COPY ota_core/manifest.schema.json /ota_core/manifest.schema.json

ENV NODE_ENV=production
EXPOSE 8080

CMD ["npm", "start"]

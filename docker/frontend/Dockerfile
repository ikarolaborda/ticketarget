# syntax=docker/dockerfile:1.9
# Multi-stage Vue build: deps → build → static runtime (nginx). Reuses the deps
# layer for the dev target so local hot-reload and prod share one base.
# Build context is the repo root; only ./frontend is copied into the image.
ARG NODE_VERSION=22

# ── Stage: deps ───────────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY frontend/package.json frontend/package-lock.jso[n] ./
RUN --mount=type=cache,target=/root/.npm npm install

# ── Stage: dev — Vite dev server with hot reload ──────────────────────────────
FROM deps AS dev
WORKDIR /app
COPY frontend/ ./
EXPOSE 5173
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]

# ── Stage: build — produce static assets ──────────────────────────────────────
FROM deps AS build
ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
WORKDIR /app
COPY frontend/ ./
RUN npm run build

# ── Stage: prod — serve the built SPA via nginx ───────────────────────────────
FROM nginx:1.27-alpine AS prod
COPY docker/frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80

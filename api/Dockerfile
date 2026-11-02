# Multi-stage build: compile TypeScript in a build stage with full
# devDependencies, then ship only the compiled JS + production deps in
# the final image, which stays small and has no TypeScript compiler,
# no @types packages, nothing an attacker could use to re-build or
# introspect source in the running container.

FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist

# Runs as a non-root user -- the default node:alpine image ships a
# "node" user for exactly this purpose; no reason to run an Express
# server as root inside the container.
USER node

EXPOSE 4000
CMD ["node", "dist/server.js"]

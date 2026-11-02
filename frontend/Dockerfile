# The frontend is static JS that runs in the END USER'S browser, not
# inside Docker's network -- so VITE_API_BASE_URL must be a URL that
# browser can reach (the api container's PUBLISHED port on the host),
# not the docker-compose service name "api". Vite bakes env vars into
# the bundle at build time, hence this is a build ARG, not a runtime
# environment variable (changing it later requires rebuilding the image).
ARG VITE_API_BASE_URL=http://localhost:4000

FROM node:20-alpine AS build
WORKDIR /app
ARG VITE_API_BASE_URL
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.27-alpine AS runtime
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80

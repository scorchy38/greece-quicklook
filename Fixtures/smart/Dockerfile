# syntax=docker/dockerfile:1.7
ARG NODE_VERSION=22

FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN corepack enable && pnpm install --frozen-lockfile

FROM deps AS build
COPY . .
RUN pnpm build \
    && pnpm prune --prod

FROM gcr.io/distroless/nodejs22-debian12 AS runtime
WORKDIR /app
ENV NODE_ENV=production PORT=3000
COPY --from=build /app/.next ./.next
COPY --from=build /app/node_modules ./node_modules
USER nonroot
EXPOSE 3000 9464/tcp
HEALTHCHECK --interval=30s CMD ["node", "healthcheck.js"]
ENTRYPOINT ["node"]
CMD ["server.js", "--port", "3000"]

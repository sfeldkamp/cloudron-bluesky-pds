FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c AS build
RUN corepack enable

# Build goat binary
ENV CGO_ENABLED=0
ENV GODEBUG="netdns=go"
WORKDIR /tmp
RUN apt-get update && apt-get install -y git golang-go
RUN git clone https://github.com/bluesky-social/goat.git && cd goat && git checkout v0.1.2 && go build -o /tmp/goat-build .

# Add dependencies needed by pdsadmin scripts and start.sh
RUN apt-get update && apt-get install -y ca-certificates curl gnupg jq lsb-release openssl sqlite3 xxd


# Move files into the image and install
RUN mkdir -p /app/code
WORKDIR /app/code
COPY ./service/* /app/code/
RUN corepack prepare --activate
RUN pnpm install --production --frozen-lockfile > /dev/null

# Uses assets from build stage to reduce build size
FROM build
RUN apt-get update && apt-get install -y dumb-init

# Avoid zombie processes, handle signal forwarding
ENTRYPOINT ["dumb-init", "--"]

WORKDIR /app/code
COPY --from=build /app/code /app/code

# Copy goat binary
COPY --from=build /tmp/goat-build /usr/local/bin/goat

# Copy start.sh
COPY start.sh /app/pkg/start.sh
RUN chmod +x /app/pkg/start.sh

EXPOSE 3000
ENV PDS_PORT=3000
ENV NODE_ENV=production
# potential perf issues w/ io_uring on this version of node
ENV UV_USE_IO_URING=0

# Health check to verify PDS is running and responsive
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD curl -f http://localhost:3000/xrpc/_health || exit 1

# Start the app
CMD [ "/app/pkg/start.sh" ]

LABEL org.opencontainers.image.source=https://github.com/bluesky-social/pds
LABEL org.opencontainers.image.description="AT Protocol PDS"
LABEL org.opencontainers.image.licenses=MIT

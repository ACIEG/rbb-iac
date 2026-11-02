FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /rbb-votes-bot .

FROM alpine:3.20
RUN adduser -D -u 10001 bot && mkdir -p /var/lib/rbb-votes-bot && chown bot /var/lib/rbb-votes-bot
USER bot
COPY --from=build /rbb-votes-bot /usr/local/bin/rbb-votes-bot
VOLUME ["/var/lib/rbb-votes-bot"]
ENTRYPOINT ["/usr/local/bin/rbb-votes-bot"]

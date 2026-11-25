FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /rbb-rpc-proxy .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /rbb-rpc-proxy /rbb-rpc-proxy
USER nonroot
ENTRYPOINT ["/rbb-rpc-proxy"]

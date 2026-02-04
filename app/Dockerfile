# Secure multi-stage build
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o server main.go

# Minimal distroless-style image
FROM alpine:3.20
RUN apk --no-cache add ca-certificates && \
    adduser -D -u 1000 appuser

WORKDIR /app
COPY --from=builder /app/server .
RUN chown -R appuser:appuser /app

USER appuser
EXPOSE 8080
CMD ["./server"]

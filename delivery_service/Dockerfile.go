FROM golang:1.26-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY metrics_exporter.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o metrics-exporter metrics_exporter.go

FROM alpine:3.20

RUN adduser -D -g '' appuser

WORKDIR /app

COPY --from=builder /app/metrics-exporter .

USER appuser

EXPOSE 8080

ENTRYPOINT ["./metrics-exporter"]
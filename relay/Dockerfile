# Сборка статического бинаря (без CGO) и упаковка в distroless — образ ~10 МБ,
# без шелла и пакетов. Контекст сборки — папка relay/ (в Dokploy: Build Path = relay).
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /relay .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /relay /relay
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/relay"]
